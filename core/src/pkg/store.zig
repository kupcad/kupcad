const std = @import("std");

const sqlite = @import("sqlite");

const log = std.log.scoped(.pkg);

pub const Db = struct {
    handle: ?*sqlite.sqlite3,

    pub fn exec(self: Db, sql: []const u8, args: anytype, options: anytype) !void {
        _ = options;
        const sql_z = try std.heap.page_allocator.dupeSentinel(u8, sql, 0);
        defer std.heap.page_allocator.free(sql_z);

        var stmt: ?*sqlite.sqlite3_stmt = null;
        const rc_prep = sqlite.sqlite3_prepare_v2(self.handle, sql_z, -1, &stmt, null);
        if (rc_prep != sqlite.SQLITE_OK or stmt == null) return error.SqliteError;
        defer _ = sqlite.sqlite3_finalize(stmt);

        const ArgsType = @TypeOf(args);
        const args_info = @typeInfo(ArgsType);
        if (args_info == .@"struct" and args_info.@"struct".is_tuple) {
            inline for (args, 1..) |arg, idx| {
                const ArgType = @TypeOf(arg);
                if (@typeInfo(ArgType) == .pointer) {
                    const slice: []const u8 = arg;
                    _ = sqlite.sqlite3_bind_text(stmt, @intCast(idx), slice.ptr, @intCast(slice.len), null);
                } else if (ArgType == i64 or ArgType == i32 or ArgType == usize) {
                    _ = sqlite.sqlite3_bind_int64(stmt, @intCast(idx), @intCast(arg));
                }
            }
        }

        const rc = sqlite.sqlite3_step(stmt);
        if (rc != sqlite.SQLITE_DONE and rc != sqlite.SQLITE_ROW) return error.SqliteError;
    }

    pub fn prepare(self: Db, sql: []const u8) !Stmt {
        const sql_z = try std.heap.page_allocator.dupeSentinel(u8, sql, 0);
        defer std.heap.page_allocator.free(sql_z);

        var stmt_handle: ?*sqlite.sqlite3_stmt = null;
        const rc = sqlite.sqlite3_prepare_v2(self.handle, sql_z, -1, &stmt_handle, null);
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

    fn bindArgs(self: Stmt, args: anytype) void {
        const ArgsType = @TypeOf(args);
        const args_info = @typeInfo(ArgsType);
        if (args_info == .@"struct" and args_info.@"struct".is_tuple) {
            inline for (args, 1..) |arg, idx| {
                const ArgType = @TypeOf(arg);
                if (@typeInfo(ArgType) == .pointer) {
                    const slice: []const u8 = arg;
                    _ = sqlite.sqlite3_bind_text(self.handle, @intCast(idx), slice.ptr, @intCast(slice.len), null);
                } else if (ArgType == i64 or ArgType == i32 or ArgType == usize) {
                    _ = sqlite.sqlite3_bind_int64(self.handle, @intCast(idx), @intCast(arg));
                }
            }
        }
    }

    pub fn one(self: Stmt, comptime T: type, args: anytype, options: anytype) !?T {
        _ = options;
        _ = sqlite.sqlite3_reset(self.handle);
        _ = sqlite.sqlite3_clear_bindings(self.handle);
        self.bindArgs(args);

        const rc = sqlite.sqlite3_step(self.handle);
        if (rc == sqlite.SQLITE_ROW) {
            var result: T = undefined;
            inline for (@typeInfo(T).@"struct".field_names, 0..) |field_name, i| {
                const filed_type = @typeInfo(T).@"struct".field_types[i];
                if (filed_type == []const u8) {
                    const ptr = sqlite.sqlite3_column_text(self.handle, @intCast(i));
                    const len = sqlite.sqlite3_column_bytes(self.handle, @intCast(i));
                    @field(result, field_name) = if (ptr != null) ptr[0..@intCast(len)] else "";
                } else if (filed_type == i32 or filed_type == i64) {
                    @field(result, field_name) = @intCast(sqlite.sqlite3_column_int64(self.handle, @intCast(i)));
                }
            }
            return result;
        }
        return null;
    }

    pub fn iterator(self: Stmt, comptime T: type, args: anytype) !Iterator(T) {
        _ = sqlite.sqlite3_reset(self.handle);
        _ = sqlite.sqlite3_clear_bindings(self.handle);
        self.bindArgs(args);

        return Iterator(T){ .stmt = self };
    }

    pub fn Iterator(comptime T: type) type {
        return struct {
            stmt: Stmt,

            pub fn next(self: *@This()) !?T {
                const rc = sqlite.sqlite3_step(self.stmt.handle);
                if (rc == sqlite.SQLITE_ROW) {
                    var result: T = undefined;
                    inline for (@typeInfo(T).@"struct".field_names, 0..) |field_name, i| {
                        const filed_type = @typeInfo(T).@"struct".field_types[i];
                        if (filed_type == []const u8) {
                            const ptr = sqlite.sqlite3_column_text(self.stmt.handle, @intCast(i));
                            const len = sqlite.sqlite3_column_bytes(self.stmt.handle, @intCast(i));
                            @field(result, field_name) = if (ptr != null) ptr[0..@intCast(len)] else "";
                        } else if (filed_type == i32 or filed_type == i64) {
                            @field(result, field_name) = @intCast(sqlite.sqlite3_column_int64(self.stmt.handle, @intCast(i)));
                        }
                    }
                    return result;
                }
                return null;
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
        if (rc != sqlite.SQLITE_OK or handle == null) return error.DatabaseCorrupted;

        const db = Db{ .handle = handle };
        var store = Store{ .db = db, .io = io };

        const integrity_stmt = try db.prepare("PRAGMA quick_check");
        defer integrity_stmt.deinit();
        const integrity_res = try integrity_stmt.one(struct { result: []const u8 }, .{}, .{});
        if (integrity_res) |res| {
            if (!std.mem.eql(u8, res.result, "ok")) {
                log.err("CRITICAL: SQLite database is corrupted! Self-healing triggered...\n", .{});
                return error.DatabaseCorrupted;
            }
        }

        try store.runMigrations();
        return store;
    }

    pub fn deinit(self: *Store) void {
        self.db.deinit();
    }

    fn runMigrations(self: *Store) !void {
        const version_stmt = try self.db.prepare("PRAGMA user_version");
        defer version_stmt.deinit();
        const current_version_row = try version_stmt.one(struct { user_version: i32 }, .{}, .{});
        const current_version = if (current_version_row) |row| row.user_version else 0;

        const TARGET_VERSION: i32 = 2;

        if (current_version < TARGET_VERSION) {
            log.info("Upgrading database schema from v{d} to v{d}...\n", .{ current_version, TARGET_VERSION });

            try self.db.exec("BEGIN TRANSACTION", .{}, .{});
            if (current_version < 1) {
                try self.db.exec(
                    \\CREATE TABLE IF NOT EXISTS packages (
                    \\    id TEXT PRIMARY KEY,
                    \\    commit_sha TEXT NOT NULL,
                    \\    provider TEXT NOT NULL,
                    \\    created_at INTEGER NOT NULL
                    \\)
                , .{}, .{});
                try self.db.exec(
                    \\CREATE TABLE IF NOT EXISTS files (
                    \\    hash TEXT PRIMARY KEY,
                    \\    size INTEGER NOT NULL,
                    \\    created_at INTEGER NOT NULL
                    \\)
                , .{}, .{});
                try self.db.exec(
                    \\CREATE TABLE IF NOT EXISTS package_files (
                    \\    package_id TEXT NOT NULL,
                    \\    commit_sha TEXT NOT NULL,
                    \\    file_path TEXT NOT NULL,
                    \\    file_hash TEXT NOT NULL,
                    \\    PRIMARY KEY (package_id, commit_sha, file_path),
                    \\    FOREIGN KEY (file_hash) REFERENCES files(hash)
                    \\)
                , .{}, .{});
                try self.db.exec(
                    \\CREATE TABLE IF NOT EXISTS meta (
                    \\    key TEXT PRIMARY KEY,
                    \\    value TEXT NOT NULL
                    \\)
                , .{}, .{});
            }
            if (current_version < 2) {
                try self.db.exec("ALTER TABLE packages ADD COLUMN integrity TEXT NOT NULL DEFAULT ''", .{}, .{});
            }
            const update_pragma = try std.fmt.allocPrint(std.heap.page_allocator, "PRAGMA user_version = {d}", .{TARGET_VERSION});
            defer std.heap.page_allocator.free(update_pragma);
            try self.db.exec(update_pragma, .{}, .{});
            try self.db.exec("COMMIT", .{}, .{});
        }
    }

    /// Computes a deterministic Merkle-style checksum of extracted package files
    pub fn computeIntegrity(allocator: std.mem.Allocator, files_map: *const std.StringHashMap([]const u8)) ![]const u8 {
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

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (paths.items) |path| {
            const hash = files_map.get(path).?;
            hasher.update(path);
            hasher.update(hash);
        }

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);

        const hex = std.fmt.bytesToHex(digest, .lower);
        return std.fmt.allocPrint(allocator, "sha256-{s}", .{hex});
    }

    /// Checks whether a package commit_sha exists in the offline store
    pub fn hasPackage(self: *Store, pkg_id: []const u8, commit_sha: []const u8) !bool {
        const stmt_sql =
            \\SELECT 1 FROM packages WHERE id = ? AND commit_sha = ? LIMIT 1
        ;
        var stmt = try self.db.prepare(stmt_sql);
        defer stmt.deinit();

        const row = try stmt.one(struct { val: i32 }, .{ pkg_id, commit_sha }, .{});
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
        try self.db.exec("BEGIN TRANSACTION", .{}, .{});
        errdefer self.db.exec("ROLLBACK", .{}, .{}) catch {};

        const now_ns = std.Io.Clock.real.now(self.io).nanoseconds;
        const now: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));

        const pkg_stmt =
            \\INSERT OR IGNORE INTO packages (id, commit_sha, provider, integrity, created_at)
            \\VALUES (?, ?, ?, ?, ?)
        ;
        try self.db.exec(pkg_stmt, .{ pkg_id, commit_sha, provider_name, integrity, now }, .{});

        var files_it = files_map.iterator();
        while (files_it.next()) |entry| {
            const file_path = entry.key_ptr.*;
            const file_hash = entry.value_ptr.*;

            const file_stmt =
                \\INSERT OR IGNORE INTO files (hash, size, created_at)
                \\VALUES (?, 0, ?)
            ;
            try self.db.exec(file_stmt, .{ file_hash, now }, .{});

            const mapping_stmt =
                \\INSERT OR IGNORE INTO package_files (package_id, commit_sha, file_path, file_hash)
                \\VALUES (?, ?, ?, ?)
            ;
            try self.db.exec(mapping_stmt, .{ pkg_id, commit_sha, file_path, file_hash }, .{});
        }
        try self.db.exec("COMMIT", .{}, .{});
    }
};
