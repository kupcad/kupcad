//! A small typed wrapper over SQLite's C API for the package store: `Db.exec` runs a
//! statement once, `Db.prepare` gives a `Stmt` to run many times (`exec`), read one row
//! (`one`) or step through rows (`iterator`), its arguments and row fields typed.

const sqlite = @import("sqlite");

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
