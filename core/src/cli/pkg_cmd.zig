const std = @import("std");

/// Resolves the latest commit hash for a GitHub repository using system curl
fn fetchLatestCommit(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8) ![]const u8 {
    const api_url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/commits/main", .{repo_path[11..]});
    defer allocator.free(api_url);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-s", "-H", "User-Agent: kupcad", api_url },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) return error.InvalidResponse;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    const sha = parsed.value.object.get("sha") orelse return error.InvalidResponse;
    return allocator.dupe(u8, sha.string);
}

/// Downloads and extracts the tarball into the local .kupcad_cache/ directory
fn downloadAndExtract(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8, commit_sha: []const u8) !void {
    const cache_dir_path = try std.fmt.allocPrint(allocator, ".kupcad_cache/{s}/{s}", .{ repo_path, commit_sha });
    defer allocator.free(cache_dir_path);

    const mkdir_res = try std.process.run(allocator, io, .{
        .argv = &.{ "mkdir", "-p", cache_dir_path },
    });
    defer allocator.free(mkdir_res.stdout);
    defer allocator.free(mkdir_res.stderr);

    const tarball_url = try std.fmt.allocPrint(allocator, "https://{s}/archive/{s}.tar.gz", .{ repo_path, commit_sha });
    defer allocator.free(tarball_url);

    const tarball_path = try std.fmt.allocPrint(allocator, ".kupcad_cache/{s}.tar.gz", .{commit_sha});
    defer allocator.free(tarball_path);

    // Download the tarball securely using Zig 0.16.0 process execution
    const curl_res = try std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-sL", tarball_url, "-o", tarball_path },
    });
    defer allocator.free(curl_res.stdout);
    defer allocator.free(curl_res.stderr);

    if (curl_res.term != .exited or curl_res.term.exited != 0) return error.DownloadFailed;

    // Extract the tarball into the cache directory
    const tar_res = try std.process.run(allocator, io, .{
        .argv = &.{ "tar", "-xzf", tarball_path, "-C", cache_dir_path, "--strip-components=1" },
    });
    defer allocator.free(tar_res.stdout);
    defer allocator.free(tar_res.stderr);

    // Clean up the zipped archive natively
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, tarball_path) catch {};
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const repo_url = args_iter.next() orelse {
        std.debug.print("Error: Missing repository URL.\nUsage: kupcad add github.com/user/repo\n", .{});
        return;
    };

    std.debug.print("Resolving {s}...\n", .{repo_url});
    const commit_sha = try fetchLatestCommit(allocator, init.io, repo_url);
    defer allocator.free(commit_sha);

    std.debug.print("Downloading {s} (commit {s})...\n", .{ repo_url, commit_sha[0..7] });
    try downloadAndExtract(allocator, init.io, repo_url, commit_sha);

    // Memory-managed map for lockfile state
    var lock_map = std.StringHashMapUnmanaged([]const u8){};
    defer {
        var it = lock_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        lock_map.deinit(allocator);
    }

    const cwd = std.Io.Dir.cwd();

    // Read and parse existing kupcad.lock using dynamic std.json.Value
    if (cwd.openFile(init.io, "kupcad.lock", .{})) |file| {
        defer file.close(init.io);
        if (file.stat(init.io)) |stat| {
            if (std.math.cast(usize, stat.size)) |file_size| {
                if (file_size > 0) {
                    const content = try allocator.alloc(u8, file_size);
                    defer allocator.free(content);

                    const bytes_read = try file.readStreaming(init.io, &.{content});
                    if (bytes_read == file_size) {
                        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch null;
                        if (parsed) |*p| {
                            defer p.deinit();
                            if (p.value == .object) {
                                if (p.value.object.get("dependencies")) |deps| {
                                    if (deps == .object) {
                                        var it = deps.object.iterator();
                                        while (it.next()) |entry| {
                                            if (entry.value_ptr.* == .string) {
                                                const k = try allocator.dupe(u8, entry.key_ptr.*);
                                                const v = try allocator.dupe(u8, entry.value_ptr.string);
                                                try lock_map.put(allocator, k, v);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else |_| {}
    } else |_| {}

    // Replace existing key if updating
    if (lock_map.fetchRemove(repo_url)) |kv| {
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
    const new_key = try allocator.dupe(u8, repo_url);
    const new_val = try allocator.dupe(u8, commit_sha);
    try lock_map.put(allocator, new_key, new_val);

    // Format lockfile JSON
    var out_str = std.array_list.Managed(u8).init(allocator);
    defer out_str.deinit();

    try out_str.appendSlice("{\n  \"dependencies\": {\n");
    var it = lock_map.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try out_str.appendSlice(",\n");
        first = false;
        const line = try std.fmt.allocPrint(allocator, "    \"{s}\": \"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
        defer allocator.free(line);
        try out_str.appendSlice(line);
    }
    try out_str.appendSlice("\n  }\n}\n");

    try cwd.writeFile(init.io, .{ .sub_path = "kupcad.lock", .data = out_str.items });
    std.debug.print("Added successfully!\n", .{});
}
