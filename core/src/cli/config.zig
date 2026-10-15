const std = @import("std");
const fs = @import("fs.zig");
const FmtConfig = @import("../tools/fmt/config.zig").Config;
const LintConfig = @import("../tools/lint/config.zig").Config;

// Shares the frontend's cap so the CLI never accepts a file the parser would reject.
pub const MAX_FILE_SIZE = @import("../core/limits.zig").MAX_SOURCE_BYTES;
const DEFAULT_CONFIG_NAME = ".kupcad.json";

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

    pub fn load(io: std.Io, allocator: std.mem.Allocator, custom_path: ?[]const u8, where: ?*Position) !ProjectConfig {
        const target_path = custom_path orelse DEFAULT_CONFIG_NAME;
        const source = fs.readFileLimit(io, allocator, target_path, MAX_FILE_SIZE) catch |err| {
            // If the user didn't explicitly provide a config path, it's okay if the default is missing
            if (err == error.FileNotFound and custom_path == null) {
                return ProjectConfig{};
            }
            return err;
        };
        defer allocator.free(source);
        return parse(allocator, source, where);
    }
};
