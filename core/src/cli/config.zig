const std = @import("std");
const fs = @import("fs.zig");
const FmtConfig = @import("../tools/fmt/config.zig").Config;
const LintConfig = @import("../tools/lint/config.zig").Config;

// Shares the frontend's cap so the CLI never accepts a file the parser would reject.
pub const MAX_FILE_SIZE = @import("../core/limits.zig").MAX_SOURCE_BYTES;
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
        var scanner = std.json.Scanner.initCompleteInput(allocator, source);
        defer scanner.deinit();
        var diagnostics: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&diagnostics);
        const parsed = std.json.parseFromTokenSource(ProjectConfig, allocator, &scanner, .{}) catch |err| {
            if (where) |w| w.* = .{ .line = diagnostics.getLine(), .column = diagnostics.getColumn() };
            return err;
        };
        defer parsed.deinit();
        return parsed.value;
    }

    pub const Position = struct { line: u64, column: u64 };

    /// The settings that hold for the script at `script_path`: the nearest .kupcad.json in
    /// its folder or above (as `find` looks), the defaults when there is none. A file that
    /// doesn't parse is an error; `where` receives the position when it has one.
    pub fn forScript(io: std.Io, allocator: std.mem.Allocator, script_path: []const u8, where: ?*Position) !ProjectConfig {
        const dir = std.fs.path.dirname(script_path) orelse ".";
        const found = try find(io, allocator, dir) orelse return .{};
        defer allocator.free(found);
        return load(io, allocator, found, where);
    }

    /// Reads the settings at `path`; the defaults when there is no file (null).
    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: ?[]const u8, where: ?*Position) !ProjectConfig {
        const source = try fs.readFileLimit(io, allocator, path orelse return .{}, MAX_FILE_SIZE);
        defer allocator.free(source);
        return parse(allocator, source, where);
    }

    /// The FILE_NAME that governs scripts in `dir`: the one in `dir` or the nearest folder
    /// above it, as git finds a repository, so a project's settings hold in every folder of
    /// it whatever directory a tool starts in. Null if there is none; caller owns the path.
    pub fn find(io: std.Io, allocator: std.mem.Allocator, dir: []const u8) !?[]u8 {
        var current: ?[]const u8 = dir;
        while (current) |folder| : (current = std.fs.path.dirname(folder)) {
            const candidate = try std.fs.path.join(allocator, &.{ folder, FILE_NAME });
            if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |err| {
                allocator.free(candidate);
                if (err != error.FileNotFound) return err;
            }
        }
        return null;
    }

    /// What a `parse` error means, for a person.
    pub fn describeError(err: anyerror) []const u8 {
        return switch (err) {
            error.UnknownField => "unknown setting (see the lint rules with `kupcad check --help`)",
            error.InvalidEnumTag => "unknown value (a lint rule's level is off, info, warning or error)",
            error.SyntaxError, error.UnexpectedEndOfInput => "invalid JSON",
            else => @errorName(err),
        };
    }
};
