const std = @import("std");
const FmtConfig = @import("../tools/fmt/config.zig").Config;
const LintConfig = @import("../tools/lint/config.zig").Config;

pub const MAX_FILE_SIZE = 1024 * 1024 * 10; // 10MB
const DEFAULT_CONFIG_NAME = ".kupcad.json";

pub const ProjectConfig = struct {
    fmt: FmtConfig = .{},
    lint: LintConfig = .{},

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
        const cwd = std.Io.Dir.cwd();
        const target_path = custom_path orelse DEFAULT_CONFIG_NAME;

        const source = cwd.readFileAlloc(io, target_path, allocator, .limited(MAX_FILE_SIZE)) catch |err| {
            if (err == error.FileNotFound) {
                if (custom_path == null) {
                    return ProjectConfig{};
                }
            }
            return err;
        };
        defer allocator.free(source);
        return parse(allocator, source);
    }
};
