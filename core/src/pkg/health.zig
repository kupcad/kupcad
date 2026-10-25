//! `kupcad pkg doctor`: `Doctor.run` checks the package database's SQLite integrity, evicts
//! index entries whose blob file is gone from the content-addressed store or doesn't hold
//! what its name says (removing it), and re-registers blob files the index doesn't list
//! that do, printing each step.

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
        if (try self.store.quickCheck()) {
            self.printer.print("OK\n", .{});
            return;
        }

        log.err("CORRUPTED!\n", .{});
        return error.DatabaseCorrupted;
    }

    fn healMissingBlobs(self: *Doctor) !void {
        self.printer.print("[2/3] Scanning for missing or corrupt physical files... ", .{});

        // Listed first, as evicting while stepping a SELECT over the same table is unsafe.
        const hashes = try self.store.blobHashes(self.allocator);
        defer {
            for (hashes) |h| self.allocator.free(h);
            self.allocator.free(hashes);
        }
        const cwd = std.Io.Dir.cwd();
        var missing_count: usize = 0;
        for (hashes) |hash| {
            const final_path = try self.allocator.print("{s}/files/{s}", .{ self.cafs.global_dir_path, hash });
            defer self.allocator.free(final_path);
            const file_exists = if (cwd.openFile(self.io, final_path, .{})) |f| blk: {
                f.close(self.io);
                break :blk true;
            } else |_| false;
            // There, it must hold what its name says: a changed one would be linked into
            // every project installing it (linkBlob refuses it, too late to repair then)
            if (file_exists) {
                if (try self.cafs.isIntact(hash)) continue;
                cwd.deleteFile(self.io, final_path) catch |err| log.warn("Could not remove the corrupt blob {s}: {}", .{ hash, err });
            }
            // Evict blob + dependent packages so they get re-downloaded next install
            try self.store.evictBlob(hash);
            missing_count += 1;
        }

        if (missing_count > 0) {
            log.warn("Evicted {d} missing or corrupt blobs from index. Run 'kupcad pkg install' to repair.\n", .{missing_count});
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
            // A blob's name is its SHA-256: any other file (a .DS_Store) is none of the store's
            if (entry.kind != .file or !Cafs.isBlobName(entry.name)) continue;

            // File names are bound as parameters: they are not trusted SQL.
            if (try self.store.hasBlob(entry.name)) continue;
            // File exists physically but not in DB. Re-register it, if it is what its name says
            if (!try self.cafs.isIntact(entry.name)) {
                dir.deleteFile(self.io, entry.name) catch |err| log.warn("Could not remove the corrupt blob {s}: {}", .{ entry.name, err });
                continue;
            }
            const stat = try dir.statFile(self.io, entry.name, .{});
            try self.store.indexBlob(entry.name, @intCast(stat.size), now);
            orphan_count += 1;
        }

        if (orphan_count > 0) {
            log.warn("Re-indexed {d} orphaned blobs.\n", .{orphan_count});
        } else {
            self.printer.print("OK\n", .{});
        }
    }
};
