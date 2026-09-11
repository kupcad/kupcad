const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const StoreError = error{
    DatabaseOpenFailed,
    QueryExecutionFailed,
    PrepareStatementFailed,
    BindParameterFailed,
    StepFailed,
};

pub const Store = struct {
    db: *c.sqlite3,

    /// Opens the SQLite database at the given path and initializes the CAFS schema.
    pub fn init(db_path: [:0]const u8) StoreError!Store {
        var db: ?*c.sqlite3 = null;

        // Open the database (creates it if it doesn't exist)
        if (c.sqlite3_open(db_path.ptr, &db) != c.SQLITE_OK) {
            std.debug.print("Failed to open database: {s}\n", .{c.sqlite3_errmsg(db)});
            return error.DatabaseOpenFailed;
        }

        const self = Store{ .db = db.? };

        // Enable Foreign Keys and Write-Ahead Logging (WAL) for performance
        try self.execute(
            \\ PRAGMA foreign_keys = ON;
            \\ PRAGMA journal_mode = WAL;
            \\ PRAGMA synchronous = NORMAL;
        );

        // Initialize the CAFS Schema
        try self.execute(
            \\ CREATE TABLE IF NOT EXISTS files (
            \\     hash TEXT PRIMARY KEY,
            \\     size INTEGER NOT NULL,
            \\     is_executable BOOLEAN NOT NULL DEFAULT 0
            \\ );
            \\
            \\ CREATE TABLE IF NOT EXISTS packages (
            \\     id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\     repo_url TEXT NOT NULL,
            \\     commit_sha TEXT NOT NULL,
            \\     UNIQUE(repo_url, commit_sha)
            \\ );
            \\
            \\ CREATE TABLE IF NOT EXISTS package_files (
            \\     package_id INTEGER NOT NULL,
            \\     file_hash TEXT NOT NULL,
            \\     file_path TEXT NOT NULL,
            \\     FOREIGN KEY(package_id) REFERENCES packages(id) ON DELETE CASCADE,
            \\     FOREIGN KEY(file_hash) REFERENCES files(hash) ON DELETE CASCADE,
            \\     UNIQUE(package_id, file_path)
            \\ );
        );

        return self;
    }

    /// Closes the database connection safely.
    pub fn deinit(self: *Store) void {
        _ = c.sqlite3_close(self.db);
    }

    /// Executes a raw SQL query (useful for schema creation or PRAGMAs).
    pub fn execute(self: Store, query: [:0]const u8) StoreError!void {
        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, query.ptr, null, null, &errmsg) != c.SQLITE_OK) {
            std.debug.print("Query execution failed: {s}\n", .{errmsg});
            c.sqlite3_free(errmsg);
            return error.QueryExecutionFailed;
        }
    }

    /// Registers a unique file in the global CAFS.
    pub fn insertFile(self: Store, hash: [:0]const u8, size: usize, is_executable: bool) StoreError!void {
        const query = "INSERT OR IGNORE INTO files (hash, size, is_executable) VALUES (?1, ?2, ?3)";
        var stmt: ?*c.sqlite3_stmt = null;

        if (c.sqlite3_prepare_v2(self.db, query, -1, &stmt, null) != c.SQLITE_OK) {
            return error.PrepareStatementFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, hash.ptr, @intCast(hash.len), c.SQLITE_STATIC) != c.SQLITE_OK or
            c.sqlite3_bind_int64(stmt, 2, @intCast(size)) != c.SQLITE_OK or
            c.sqlite3_bind_int(stmt, 3, if (is_executable) 1 else 0) != c.SQLITE_OK)
        {
            return error.BindParameterFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.StepFailed;
        }
    }

    /// Registers a package commit and returns its database ID.
    pub fn insertPackage(self: Store, repo_url: [:0]const u8, commit_sha: [:0]const u8) StoreError!i64 {
        const query = "INSERT OR IGNORE INTO packages (repo_url, commit_sha) VALUES (?1, ?2)";
        var stmt: ?*c.sqlite3_stmt = null;

        if (c.sqlite3_prepare_v2(self.db, query, -1, &stmt, null) != c.SQLITE_OK) {
            return error.PrepareStatementFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, repo_url.ptr, @intCast(repo_url.len), c.SQLITE_STATIC) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, commit_sha.ptr, @intCast(commit_sha.len), c.SQLITE_STATIC) != c.SQLITE_OK)
        {
            return error.BindParameterFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.StepFailed;
        }

        // Fetch the ID (whether newly inserted or existing)
        const select_query = "SELECT id FROM packages WHERE repo_url = ?1 AND commit_sha = ?2";
        var select_stmt: ?*c.sqlite3_stmt = null;

        if (c.sqlite3_prepare_v2(self.db, select_query, -1, &select_stmt, null) != c.SQLITE_OK) {
            return error.PrepareStatementFailed;
        }
        defer _ = c.sqlite3_finalize(select_stmt);

        _ = c.sqlite3_bind_text(select_stmt, 1, repo_url.ptr, @intCast(repo_url.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(select_stmt, 2, commit_sha.ptr, @intCast(commit_sha.len), c.SQLITE_STATIC);

        if (c.sqlite3_step(select_stmt) == c.SQLITE_ROW) {
            return c.sqlite3_column_int64(select_stmt, 0);
        }

        return error.StepFailed;
    }

    /// Links a specific file hash to a package at a given path.
    pub fn linkPackageFile(self: Store, package_id: i64, file_hash: [:0]const u8, file_path: [:0]const u8) StoreError!void {
        const query = "INSERT OR IGNORE INTO package_files (package_id, file_hash, file_path) VALUES (?1, ?2, ?3)";
        var stmt: ?*c.sqlite3_stmt = null;

        if (c.sqlite3_prepare_v2(self.db, query, -1, &stmt, null) != c.SQLITE_OK) {
            return error.PrepareStatementFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_int64(stmt, 1, package_id) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, file_hash.ptr, @intCast(file_hash.len), c.SQLITE_STATIC) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 3, file_path.ptr, @intCast(file_path.len), c.SQLITE_STATIC) != c.SQLITE_OK)
        {
            return error.BindParameterFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.StepFailed;
        }
    }
};
