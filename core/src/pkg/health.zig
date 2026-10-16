//! `kupcad pkg doctor`: `Doctor.run` checks the package database's SQLite integrity, evicts
//! index entries whose blob file is gone from the content-addressed store, and re-registers
//! blob files the index doesn't list, printing each step.

const std = @import("std");
const Cafs = @import("cafs.zig").Cafs;
const Store = @import("store.zig").Store;
const Printer = @import("../log.zig").Printer;
const clock = @import("clock.zig");

const log = std.log.scoped(.pkg);

pub const Doctor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cafs: *Cafs,
    store: *Store,
    /// Where the report goes (each check and what was healed).
    printer: Printer,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cafs: *Cafs, store: *Store, printer: Printer) Doctor {
        return .{
            .allocator = allocator,
            .io = io,
            .cafs = cafs,
            .store = store,
            .printer = printer,
        };
    }

    /// Audits and heals the CAFS and database state
    pub fn run(self: *Doctor) !void {
        self.printer.print("Running KupCAD Doctor...\n", .{});

        try self.checkDbIntegrity();
        try self.healMissingBlobs();
        try self.healOrphanedBlobs();

        self.printer.print("System health check complete.\n", .{});
    }

    fn checkDbIntegrity(self: *Doctor) !void {
        self.printer.print("[1/3] Checking SQLite integrity... ", .{});
        const stmt = try self.store.db.prepare("PRAGMA quick_check");
        defer stmt.deinit();

        if (try stmt.one(struct { result: []const u8 }, .{})) |row| {
            if (std.mem.eql(u8, row.result, "ok")) {
                self.printer.print("OK\n", .{});
                return;
            }
        }

        log.err("CORRUPTED!\n", .{});
        return error.DatabaseCorrupted;
    }

    fn healMissingBlobs(self: *Doctor) !void {
        self.printer.print("[2/3] Scanning for missing physical files... ", .{});

        const query = "SELECT hash FROM files";
        var stmt = try self.store.db.prepare(query);
        defer stmt.deinit();

        var rows = try stmt.iterator(struct { hash: []const u8 }, .{});
        const cwd = std.Io.Dir.cwd();
        var missing_count: usize = 0;

        // Collect first: mutating `files` while stepping a SELECT over it is unsafe.
        var missing: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (missing.items) |h| self.allocator.free(h);
            missing.deinit(self.allocator);
        }

        while (try rows.next()) |row| {
            const final_path = try self.allocator.print("{s}/files/{s}", .{ self.cafs.global_dir_path, row.hash });
            defer self.allocator.free(final_path);

            const file_exists = if (cwd.openFile(self.io, final_path, .{})) |f| blk: {
                f.close(self.io);
                break :blk true;
            } else |_| false;

            if (!file_exists) try missing.append(self.allocator, try self.allocator.dupe(u8, row.hash));
        }

        for (missing.items) |hash| {
            // Evict blob + dependent packages (bound params) so they get re-downloaded next install
            try self.store.evictBlob(hash);
            missing_count += 1;
        }

        if (missing_count > 0) {
            log.warn("Evicted {d} missing blobs from index. Run 'kupcad pkg install' to repair.\n", .{missing_count});
        } else {
            self.printer.print("OK\n", .{});
        }
    }

    fn healOrphanedBlobs(self: *Doctor) !void {
        self.printer.print("[3/3] Scanning for orphaned physical files... ", .{});

        const files_path = try self.allocator.print("{s}/files", .{self.cafs.global_dir_path});
        defer self.allocator.free(files_path);

        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(self.io, files_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var it = dir.iterate();
        var orphan_count: usize = 0;
        const now = clock.nowSeconds(self.io);

        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;

            // Check if hash exists in DB (bound params: file names are not trusted SQL)
            var stmt = try self.store.db.prepare("SELECT 1 FROM files WHERE hash = ?");
            defer stmt.deinit();

            if (try stmt.one(struct { val: i32 }, .{entry.name}) == null) {
                // File exists physically but not in DB. Re-register it.
                const stat = try dir.statFile(self.io, entry.name, .{});
                const size: i64 = @intCast(stat.size);
                const created_at: i64 = @intCast(now);

                try self.store.db.exec("INSERT INTO files (hash, size, created_at) VALUES (?, ?, ?)", .{ entry.name, size, created_at });
                orphan_count += 1;
            }
        }

        if (orphan_count > 0) {
            log.warn("Re-indexed {d} orphaned blobs.\n", .{orphan_count});
        } else {
            self.printer.print("OK\n", .{});
        }
    }
};
