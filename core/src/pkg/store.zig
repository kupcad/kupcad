//! `Store`: the SQLite index of the global package store, which package commits are installed
//! and which blobs their files are, with its schema migrations. The SQLite calls are wrapped
//! in sqlite.zig and the packages' integrity hashes computed in integrity.zig.

const std = @import("std");

const sqlite = @import("sqlite");
const sql = @import("sqlite.zig");
pub const Db = sql.Db;
const string_map = @import("string_map.zig");
const clock = @import("clock.zig");

const log = std.log.scoped(.pkg);

/// How long a statement waits for another process's lock on the index (two installs at
/// once, an install while `pkg prune` runs) before failing with SQLITE_BUSY.
pub const BUSY_TIMEOUT_MS: c_int = 5000;
/// The index's schema (`PRAGMA user_version`); runMigrations brings older ones up to it.
/// v4: packages.last_used, when an install last used the package (see GarbageCollector).
/// v5: git host packages are indexed without their archive's top folder (see Cafs.ArchiveLayout).
pub const SCHEMA_VERSION: i32 = 5;

/// Deletes package_files rows whose (package_id, commit_sha) has no packages row.
const ORPHAN_PACKAGE_FILES_SQL =
    \\DELETE FROM package_files WHERE NOT EXISTS (
    \\    SELECT 1 FROM packages p
    \\    WHERE p.id = package_files.package_id AND p.commit_sha = package_files.commit_sha
    \\)
;

pub const Store = struct {
    db: Db,
    io: std.Io,

    pub fn init(io: std.Io, db_path: []const u8) !Store {
        const db_path_z = try std.heap.page_allocator.dupeSentinel(u8, db_path, 0);
        defer std.heap.page_allocator.free(db_path_z);

        var handle: ?*sqlite.sqlite3 = null;
        const rc = sqlite.sqlite3_open(db_path_z, &handle);
        // SQLite hands back a handle even when opening failed; it is closed like any other.
        errdefer _ = sqlite.sqlite3_close(handle);
        // Usually the path or its permissions, not corruption (which quick_check finds below).
        if (rc != sqlite.SQLITE_OK or handle == null) return error.SqliteOpenFailed;
        // Without it a locked index fails at once ("database is locked").
        if (sqlite.sqlite3_busy_timeout(handle, BUSY_TIMEOUT_MS) != sqlite.SQLITE_OK) return error.SqliteError;

        const db = Db{ .handle = handle };
        var store = Store{ .db = db, .io = io };

        {
            // Scoped so the statement is finalized before migrations run: an active
            // statement makes schema changes (DROP TABLE) fail with SQLITE_LOCKED.
            const integrity_stmt = try db.prepare("PRAGMA quick_check");
            defer integrity_stmt.deinit();
            const integrity_res = try integrity_stmt.one(struct { result: []const u8 }, .{});
            if (integrity_res) |res| {
                if (!std.mem.eql(u8, res.result, "ok")) {
                    log.err("the package index {s} is corrupted (PRAGMA quick_check failed); delete it to let the next install rebuild it", .{db_path});
                    return error.DatabaseCorrupted;
                }
            }
        }

        try store.runMigrations();
        return store;
    }

    pub fn deinit(self: *Store) void {
        self.db.deinit();
    }

    fn runMigrations(self: *Store) !void {
        const current_version = blk: {
            const version_stmt = try self.db.prepare("PRAGMA user_version");
            defer version_stmt.deinit();
            const current_version_row = try version_stmt.one(struct { user_version: i32 }, .{});
            break :blk if (current_version_row) |row| row.user_version else 0;
        };

        if (current_version < SCHEMA_VERSION) {
            log.info("Upgrading database schema from v{d} to v{d}...\n", .{ current_version, SCHEMA_VERSION });

            try self.db.exec("BEGIN TRANSACTION", .{});
            errdefer self.db.exec("ROLLBACK", .{}) catch |err| log.err("Rollback failed: {}", .{err});
            if (current_version < 1) {
                try self.db.exec(
                    \\CREATE TABLE IF NOT EXISTS packages (
                    \\    id TEXT PRIMARY KEY,
                    \\    commit_sha TEXT NOT NULL,
                    \\    provider TEXT NOT NULL,
                    \\    created_at INTEGER NOT NULL
                    \\)
                , .{});
                try self.db.exec(
                    \\CREATE TABLE IF NOT EXISTS files (
                    \\    hash TEXT PRIMARY KEY,
                    \\    size INTEGER NOT NULL,
                    \\    created_at INTEGER NOT NULL
                    \\)
                , .{});
                try self.db.exec(
                    \\CREATE TABLE IF NOT EXISTS package_files (
                    \\    package_id TEXT NOT NULL,
                    \\    commit_sha TEXT NOT NULL,
                    \\    file_path TEXT NOT NULL,
                    \\    file_hash TEXT NOT NULL,
                    \\    PRIMARY KEY (package_id, commit_sha, file_path),
                    \\    FOREIGN KEY (file_hash) REFERENCES files(hash)
                    \\)
                , .{});
                try self.db.exec(
                    \\CREATE TABLE IF NOT EXISTS meta (
                    \\    key TEXT PRIMARY KEY,
                    \\    value TEXT NOT NULL
                    \\)
                , .{});
            }
            if (current_version < 2) {
                try self.db.exec("ALTER TABLE packages ADD COLUMN integrity TEXT NOT NULL DEFAULT ''", .{});
            }
            if (current_version < 3) {
                // v3: a package may be cached at several commits. The v1 schema keyed
                // `packages` by id alone, so INSERT OR IGNORE silently dropped every
                // commit after the first. Rebuild with a composite key.
                try self.db.exec(
                    \\CREATE TABLE packages_v3 (
                    \\    id TEXT NOT NULL,
                    \\    commit_sha TEXT NOT NULL,
                    \\    provider TEXT NOT NULL,
                    \\    created_at INTEGER NOT NULL,
                    \\    integrity TEXT NOT NULL DEFAULT '',
                    \\    PRIMARY KEY (id, commit_sha)
                    \\)
                , .{});
                try self.db.exec(
                    \\INSERT INTO packages_v3 (id, commit_sha, provider, created_at, integrity)
                    \\SELECT id, commit_sha, provider, created_at, integrity FROM packages
                , .{});
                try self.db.exec("DROP TABLE packages", .{});
                try self.db.exec("ALTER TABLE packages_v3 RENAME TO packages", .{});
                // File mappings for commits that the old schema dropped are unreachable.
                try self.db.exec(ORPHAN_PACKAGE_FILES_SQL, .{});
            }
            if (current_version < 4) {
                try self.db.exec("ALTER TABLE packages ADD COLUMN last_used INTEGER NOT NULL DEFAULT 0", .{});
                try self.db.exec("UPDATE packages SET last_used = created_at", .{});
            }
            if (current_version < 5) {
                // Their files were indexed under the archive's top folder (`repo-<sha>/main.kup`),
                // which no import could reach; forget them so the next install fetches them again.
                try self.db.exec("DELETE FROM packages WHERE provider IN ('github', 'gitlab', 'gitea')", .{});
                try self.db.exec(ORPHAN_PACKAGE_FILES_SQL, .{});
            }
            var pragma_buf: [48]u8 = undefined;
            try self.db.exec(try std.mem.print(&pragma_buf, "PRAGMA user_version = {d}", .{SCHEMA_VERSION}), .{});
            try self.db.exec("COMMIT", .{});
        }
    }

    /// Removes a blob from the index *and* invalidates every package that referenced
    /// it, so a later install re-downloads the package instead of treating a
    /// partially-deleted package as cached.
    /// When the store was last pruned, in seconds since the epoch; 0 if never.
    pub fn lastPruneTime(self: *Store) !i64 {
        const stmt = try self.db.prepare("SELECT value FROM meta WHERE key = 'last_prune_time'");
        defer stmt.deinit();
        const row = (try stmt.one(struct { value: []const u8 }, .{})) orelse return 0;
        return std.fmt.parseInt(i64, row.value, 10) catch 0;
    }

    pub fn setLastPruneTime(self: *Store, seconds: i64) !void {
        var buf: [32]u8 = undefined;
        const text = try std.mem.print(&buf, "{d}", .{seconds});
        try self.db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_prune_time', ?)", .{text});
    }

    /// Whether SQLite's quick check finds the database sound.
    pub fn quickCheck(self: *Store) !bool {
        const stmt = try self.db.prepare("PRAGMA quick_check");
        defer stmt.deinit();
        const row = (try stmt.one(struct { result: []const u8 }, .{})) orelse return false;
        return std.mem.eql(u8, row.result, "ok");
    }

    /// The hash of every blob the index holds, each owned by `allocator` with the slice.
    pub fn blobHashes(self: *Store, allocator: std.mem.Allocator) ![][]u8 {
        const stmt = try self.db.prepare("SELECT hash FROM files");
        defer stmt.deinit();
        var hashes: std.ArrayList([]u8) = .empty;
        errdefer {
            for (hashes.items) |h| allocator.free(h);
            hashes.deinit(allocator);
        }
        var rows = try stmt.iterator(struct { hash: []const u8 }, .{});
        while (try rows.next()) |row| {
            const copy = try allocator.dupe(u8, row.hash);
            errdefer allocator.free(copy);
            try hashes.append(allocator, copy);
        }
        return hashes.toOwnedSlice(allocator);
    }

    /// Whether the index holds a blob named `hash`.
    pub fn hasBlob(self: *Store, hash: []const u8) !bool {
        const stmt = try self.db.prepare("SELECT 1 FROM files WHERE hash = ?");
        defer stmt.deinit();
        return try stmt.one(struct { found: i32 }, .{hash}) != null;
    }

    /// Indexes a blob that is on disk but missing from the index.
    pub fn indexBlob(self: *Store, hash: []const u8, size: i64, created_at: i64) !void {
        try self.db.exec("INSERT INTO files (hash, size, created_at) VALUES (?, ?, ?)", .{ hash, size, created_at });
    }

    pub fn evictBlob(self: *Store, hash: []const u8) !void {
        try self.db.exec("BEGIN TRANSACTION", .{});
        errdefer self.db.exec("ROLLBACK", .{}) catch |err| log.err("Rollback failed: {}", .{err});

        try self.db.exec(
            \\DELETE FROM packages WHERE EXISTS (
            \\    SELECT 1 FROM package_files pf
            \\    WHERE pf.package_id = packages.id AND pf.commit_sha = packages.commit_sha AND pf.file_hash = ?
            \\)
        , .{hash});
        try self.db.exec(ORPHAN_PACKAGE_FILES_SQL, .{});
        try self.db.exec("DELETE FROM files WHERE hash = ?", .{hash});

        try self.db.exec("COMMIT", .{});
    }

    /// Whether a package that an install used at or after `since` (Unix seconds) has the
    /// blob `hash`.
    pub fn blobUsedSince(self: *Store, hash: []const u8, since: i64) !bool {
        const stmt_sql =
            \\SELECT 1 FROM package_files pf
            \\JOIN packages p ON p.id = pf.package_id AND p.commit_sha = pf.commit_sha
            \\WHERE pf.file_hash = ? AND p.last_used >= ? LIMIT 1
        ;
        var stmt = try self.db.prepare(stmt_sql);
        defer stmt.deinit();
        return (try stmt.one(struct { val: i32 }, .{ hash, since })) != null;
    }

    /// Checks whether a package commit_sha exists in the offline store
    pub fn hasPackage(self: *Store, pkg_id: []const u8, commit_sha: []const u8) !bool {
        const stmt_sql =
            \\SELECT 1 FROM packages WHERE id = ? AND commit_sha = ? LIMIT 1
        ;
        var stmt = try self.db.prepare(stmt_sql);
        defer stmt.deinit();

        const row = try stmt.one(struct { val: i32 }, .{ pkg_id, commit_sha });
        return row != null;
    }

    /// Retrieves cached package file mappings `[file_path -> file_hash]` if present in store
    pub fn getPackageFiles(
        self: *Store,
        allocator: std.mem.Allocator,
        pkg_id: []const u8,
        commit_sha: []const u8,
    ) !?std.StringHashMap([]const u8) {
        if (!try self.hasPackage(pkg_id, commit_sha)) return null;

        const stmt_sql =
            \\SELECT file_path, file_hash FROM package_files WHERE package_id = ? AND commit_sha = ?
        ;
        var stmt = try self.db.prepare(stmt_sql);
        defer stmt.deinit();

        var map = std.StringHashMap([]const u8).init(allocator);
        errdefer string_map.deinitOwned(allocator, &map);

        var iter = try stmt.iterator(struct { file_path: []const u8, file_hash: []const u8 }, .{ pkg_id, commit_sha });
        while (try iter.next()) |row| {
            const k = try allocator.dupe(u8, row.file_path);
            errdefer allocator.free(k);
            const v = try allocator.dupe(u8, row.file_hash);
            errdefer allocator.free(v);
            try map.put(k, v);
        }

        return map;
    }

    pub fn registerPackage(
        self: *Store,
        pkg_id: []const u8,
        commit_sha: []const u8,
        provider_name: []const u8,
        integrity: []const u8,
        files_map: *std.StringHashMap([]const u8),
    ) !void {
        try self.db.exec("BEGIN TRANSACTION", .{});
        errdefer self.db.exec("ROLLBACK", .{}) catch |err| log.err("Rollback failed: {}", .{err});

        const now = clock.nowSeconds(self.io);

        // Upsert keyed by (id, commit_sha): a new commit of an existing package must
        // be recorded, and re-registering the same commit refreshes its metadata.
        // Registering is also how an install uses a cached package, so it is the last use.
        const pkg_stmt =
            \\INSERT INTO packages (id, commit_sha, provider, integrity, created_at, last_used)
            \\VALUES (?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(id, commit_sha) DO UPDATE SET provider = excluded.provider, integrity = excluded.integrity, last_used = excluded.last_used
        ;
        try self.db.exec(pkg_stmt, .{ pkg_id, commit_sha, provider_name, integrity, now, now });

        // Replace (not merge) the file mapping so it exactly matches the verified content.
        try self.db.exec("DELETE FROM package_files WHERE package_id = ? AND commit_sha = ?", .{ pkg_id, commit_sha });

        // Two statements for the whole package; they were prepared again for every file.
        const file_stmt = try self.db.prepare(
            \\INSERT OR IGNORE INTO files (hash, size, created_at)
            \\VALUES (?, 0, ?)
        );
        defer file_stmt.deinit();
        const mapping_stmt = try self.db.prepare(
            \\INSERT OR IGNORE INTO package_files (package_id, commit_sha, file_path, file_hash)
            \\VALUES (?, ?, ?, ?)
        );
        defer mapping_stmt.deinit();

        var files_it = files_map.iterator();
        while (files_it.next()) |entry| {
            const file_path = entry.key_ptr.*;
            const file_hash = entry.value_ptr.*;
            try file_stmt.exec(.{ file_hash, now });
            try mapping_stmt.exec(.{ pkg_id, commit_sha, file_path, file_hash });
        }
        try self.db.exec("COMMIT", .{});
    }
};
