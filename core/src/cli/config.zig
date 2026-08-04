const std = @import("std");
const FmtConfig = @import("../tools/fmt/config.zig").Config;
const LintConfig = @import("../tools/lint/config.zig").Config;

const DEFAULT_CONFIG_NAME = ".kupcad.json";

pub const ProjectConfig = struct {
    fmt: FmtConfig = .{},
    lint: LintConfig = .{},

    pub fn load(io: std.Io, allocator: std.mem.Allocator, custom_path: ?[]const u8) !ProjectConfig {
        const cwd = std.Io.Dir.cwd();
        const target_path = custom_path orelse DEFAULT_CONFIG_NAME;

        const source = cwd.readFileAlloc(io, target_path, allocator, .limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                if (custom_path == null) {
                    return ProjectConfig{};
                }
            }
            return err;
        };
        defer allocator.free(source);

        const parsed = try std.json.parseFromSlice(ProjectConfig, allocator, source, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        return parsed.value;
    }
};
