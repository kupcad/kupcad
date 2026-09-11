const std = @import("std");

const LOCKFILE_VERSION = "1.0.0";

const LockFile = struct {
    dependencies: std.StringHashMapUnmanaged([]const u8),
};

/// A recursive directory builder using Zig 0.16.0 native std.Io capabilities.
fn ensurePath(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var end: usize = 0;
    while (end < path.len) {
        end += 1;
        if (end == path.len or path[end] == '/') {
            const sub = path[0..end];
            if (sub.len > 0 and !std.mem.eql(u8, sub, ".") and !std.mem.eql(u8, sub, "..")) {
                cwd.createDir(io, sub, .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => continue,
                    else => return err,
                };
            }
        }
    }
}

/// A stable HTTP GET request using the core Zig 0.16.0 HTTP primitives.
fn fetchHttpNative(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var req = try client.request(.GET, try std.Uri.parse(url), .{
        .extra_headers = &[_]std.http.Header{
            .{ .name = "User-Agent", .value = "kupcad" },
        },
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) return error.InvalidResponse;

    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    return try out.toOwnedSlice();
}

/// Resolves the latest commit hash for a GitHub repository
fn fetchLatestCommit(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8) ![]const u8 {
    const api_url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/commits/main", .{repo_path[11..]});
    defer allocator.free(api_url);

    const body = try fetchHttpNative(allocator, io, api_url);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const sha = parsed.value.object.get("sha") orelse return error.InvalidResponse;
    return allocator.dupe(u8, sha.string);
}

fn stripFirstComponent(path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/')) |idx| {
        return path[idx + 1 ..];
    }
    return "";
}

/// Downloads, decompresses, and extracts the tarball completely natively in memory
fn downloadAndExtract(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8, commit_sha: []const u8) !void {
    const cache_dir_path = try std.fmt.allocPrint(allocator, ".kupcad_cache/{s}/{s}", .{ repo_path, commit_sha });
    defer allocator.free(cache_dir_path);

    try ensurePath(io, cache_dir_path);

    const tarball_url = try std.fmt.allocPrint(allocator, "https://{s}/archive/{s}.tar.gz", .{ repo_path, commit_sha });
    defer allocator.free(tarball_url);

    const tarball_data = try fetchHttpNative(allocator, io, tarball_url);
    defer allocator.free(tarball_data);

    var in_stream: std.Io.Reader = .fixed(tarball_data);
    const decompress: std.compress.flate.Decompress = .init(&in_stream, .gzip, &.{});

    const cwd_io = std.Io.Dir.cwd();
    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;

    var tar_iter: std.tar.Iterator = .init(@constCast(&decompress.reader), .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    // Extract files block by block
    while (try tar_iter.next()) |file| {
        const stripped_name = stripFirstComponent(file.name);
        if (stripped_name.len == 0) {
            continue;
        }

        const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir_path, stripped_name });
        defer allocator.free(out_path);

        if (file.kind == .directory) {
            try ensurePath(io, out_path);
        } else if (file.kind == .file) {
            if (std.fs.path.dirname(out_path)) |parent| {
                try ensurePath(io, parent);
            }

            const file_size: usize = @intCast(file.size);
            const content = try allocator.alloc(u8, file_size);
            defer allocator.free(content);

            // Extract the tar payload natively into the allocated buffer
            var fw: std.Io.Writer = .fixed(content);
            try tar_iter.streamRemaining(file, &fw);

            cwd_io.writeFile(io, .{ .sub_path = out_path, .data = content }) catch {};
        }
    }
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

    // Read and parse existing kupcad.lock safely
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

    // Format lockfile JSON manually to include metadata and version
    var out_str = std.array_list.Managed(u8).init(allocator);
    defer out_str.deinit();

    try out_str.appendSlice("{\n  \"metadata\": {\n    \"version\": \"");
    try out_str.appendSlice(LOCKFILE_VERSION);
    try out_str.appendSlice("\"\n  },\n  \"dependencies\": {\n");
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
