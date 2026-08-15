const std = @import("std");
const fs = @import("fs.zig");
const FmtConfig = @import("../tools/fmt/config.zig").Config;
const LintConfig = @import("../tools/lint/config.zig").Config;

pub const MAX_FILE_SIZE = 1024 * 1024 * 10; // 10MB
const DEFAULT_CONFIG_NAME = ".kupcad.json";

pub const ProjectConfig = struct {
    fmt: FmtConfig = .{},
    lint: LintConfig = .{},
    compiler_memory_limit: ?usize = null, // Memory Sandbox for AST parsing (bytes)
    vm_memory_limit: ?usize = null, // Memory Sandbox for Runtime (bytes)

    /// Parses a JSON configuration string safely without crashing
    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ProjectConfig {
        const parsed = std.json.parseFromSlice(ProjectConfig, allocator, source, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            return err;
        };
        defer parsed.deinit();
        return parsed.value;
    }

    pub fn load(io: std.Io, allocator: std.mem.Allocator, custom_path: ?[]const u8) !ProjectConfig {
        const target_path = custom_path orelse DEFAULT_CONFIG_NAME;
        const source = fs.readFileLimit(io, allocator, target_path, MAX_FILE_SIZE) catch |err| {
            // If the user didn't explicitly provide a config path, it's okay if the default is missing
            if (err == error.FileNotFound and custom_path == null) {
                return ProjectConfig{};
            }
            return err;
        };
        defer allocator.free(source);
        return parse(allocator, source);
    }
};
