const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Db = struct {
    handle: ?*c.sqlite3,

    pub fn exec(self: Db, sql: []const u8, args: anytype, options: anytype) !void {
        _ = options;
        const sql_z = try std.heap.page_allocator.dupeZ(u8, sql);
        defer std.heap.page_allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        const rc_prep = c.sqlite3_prepare_v2(self.handle, sql_z, -1, &stmt, null);
        if (rc_prep != c.SQLITE_OK or stmt == null) return error.SqliteError;
        defer _ = c.sqlite3_finalize(stmt);

        const ArgsType = @TypeOf(args);
        const args_info = @typeInfo(ArgsType);
        if (args_info == .@"struct" and args_info.@"struct".is_tuple) {
            inline for (args, 1..) |arg, idx| {
                const ArgType = @TypeOf(arg);
                if (ArgType == []const u8) {
                    _ = c.sqlite3_bind_text(stmt, @intCast(idx), arg.ptr, @intCast(arg.len), null);
                } else if (ArgType == i64 or ArgType == i32 or ArgType == usize) {
                    _ = c.sqlite3_bind_int64(stmt, @intCast(idx), @intCast(arg));
                }
            }
        }

        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) return error.SqliteError;
    }

    pub fn prepare(self: Db, sql: []const u8) !Stmt {
        const sql_z = try std.heap.page_allocator.dupeZ(u8, sql);
        defer std.heap.page_allocator.free(sql_z);

        var stmt_handle: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql_z, -1, &stmt_handle, null);
        if (rc != c.SQLITE_OK or stmt_handle == null) return error.SqliteError;

        return Stmt{ .handle = stmt_handle.? };
    }

    pub fn deinit(self: *Db) void {
        if (self.handle) |h| {
            _ = c.sqlite3_close(h);
            self.handle = null;
        }
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn deinit(self: Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn one(self: Stmt, comptime T: type, args: anytype, options: anytype) !?T {
        _ = args;
        _ = options;
        _ = c.sqlite3_reset(self.handle);
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) {
            var result: T = undefined;
            inline for (std.meta.fields(T), 0..) |field, i| {
                if (field.type == []const u8) {
                    const ptr = c.sqlite3_column_text(self.handle, @intCast(i));
                    const len = c.sqlite3_column_bytes(self.handle, @intCast(i));
                    @field(result, field.name) = if (ptr != null) ptr[0..@intCast(len)] else "";
                } else if (field.type == i32 or field.type == i64) {
                    @field(result, field.name) = @intCast(c.sqlite3_column_int64(self.handle, @intCast(i)));
                }
            }
            return result;
        }
        return null;
    }

    pub fn iterator(self: Stmt, comptime T: type, args: anytype) !Iterator(T) {
        _ = args;
        _ = c.sqlite3_reset(self.handle);
        return Iterator(T){ .stmt = self };
    }

    pub fn Iterator(comptime T: type) type {
        return struct {
            stmt: Stmt,

            pub fn next(self: *@This()) !?T {
                const rc = c.sqlite3_step(self.stmt.handle);
                if (rc == c.SQLITE_ROW) {
                    var result: T = undefined;
                    inline for (std.meta.fields(T), 0..) |field, i| {
                        if (field.type == []const u8) {
                            const ptr = c.sqlite3_column_text(self.stmt.handle, @intCast(i));
                            const len = c.sqlite3_column_bytes(self.stmt.handle, @intCast(i));
                            @field(result, field.name) = if (ptr != null) ptr[0..@intCast(len)] else "";
                        } else if (field.type == i32 or field.type == i64) {
                            @field(result, field.name) = @intCast(c.sqlite3_column_int64(self.stmt.handle, @intCast(i)));
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
        const db_path_z = try std.heap.page_allocator.dupeZ(u8, db_path);
        defer std.heap.page_allocator.free(db_path_z);

        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path_z, &handle);
        if (rc != c.SQLITE_OK or handle == null) return error.DatabaseCorrupted;

        const db = Db{ .handle = handle };
        var store = Store{ .db = db, .io = io };

        const integrity_stmt = try db.prepare("PRAGMA quick_check");
        defer integrity_stmt.deinit();
        const integrity_res = try integrity_stmt.one(struct { result: []const u8 }, .{}, .{});
        if (integrity_res) |res| {
            if (!std.mem.eql(u8, res.result, "ok")) {
                std.debug.print("CRITICAL: SQLite database is corrupted! Self-healing triggered...\n", .{});
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
        const TARGET_VERSION: i32 = 1;

        if (current_version < TARGET_VERSION) {
            if (!@import("builtin").is_test) {
                std.debug.print("Upgrading database schema from v{d} to v{d}...\n", .{ current_version, TARGET_VERSION });
            }

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
            const update_pragma = try std.fmt.allocPrint(std.heap.page_allocator, "PRAGMA user_version = {d}", .{TARGET_VERSION});
            defer std.heap.page_allocator.free(update_pragma);
            try self.db.exec(update_pragma, .{}, .{});
            try self.db.exec("COMMIT", .{}, .{});
        }
    }

    pub fn registerPackage(
        self: *Store,
        pkg_id: []const u8,
        commit_sha: []const u8,
        provider_name: []const u8,
        files_map: *std.StringHashMap([]const u8),
    ) !void {
        try self.db.exec("BEGIN TRANSACTION", .{}, .{});
        errdefer self.db.exec("ROLLBACK", .{}, .{}) catch {};

        // Explicitly cast the i96 duration to i64 for SQLite bindings
        const now_ns = std.Io.Clock.real.now(self.io).nanoseconds;
        const now: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));

        const pkg_stmt =
            \\INSERT OR IGNORE INTO packages (id, commit_sha, provider, created_at)
            \\VALUES (?, ?, ?, ?)
        ;
        try self.db.exec(pkg_stmt, .{ pkg_id, commit_sha, provider_name, now }, .{});

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
