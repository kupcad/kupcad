const std = @import("std");
const FmtConfig = @import("../tools/fmt/config.zig").Config;
const LintConfig = @import("../tools/lint/config.zig").Config;

const DEFAULT_CONFIG_NAME = ".kupcad.json";

pub const ProjectConfig = struct {
    fmt: FmtConfig = .{},
    lint: LintConfig = .{},

    /// Attempts to load and parse `.kupcad.json` from the current directory.
    /// Returns default configurations if the file does not exist.
    pub fn load(init: std.process.Init, allocator: std.mem.Allocator) !ProjectConfig {
        const cwd = std.Io.Dir.cwd();

        // Try to read the config file
        const source = cwd.readFileAlloc(init.io, DEFAULT_CONFIG_NAME, allocator, .limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                return ProjectConfig{}; // Just return defaults if no config file is found
            }
            return err;
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
