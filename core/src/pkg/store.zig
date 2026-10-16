//! `Store`: the SQLite index of the global package store, which package commits are installed
//! and which blobs their files are, with schema migrations and the packages' integrity hashes
//! (`computeIntegrity`, `verifyIntegrity`). `Db` and `Stmt` wrap the SQLite calls.

const std = @import("std");

const sqlite = @import("sqlite");

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

pub const Db = struct {
    handle: ?*sqlite.sqlite3,

    /// Runs `sql` once with `args`. A statement run for each of many rows is prepared
    /// once with `prepare` and run with `Stmt.exec`.
    pub fn exec(self: Db, sql: []const u8, args: anytype) !void {
        const stmt = try self.prepare(sql);
        defer stmt.deinit();
        try stmt.exec(args);
    }

    /// SQLite takes the statement's length, so the text needs no copy (one went through
    /// the page allocator per statement).
    pub fn prepare(self: Db, sql: []const u8) !Stmt {
        var stmt_handle: ?*sqlite.sqlite3_stmt = null;
        const rc = sqlite.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt_handle, null);
        if (rc != sqlite.SQLITE_OK or stmt_handle == null) return error.SqliteError;

        return Stmt{ .handle = stmt_handle.? };
    }

    pub fn deinit(self: *Db) void {
        if (self.handle) |h| {
            _ = sqlite.sqlite3_close(h);
            self.handle = null;
        }
    }
};

pub const Stmt = struct {
    handle: *sqlite.sqlite3_stmt,

    pub fn deinit(self: Stmt) void {
        _ = sqlite.sqlite3_finalize(self.handle);
    }

    /// Binds `args`, a tuple of strings and integers, to the statement's `?`s in order. A
    /// type it can't bind is a compile error, and a bind SQLite refuses (more arguments than
    /// placeholders) an error: both were skipped, leaving that placeholder NULL.
    fn bindArgs(self: Stmt, args: anytype) !void {
        const args_info = @typeInfo(@TypeOf(args));
        if (args_info != .@"struct" or !args_info.@"struct".is_tuple) @compileError("SQL arguments are a tuple, such as .{ id, name }");
        inline for (args, 1..) |arg, idx| {
            const ArgType = @TypeOf(arg);
            const rc = if (@typeInfo(ArgType) == .pointer) text: {
                const slice: []const u8 = arg;
                break :text sqlite.sqlite3_bind_text(self.handle, @intCast(idx), slice.ptr, @intCast(slice.len), null);
            } else if (ArgType == i64 or ArgType == i32 or ArgType == usize or ArgType == comptime_int)
                sqlite.sqlite3_bind_int64(self.handle, @intCast(idx), @intCast(arg))
            else
                @compileError("an SQL argument is a string or an integer, not " ++ @typeName(ArgType));
            if (rc != sqlite.SQLITE_OK) return error.SqliteError;
        }
    }

    /// Resets the statement and binds `args`, ready to step.
    fn rebind(self: Stmt, args: anytype) !void {
        _ = sqlite.sqlite3_reset(self.handle);
        _ = sqlite.sqlite3_clear_bindings(self.handle);
        try self.bindArgs(args);
    }

    /// Runs the statement with `args` for its effect (an insert, a delete).
    pub fn exec(self: Stmt, args: anytype) !void {
        try self.rebind(args);
        const rc = sqlite.sqlite3_step(self.handle);
        if (rc != sqlite.SQLITE_DONE and rc != sqlite.SQLITE_ROW) return error.SqliteError;
    }

    pub fn one(self: Stmt, comptime T: type, args: anytype) !?T {
        try self.rebind(args);
        return readRow(T, self.handle);
    }

    /// Steps `handle` once: the next row, null when there are none, and a step that fails
    /// (busy, I/O, corruption, an overflowing expression) is an error. It used to read as
    /// "no more rows", so a package could be linked from half its files and reported done.
    fn readRow(comptime T: type, handle: *sqlite.sqlite3_stmt) !?T {
        const rc = sqlite.sqlite3_step(handle);
        if (rc == sqlite.SQLITE_DONE) return null;
        if (rc != sqlite.SQLITE_ROW) return error.SqliteError;
        // SAFETY: All fields are immediately populated via reflection from sqlite3_column_* below.
        var result: T = undefined;
        inline for (@typeInfo(T).@"struct".field_names, 0..) |field_name, i| {
            const field_type = @typeInfo(T).@"struct".field_types[i];
            if (field_type == []const u8) {
                const ptr = sqlite.sqlite3_column_text(handle, @intCast(i));
                const len = sqlite.sqlite3_column_bytes(handle, @intCast(i));
                @field(result, field_name) = if (ptr != null) ptr[0..@intCast(len)] else "";
            } else if (field_type == i32 or field_type == i64) {
                @field(result, field_name) = @intCast(sqlite.sqlite3_column_int64(handle, @intCast(i)));
            } else {
                // A field of another type was skipped and read as whatever was in memory.
                @compileError("an SQL row field is a []const u8, an i32 or an i64, not " ++ @typeName(field_type));
            }
        }
        return result;
    }

    pub fn iterator(self: Stmt, comptime T: type, args: anytype) !Iterator(T) {
        try self.rebind(args);
        return Iterator(T){ .stmt = self };
    }

    pub fn Iterator(comptime T: type) type {
        return struct {
            stmt: Stmt,

            pub fn next(self: *@This()) !?T {
                return readRow(T, self.stmt.handle);
            }
        };
    }
};

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
            try self.db.exec(try std.fmt.bufPrint(&pragma_buf, "PRAGMA user_version = {d}", .{SCHEMA_VERSION}), .{});
            try self.db.exec("COMMIT", .{});
        }
    }

    pub const IntegrityAlgo = enum {
        /// v2 (lockfile >= 2.0.0): length-prefixed fields, unambiguous.
        current,
        /// v1 (lockfile 1.x): plain `path || hash` concatenation. Ambiguous
        /// (("ab","c") == ("a","bc")); only used to verify old lockfiles before upgrading them.
        legacy,
    };

    /// How an integrity was taken, so an old lockfile's can still be checked.
    pub const IntegrityScheme = struct {
        algo: IntegrityAlgo = .current,
        /// The folder every path was hashed under: before lockfile 3.0.0, a git host
        /// archive's files kept its top folder (`repo-<sha>/main.kup`). Empty: none.
        root: []const u8 = "",
    };

    /// Computes a deterministic Merkle-style checksum of extracted package files.
    /// Each path and hash is length-prefixed (u64 LE) so distinct file maps can
    /// never produce the same hash input.
    pub fn computeIntegrity(allocator: std.mem.Allocator, files_map: *const std.StringHashMap([]const u8)) ![]const u8 {
        return computeIntegrityWith(allocator, files_map, .{});
    }

    pub fn computeIntegrityWith(allocator: std.mem.Allocator, files_map: *const std.StringHashMap([]const u8), scheme: IntegrityScheme) ![]const u8 {
        var paths = std.ArrayListUnmanaged([]const u8).empty;
        defer paths.deinit(allocator);

        var it = files_map.keyIterator();
        while (it.next()) |k| try paths.append(allocator, k.*);

        // Deterministic sorting ensures the hash is identical across environments
        std.mem.sort([]const u8, paths.items, {}, struct {
            pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        // A common folder doesn't change the order, so it is only added while hashing.
        const folder: []const []const u8 = if (scheme.root.len > 0) &.{ scheme.root, "/" } else &.{};
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (paths.items) |path| {
            const hash = files_map.get(path).?;
            switch (scheme.algo) {
                .current => {
                    hashLenPrefixed(&hasher, folder, path);
                    hashLenPrefixed(&hasher, &.{}, hash);
                },
                .legacy => {
                    for (folder) |part| hasher.update(part);
                    hasher.update(path);
                    hasher.update(hash);
                },
            }
        }

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);

        const hex = std.fmt.bytesToHex(digest, .lower);
        return allocator.print("sha256-{s}", .{hex});
    }

    /// Hashes `prefix ++ bytes` after its length.
    fn hashLenPrefixed(hasher: *std.crypto.hash.sha2.Sha256, prefix: []const []const u8, bytes: []const u8) void {
        var len: u64 = bytes.len;
        for (prefix) |part| len += part.len;
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, len, .little);
        hasher.update(&len_buf);
        for (prefix) |part| hasher.update(part);
        hasher.update(bytes);
    }

    /// Fails with error.IntegrityMismatch unless `files_map` hashes to `expected`.
    pub fn verifyIntegrity(
        allocator: std.mem.Allocator,
        files_map: *const std.StringHashMap([]const u8),
        expected: []const u8,
        scheme: IntegrityScheme,
    ) !void {
        const actual = try computeIntegrityWith(allocator, files_map, scheme);
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, expected)) return error.IntegrityMismatch;
    }

    /// Frees a `[path -> hash]` map whose keys and values are owned by `allocator`.
    pub fn freeFileMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    /// Removes a blob from the index *and* invalidates every package that referenced
    /// it, so a later install re-downloads the package instead of treating a
    /// partially-deleted package as cached.
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
        errdefer {
            var it = map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            map.deinit();
        }

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

        const now_ns = std.Io.Clock.real.now(self.io).nanoseconds;
        const now: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));

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
