const std = @import("std");
const FmtConfig = @import("../tools/fmt/config.zig").Config;
const LintConfig = @import("../tools/lint/config.zig").Config;

const DEFAULT_CONFIG_NAME = ".kupcad.json";

pub const ProjectConfig = struct {
    fmt: FmtConfig = .{},
    lint: LintConfig = .{},

    /// Attempts to load and parse `.kupcad.json` (or a custom path) from the current directory.
    /// Returns default configurations if the default file does not exist.
    pub fn load(init: std.process.Init, allocator: std.mem.Allocator, custom_path: ?[]const u8) !ProjectConfig {
        const cwd = std.Io.Dir.cwd();

        const target_path = custom_path orelse DEFAULT_CONFIG_NAME;

        // Try to read the config file
        const source = cwd.readFileAlloc(init.io, target_path, allocator, .limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                if (custom_path == null) {
                    return ProjectConfig{}; // Just return defaults if no default config file is found
                }
            }
            return err; // Fail loudly if the explicit custom path is missing or there's an IO error
        };
        defer allocator.free(source);

        // Parse the JSON directly into our Zig structs
        const parsed = try std.json.parseFromSlice(ProjectConfig, allocator, source, .{
            .ignore_unknown_fields = true, // Be lenient with extra keys
        });
        defer parsed.deinit();

        return parsed.value;
    }
};
