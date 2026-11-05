//! A project's `.kupcad.json` settings: the formatter and linter configuration and the memory
//! limits. `ProjectConfig.forScript` finds the file that governs a script (the nearest one in
//! its folder or above) and parses it.

const std = @import("std");
const fs = @import("fs.zig");
const FmtConfig = @import("../tools/fmt/config.zig").Config;
const LintConfig = @import("../tools/lint/config.zig").Config;
const json_input = @import("../core/json_input.zig");

/// A project's settings file, found in a script's folder or a folder above it.
pub const FILE_NAME = ".kupcad.json";

pub const ProjectConfig = struct {
    fmt: FmtConfig = .{},
    lint: LintConfig = .{},
    compiler_memory_limit: ?usize = null, // Memory Sandbox for AST parsing (bytes)
    vm_memory_limit: ?usize = null, // Memory Sandbox for Runtime (bytes)

    /// Parses `.kupcad.json`. A key it doesn't know is an error (error.UnknownField), like a
    /// bad value: a mistyped rule (`"unused-variabel": "off"`) used to be ignored silently.
    /// `where`, if given, receives the 1-based line and column the parse stopped at.
    pub fn parse(allocator: std.mem.Allocator, source: []const u8, where: ?*Position) !ProjectConfig {
        const parsed = try json_input.parse(ProjectConfig, allocator, source, where);
        defer parsed.deinit();
        return parsed.value;
    }

    pub const Position = json_input.Position;

    /// Why a settings file couldn't be read, for a person: the file, with where its parse
    /// stopped when it has a place (`.../.kupcad.json:3:5: unknown setting ...`), else why
    /// it couldn't be loaded. Every command said it its own way, two of them naming the
    /// script with the file's position (`near main.kup:0:0`).
    pub const Failure = struct {
        /// The settings file, owned.
        path: []u8,
        where: Position,
        err: anyerror,

        pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
        }

        pub fn format(self: Failure, w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.where.line > 0) return w.print("{s}:{d}:{d}: {s}", .{ self.path, self.where.line, self.where.column, describeError(self.err) });
            return w.print("Could not load {s}: {s}", .{ self.path, describeError(self.err) });
        }
    };

    /// The settings that hold for the script at `script_path`: the nearest .kupcad.json in
    /// its folder or above (as `find` looks), the defaults when there is none. A file that
    /// doesn't parse or can't be read is an error, and `failure` says which and why.
    pub fn forScript(io: std.Io, allocator: std.mem.Allocator, script_path: []const u8, failure: *?Failure) !ProjectConfig {
        const dir = std.fs.path.dirname(script_path) orelse ".";
        const found = try find(io, allocator, dir) orelse return .{};
        defer allocator.free(found);
        return load(io, allocator, found, failure);
    }

    /// Reads the settings at `path`; the defaults when there is no file (null). An error
    /// (a file that doesn't parse or can't be read) sets `failure` to say which and why;
    /// the caller frees it.
    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: ?[]const u8, failure: *?Failure) !ProjectConfig {
        const file = path orelse return .{};
        var where: Position = .{ .line = 0, .column = 0 };
        return loadAt(io, allocator, file, &where) catch |err| {
            failure.* = .{ .path = try allocator.dupe(u8, file), .where = where, .err = err };
            return err;
        };
    }

    fn loadAt(io: std.Io, allocator: std.mem.Allocator, path: []const u8, where: *Position) !ProjectConfig {
        const source = try fs.readFile(io, allocator, path);
        defer allocator.free(source);
        return parse(allocator, source, where);
    }

    /// The FILE_NAME that governs scripts in `dir`: the one in `dir` or the nearest folder
    /// above it, as git finds a repository, so a project's settings hold in every folder of
    /// it whatever directory a tool starts in. Null if there is none; caller owns the path.
    pub fn find(io: std.Io, allocator: std.mem.Allocator, dir: []const u8) !?[]u8 {
        // From the folder's absolute path: a relative one (".", a script's in the current
        // directory) has no folder above it to look in
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        const absolute = try std.fs.path.resolve(allocator, &.{ cwd, dir });
        defer allocator.free(absolute);
        const folder = try fs.nearestAncestorWith(io, allocator, absolute, null, &.{FILE_NAME}) orelse return null;
        return try std.fs.path.join(allocator, &.{ folder, FILE_NAME });
    }

    /// What a `parse` error means, for a person.
    pub fn describeError(err: anyerror) []const u8 {
        return switch (err) {
            error.UnknownField => "unknown setting (see the lint rules with `kupcad check --help`)",
            error.InvalidEnumTag => "unknown value (a lint rule's level is off, info, warning or error)",
            else => json_input.describeSyntaxError(err) orelse @errorName(err),
        };
    }
};
