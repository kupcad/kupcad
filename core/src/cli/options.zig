const std = @import("std");

pub const CommandOptions = struct {
    config_path: ?[]const u8 = null,
    paths: std.ArrayListUnmanaged([]const u8),

    /// Parses the argument iterator to extract global flags and target file paths.
    /// Exits the process automatically if required inputs are missing.
    pub fn parse(allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator, command_name: []const u8) !CommandOptions {
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        var config_path: ?[]const u8 = null;

        // Separate flags from target file/dir paths
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--config")) {
                config_path = args_iter.next() orelse {
                    std.debug.print("Error: Missing value for --config. Usage: kupcad {s} [--config <file>] <file|dir>...\n", .{command_name});
                    std.process.exit(1);
                };
            } else {
                try paths.append(allocator, arg);
            }
        }

        if (paths.items.len == 0) {
            std.debug.print("Error: Missing file path. Usage: kupcad {s} [--config <file>] <file|dir>...\n", .{command_name});
            std.process.exit(1);
        }

        return CommandOptions{
            .config_path = config_path,
            .paths = paths,
        };
    }

    pub fn deinit(self: *CommandOptions, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
    }
};
