const std = @import("std");
const Cafs = @import("cafs.zig").Cafs;
const Store = @import("store.zig").Store;
const Printer = @import("../log.zig").Printer;

const log = std.log.scoped(.pkg);

/// How long the store keeps what no project links: a blob written, or a package an
/// install used, this recently stays; lazyPrune runs at most this often.
pub const RETENTION_SECONDS: i64 = 7 * 24 * 60 * 60;

pub const GarbageCollector = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cafs: *Cafs,
    store: *Store,
    /// Where the results go (what was pruned).
    printer: Printer,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cafs: *Cafs, store: *Store, printer: Printer) GarbageCollector {
        return .{
            .allocator = allocator,
            .io = io,
            .cafs = cafs,
            .store = store,
            .printer = printer,
        };
    }

    /// Prunes unused blobs from the CAFS and the SQLite index. A blob stays while a project
    /// hard-links it; unless `force`, also while it, or a package an install used, is
    /// younger than RETENTION_SECONDS. Where a project holds a copy instead (the store on
    /// another device), the link count can't show the use: a package installed a moment
    /// ago from old blobs used to be pruned, and evicted, right after.
    pub fn prune(self: *GarbageCollector, force: bool) !void {
        const files_path = try self.allocator.print("{s}/files", .{self.cafs.global_dir_path});
        defer self.allocator.free(files_path);

        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(self.io, files_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return, // Nothing to prune
            else => return err,
        };
        defer dir.close(self.io);

        const now_ts = std.Io.Clock.real.now(self.io);
        const now_sec: i64 = @intCast(@divFloor(now_ts.nanoseconds, std.time.ns_per_s));
        const retention_ns: i96 = @as(i96, RETENTION_SECONDS) * std.time.ns_per_s;
        var pruned_count: usize = 0;
        var bytes_freed: u64 = 0;

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;

            const stat = try dir.statFile(self.io, entry.name, .{});

            // If nlink > 1, the file is currently used by a project
            if (stat.nlink > 1) continue;

            if (!force) {
                if (stat.mtime.durationTo(now_ts).nanoseconds < retention_ns) continue;
                if (try self.store.blobUsedSince(entry.name, now_sec - RETENTION_SECONDS)) continue;
            }

            // Delete physical file
            try dir.deleteFile(self.io, entry.name);
            pruned_count += 1;
            bytes_freed += stat.size;

            // Remove from the index and invalidate every package that referenced the
            // blob; otherwise the package still looks cached and linking fails later.
            // (Bound parameter: file names in the CAFS dir are not trusted SQL.)
            try self.store.evictBlob(entry.name);
        }

        self.printer.print("Pruned {d} files, freeing {d} bytes.\n", .{ pruned_count, bytes_freed });

        // Update last_prune_time in meta table (Unix epoch seconds)
        var now_buf: [32]u8 = undefined;
        const now_str = try std.fmt.bufPrint(&now_buf, "{d}", .{now_sec});
        try self.store.db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_prune_time', ?)", .{now_str}, .{});
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

        if (now_sec - last_prune > RETENTION_SECONDS) {
            self.printer.print("Running scheduled background cleanup...\n", .{});
            try self.prune(false);
        }
    }
};
