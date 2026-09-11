const std = @import("std");
const Store = @import("store.zig").Store;
const paths = @import("paths.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

const LOCKFILE_VERSION = "1.0.0";

pub const PackageManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: Store,
    global_store_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !PackageManager {
        const home_dir = try paths.getHomeDir(allocator);
        defer allocator.free(home_dir);

        const global_store_path = try std.fmt.allocPrint(allocator, "{s}/.kupcad/pkg", .{home_dir});

        // Ensure global directory exists before opening DB
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, global_store_path) catch {};

        const db_path_raw = try std.fmt.allocPrint(allocator, "{s}/index.db", .{global_store_path});
        defer allocator.free(db_path_raw);

        const db_path = try allocator.dupeZ(u8, db_path_raw);
        defer allocator.free(db_path);

        const store = try Store.init(db_path);

        return .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .global_store_path = global_store_path,
        };
    }

    pub fn deinit(self: *PackageManager) void {
        self.store.deinit();
        self.allocator.free(self.global_store_path);
    }

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

    fn fetchHttpNative(self: *PackageManager, url: []const u8) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var req = try client.request(.GET, try std.Uri.parse(url), .{
            .extra_headers = &[_]std.http.Header{.{ .name = "User-Agent", .value = "kupcad" }},
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status != .ok) return error.InvalidResponse;

        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();

        var buf: [8192]u8 = undefined;
        while (true) {
            const n = try reader.readSliceShort(&buf);
            if (n == 0) break;
            try out.appendSlice(buf[0..n]);
        }
        return try out.toOwnedSlice();
    }

    fn fetchLatestCommit(self: *PackageManager, repo_path: []const u8) ![]const u8 {
        const api_url = try std.fmt.allocPrint(self.allocator, "https://api.github.com/repos/{s}/commits/main", .{repo_path[11..]});
        defer self.allocator.free(api_url);

        const body = try self.fetchHttpNative(api_url);
        defer self.allocator.free(body);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const sha = parsed.value.object.get("sha") orelse return error.InvalidResponse;
        return self.allocator.dupe(u8, sha.string);
    }

    fn stripFirstComponent(path: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, path, '/')) |idx| {
            return path[idx + 1 ..];
        }
        return "";
    }

    pub fn addPackage(self: *PackageManager, repo_url: []const u8) !void {
        std.debug.print("Resolving {s}...\n", .{repo_url});
        const commit_sha = try self.fetchLatestCommit(repo_url);
        defer self.allocator.free(commit_sha);

        const repo_url_z = try self.allocator.dupeZ(u8, repo_url);
        defer self.allocator.free(repo_url_z);
        const commit_sha_z = try self.allocator.dupeZ(u8, commit_sha);
        defer self.allocator.free(commit_sha_z);

        const package_id = try self.store.insertPackage(repo_url_z, commit_sha_z);

        std.debug.print("Downloading {s} (commit {s})...\n", .{ repo_url, commit_sha[0..7] });
        const tarball_url = try std.fmt.allocPrint(self.allocator, "https://{s}/archive/{s}.tar.gz", .{ repo_url, commit_sha });
        defer self.allocator.free(tarball_url);

        const tarball_data = try self.fetchHttpNative(tarball_url);
        defer self.allocator.free(tarball_data);

        var in_stream: std.Io.Reader = .fixed(tarball_data);
        const decompress: std.compress.flate.Decompress = .init(&in_stream, .gzip, &.{});

        const cwd_io = std.Io.Dir.cwd();
        var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;

        var tar_iter: std.tar.Iterator = .init(@constCast(&decompress.reader), .{ .file_name_buffer = &file_name_buffer, .link_name_buffer = &link_name_buffer });

        const cafs_dir = try std.fmt.allocPrint(self.allocator, "{s}/files", .{self.global_store_path});
        defer self.allocator.free(cafs_dir);
        try ensurePath(self.io, cafs_dir);

        const local_pkg_dir = try std.fmt.allocPrint(self.allocator, ".kupcad/pkg/{s}", .{repo_url});
        defer self.allocator.free(local_pkg_dir);
        try ensurePath(self.io, local_pkg_dir);

        while (try tar_iter.next()) |file| {
            const stripped_name = stripFirstComponent(file.name);
            if (stripped_name.len == 0) continue;

            const local_out_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ local_pkg_dir, stripped_name });
            defer self.allocator.free(local_out_path);

            if (file.kind == .directory) {
                try ensurePath(self.io, local_out_path);
            } else if (file.kind == .file) {
                if (std.fs.path.dirname(local_out_path)) |parent| {
                    try ensurePath(self.io, parent);
                }

                const file_size: usize = @intCast(file.size);
                const content = try self.allocator.alloc(u8, file_size);
                defer self.allocator.free(content);

                var fw: std.Io.Writer = .fixed(content);
                try tar_iter.streamRemaining(file, &fw);

                var sha256 = Sha256.init(.{});
                sha256.update(content);
                const digest = sha256.finalResult();

                // Natively print the array pointer as a hex string
                var hex_buf: [64]u8 = undefined;
                const hex_digest = try std.fmt.bufPrint(&hex_buf, "{x}", .{&digest});

                const cafs_file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ cafs_dir, hex_digest });
                defer self.allocator.free(cafs_file_path);

                cwd_io.writeFile(self.io, .{ .sub_path = cafs_file_path, .data = content }) catch {};

                const hex_digest_z = try self.allocator.dupeZ(u8, hex_digest);
                defer self.allocator.free(hex_digest_z);
                const local_path_z = try self.allocator.dupeZ(u8, stripped_name);
                defer self.allocator.free(local_path_z);

                const is_executable = (file.mode & 0o111) != 0;
                try self.store.insertFile(hex_digest_z, file_size, is_executable);
                try self.store.linkPackageFile(package_id, hex_digest_z, local_path_z);

                cwd_io.symLink(self.io, cafs_file_path, local_out_path, .{}) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            }
        }

        try self.updateLockfile(repo_url, commit_sha);
        std.debug.print("Added successfully!\n", .{});
    }

    fn updateLockfile(self: *PackageManager, repo_url: []const u8, commit_sha: []const u8) !void {
        var lock_map = std.StringHashMapUnmanaged([]const u8){};
        defer {
            var it = lock_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            lock_map.deinit(self.allocator);
        }

        const cwd = std.Io.Dir.cwd();
        if (cwd.openFile(self.io, "kupcad.lock", .{})) |file| {
            defer file.close(self.io);
            if (file.stat(self.io)) |stat| {
                if (std.math.cast(usize, stat.size)) |file_size| {
                    if (file_size > 0) {
                        const content = try self.allocator.alloc(u8, file_size);
                        defer self.allocator.free(content);

                        const bytes_read = try file.readStreaming(self.io, &.{content});
                        if (bytes_read == file_size) {
                            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, content, .{}) catch null;
                            if (parsed) |*p| {
                                defer p.deinit();
                                if (p.value == .object) {
                                    if (p.value.object.get("dependencies")) |deps| {
                                        if (deps == .object) {
                                            var it = deps.object.iterator();
                                            while (it.next()) |entry| {
                                                if (entry.value_ptr.* == .string) {
                                                    const k = try self.allocator.dupe(u8, entry.key_ptr.*);
                                                    const v = try self.allocator.dupe(u8, entry.value_ptr.string);
                                                    try lock_map.put(self.allocator, k, v);
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

        if (lock_map.fetchRemove(repo_url)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        const new_key = try self.allocator.dupe(u8, repo_url);
        const new_val = try self.allocator.dupe(u8, commit_sha);
        try lock_map.put(self.allocator, new_key, new_val);

        var out_str = std.array_list.Managed(u8).init(self.allocator);
        defer out_str.deinit();

        try out_str.appendSlice("{\n  \"metadata\": {\n    \"version\": \"");
        try out_str.appendSlice(LOCKFILE_VERSION);
        try out_str.appendSlice("\"\n  },\n  \"dependencies\": {\n");
        var it = lock_map.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try out_str.appendSlice(",\n");
            first = false;
            const line = try std.fmt.allocPrint(self.allocator, "    \"{s}\": \"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            defer self.allocator.free(line);
            try out_str.appendSlice(line);
        }
        try out_str.appendSlice("\n  }\n}\n");

        try cwd.writeFile(self.io, .{ .sub_path = "kupcad.lock", .data = out_str.items });
    }
};
