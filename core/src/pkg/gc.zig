const std = @import("std");
const Cafs = @import("cafs.zig").Cafs;
const Store = @import("store.zig").Store;
const log = @import("log.zig");

pub const GarbageCollector = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cafs: *Cafs,
    store: *Store,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cafs: *Cafs, store: *Store) GarbageCollector {
        return .{
            .allocator = allocator,
            .io = io,
            .cafs = cafs,
            .store = store,
        };
    }

    /// Prunes unused blobs from the CAFS and the SQLite index
    pub fn prune(self: *GarbageCollector, force: bool) !void {
        const files_path = try std.fmt.allocPrint(self.allocator, "{s}/files", .{self.cafs.global_dir_path});
        defer self.allocator.free(files_path);

        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(self.io, files_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return, // Nothing to prune
            else => return err,
        };
        defer dir.close(self.io);

        const now_ts = std.Io.Clock.real.now(self.io);
        const seven_days_ns: i64 = 7 * 24 * 60 * 60 * std.time.ns_per_s;
        var pruned_count: usize = 0;
        var bytes_freed: u64 = 0;

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;

            const stat = try dir.statFile(self.io, entry.name, .{});

            // If nlink > 1, the file is currently used by a project
            if (stat.nlink > 1) continue;

            // Direct nanosecond duration check between stat.mtime and now_ts
            const age_ns = stat.mtime.durationTo(now_ts).nanoseconds;
            if (!force and age_ns < seven_days_ns) continue;

            // Delete physical file
            try dir.deleteFile(self.io, entry.name);
            pruned_count += 1;
            bytes_freed += stat.size;

            // Remove from SQLite index
            const delete_stmt = try std.fmt.allocPrint(self.allocator, "DELETE FROM files WHERE hash = '{s}'", .{entry.name});
            defer self.allocator.free(delete_stmt);
            try self.store.db.exec(delete_stmt, .{}, .{});
        }

        log.print("Pruned {d} files, freeing {d} bytes.\n", .{ pruned_count, bytes_freed });

        // Update last_prune_time in meta table (Unix epoch seconds)
        const now_sec = @divFloor(now_ts.nanoseconds, std.time.ns_per_s);
        const update_meta = try std.fmt.allocPrint(self.allocator, "INSERT OR REPLACE INTO meta (key, value) VALUES ('last_prune_time', '{d}')", .{now_sec});
        defer self.allocator.free(update_meta);
        try self.store.db.exec(update_meta, .{}, .{});
    }

    /// Executed post-install. Only runs if 7 days have passed since the last prune.
    pub fn lazyPrune(self: *GarbageCollector) !void {
        const stmt = try self.store.db.prepare("SELECT value FROM meta WHERE key = 'last_prune_time'");
        defer stmt.deinit();

        var last_prune: i64 = 0;
        if (try stmt.one(struct { value: []const u8 }, .{}, .{})) |row| {
            last_prune = std.fmt.parseInt(i64, row.value, 10) catch 0;
        }

        const now_ts = std.Io.Clock.real.now(self.io);
        const now_sec = @divFloor(now_ts.nanoseconds, std.time.ns_per_s);
        const seven_days_sec: i64 = 7 * 24 * 60 * 60;

        if (now_sec - last_prune > seven_days_sec) {
            log.print("Running scheduled background cleanup...\n", .{});
            try self.prune(false);
        }
    }
};
