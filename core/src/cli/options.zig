const std = @import("std");
const ProjectConfig = @import("config.zig").ProjectConfig;

pub const CommandOptions = struct {
    config_path: ?[]const u8 = null,
    paths: std.ArrayListUnmanaged([]const u8),

    /// Parses an argument iterator to extract global flags and target file paths.
    pub fn parse(allocator: std.mem.Allocator, args_iter: anytype) !CommandOptions {
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer paths.deinit(allocator);

        var config_path: ?[]const u8 = null;

        // Separate flags from target file/dir paths
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--config")) {
                config_path = args_iter.next() orelse return error.MissingConfigValue;
            } else {
                try paths.append(allocator, arg);
            }
        }

        if (paths.items.len == 0) return error.MissingFilePath;

        return CommandOptions{
            .config_path = config_path,
            .paths = paths,
        };
    }

    /// Helper that calls `parse` and automatically handles printing nice error
    /// messages and exiting the process on invalid user input.
    pub fn parseOrExit(allocator: std.mem.Allocator, args_iter: anytype, command_name: []const u8) !CommandOptions {
        return parse(allocator, args_iter) catch |err| {
            if (err == error.OutOfMemory) return err;

            if (err == error.MissingConfigValue) {
                std.debug.print("Error: Missing value for --config. Usage: kupcad {s} [--config <file>] <file|dir>...\n", .{command_name});
            } else if (err == error.MissingFilePath) {
                std.debug.print("Error: Missing file path. Usage: kupcad {s} [--config <file>] <file|dir>...\n", .{command_name});
            } else {
                std.debug.print("Error parsing arguments: {}\n", .{err});
            }
            std.process.exit(1);
        };
    }

    pub fn deinit(self: *CommandOptions, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
    }
};

/// A centralized bootstrapping struct that handles parsing arguments,
/// loading the configuration file, and gracefully handling errors.
pub const CommandSetup = struct {
    options: CommandOptions,
    config: ProjectConfig,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, args_iter: anytype, command_name: []const u8) !CommandSetup {
        const options = try CommandOptions.parseOrExit(allocator, args_iter, command_name);

        const config = ProjectConfig.load(io, allocator, options.config_path) catch |err| {
            std.debug.print("Error parsing configuration file: {}\n", .{err});
            std.process.exit(1);
        };

        return .{ .options = options, .config = config };
    }

    pub fn deinit(self: *CommandSetup, allocator: std.mem.Allocator) void {
        self.options.deinit(allocator);
    }
};
