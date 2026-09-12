const std = @import("std");
const Cafs = @import("cafs.zig").Cafs;
const Store = @import("store.zig").Store;

pub const Doctor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cafs: *Cafs,
    store: *Store,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cafs: *Cafs, store: *Store) Doctor {
        return .{
            .allocator = allocator,
            .io = io,
            .cafs = cafs,
            .store = store,
        };
    }

    /// Audits and heals the CAFS and database state
    pub fn run(self: *Doctor) !void {
        std.debug.print("Running KupCAD Doctor...\n", .{});

        try self.checkDbIntegrity();
        try self.healMissingBlobs();
        try self.healOrphanedBlobs();

        std.debug.print("System health check complete.\n", .{});
    }

    fn checkDbIntegrity(self: *Doctor) !void {
        std.debug.print("[1/3] Checking SQLite integrity... ", .{});
        const stmt = try self.store.db.prepare("PRAGMA quick_check");
        defer stmt.deinit();

        if (try stmt.one(struct { result: []const u8 }, .{}, .{})) |row| {
            if (std.mem.eql(u8, row.result, "ok")) {
                std.debug.print("OK\n", .{});
                return;
            }
        }
        std.debug.print("CORRUPTED!\n", .{});
        return error.DatabaseCorrupted;
    }

    fn healMissingBlobs(self: *Doctor) !void {
        std.debug.print("[2/3] Scanning for missing physical files... ", .{});

        const query = "SELECT hash FROM files";
        var stmt = try self.store.db.prepare(query);
        defer stmt.deinit();

        var rows = try stmt.iterator(struct { hash: []const u8 }, .{});
        const cwd = std.Io.Dir.cwd();
        var missing_count: usize = 0;

        while (try rows.next()) |row| {
            const final_path = try std.fmt.allocPrint(self.allocator, "{s}/files/{s}", .{ self.cafs.global_dir_path, row.hash });
            defer self.allocator.free(final_path);

            const file_exists = if (cwd.openFile(self.io, final_path, .{})) |f| blk: {
                f.close(self.io);
                break :blk true;
            } else |_| false;

            if (!file_exists) {
                // Delete from DB so it gets re-downloaded next install
                const del_files = try std.fmt.allocPrint(self.allocator, "DELETE FROM files WHERE hash = '{s}'", .{row.hash});
                defer self.allocator.free(del_files);
                try self.store.db.exec(del_files, .{}, .{});

                const del_pkg = try std.fmt.allocPrint(self.allocator, "DELETE FROM package_files WHERE file_hash = '{s}'", .{row.hash});
                defer self.allocator.free(del_pkg);
                try self.store.db.exec(del_pkg, .{}, .{});

                missing_count += 1;
            }
        }

        if (missing_count > 0) {
            std.debug.print("Evicted {d} missing blobs from index. Run 'kupcad pkg install' to repair.\n", .{missing_count});
        } else {
            std.debug.print("OK\n", .{});
        }
    }

    fn healOrphanedBlobs(self: *Doctor) !void {
        std.debug.print("[3/3] Scanning for orphaned physical files... ", .{});

        const files_path = try std.fmt.allocPrint(self.allocator, "{s}/files", .{self.cafs.global_dir_path});
        defer self.allocator.free(files_path);

        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(self.io, files_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var it = dir.iterate();
        var orphan_count: usize = 0;
        const now_ts = std.Io.Clock.real.now(self.io);
        const now = @divFloor(now_ts.nanoseconds, std.time.ns_per_s);

        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;

            // Check if hash exists in DB
            const query = try std.fmt.allocPrint(self.allocator, "SELECT 1 FROM files WHERE hash = '{s}'", .{entry.name});
            defer self.allocator.free(query);

            var stmt = try self.store.db.prepare(query);
            defer stmt.deinit();

            if (try stmt.one(struct { val: i32 }, .{}, .{}) == null) {
                // File exists physically but not in DB. Re-register it.
                const stat = try dir.statFile(self.io, entry.name, .{});

                const insert_stmt = try std.fmt.allocPrint(self.allocator, "INSERT INTO files (hash, size, created_at) VALUES ('{s}', {d}, {d})", .{ entry.name, stat.size, now });
                defer self.allocator.free(insert_stmt);

                try self.store.db.exec(insert_stmt, .{}, .{});
                orphan_count += 1;
            }
        }

        if (orphan_count > 0) {
            std.debug.print("Re-indexed {d} orphaned blobs.\n", .{orphan_count});
        } else {
            std.debug.print("OK\n", .{});
        }
    }
};
