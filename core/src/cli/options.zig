const std = @import("std");
const ProjectConfig = @import("config.zig").ProjectConfig;
const log_helpers = @import("../log.zig");

/// The arguments of a command that takes files or directories, `--config <file>` and the
/// options in `Flags`: a bool field `check` is the switch `--check`, a `?[]const u8` field
/// `format` the option `--format <value>`. Anything else starting with `-` is an error, not
/// a path: `fmt --check` used to read a file named "--check".
pub fn CommandOptions(comptime Flags: type) type {
    return struct {
        const Self = @This();

        config_path: ?[]const u8 = null,
        flags: Flags = .{},
        paths: std.ArrayListUnmanaged([]const u8) = .empty,

        pub const Error = error{ MissingConfigValue, MissingOptionValue, MissingFilePath, UnknownOption, OutOfMemory };

        /// On error.UnknownOption or error.MissingOptionValue, `unknown` is set to the option.
        pub fn parse(allocator: std.mem.Allocator, args_iter: anytype, unknown: *[]const u8) Error!Self {
            var self: Self = .{};
            errdefer self.paths.deinit(allocator);
            while (args_iter.next()) |arg| {
                if (std.mem.eql(u8, arg, "--config")) {
                    self.config_path = args_iter.next() orelse return error.MissingConfigValue;
                } else if (std.mem.startsWith(u8, arg, "-")) {
                    unknown.* = arg;
                    try self.setOption(arg, args_iter);
                } else {
                    try self.paths.append(allocator, arg);
                }
            }
            if (self.paths.items.len == 0) return error.MissingFilePath;
            return self;
        }

        fn setOption(self: *Self, arg: []const u8, args_iter: anytype) Error!void {
            inline for (comptime std.meta.fieldNames(Flags)) |name| {
                if (std.mem.eql(u8, arg, "--" ++ name)) {
                    switch (@FieldType(Flags, name)) {
                        bool => @field(self.flags, name) = true,
                        ?[]const u8 => @field(self.flags, name) = args_iter.next() orelse return error.MissingOptionValue,
                        else => @compileError("CommandOptions: option --" ++ name ++ " is neither a bool nor a ?[]const u8"),
                    }
                    return;
                }
            }
            return error.UnknownOption;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.paths.deinit(allocator);
        }
    };
}

/// Parses a command's arguments and loads the project configuration, reporting what
/// went wrong (followed by `usage`) so the command only has to return failure.
pub fn CommandSetup(comptime Flags: type) type {
    return struct {
        const Self = @This();

        options: CommandOptions(Flags),
        config: ProjectConfig,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, args_iter: anytype, comptime usage: []const u8) !Self {
            var unknown: []const u8 = "";
            var options = CommandOptions(Flags).parse(allocator, args_iter, &unknown) catch |err| {
                switch (err) {
                    error.MissingConfigValue => log_helpers.printStderr(io, "Error: Missing file after --config\n\n" ++ usage, .{}),
                    error.MissingFilePath => log_helpers.printStderr(io, "Error: Missing file path\n\n" ++ usage, .{}),
                    error.UnknownOption => log_helpers.printStderr(io, "Error: Unknown option '{s}'\n\n" ++ usage, .{unknown}),
                    error.MissingOptionValue => log_helpers.printStderr(io, "Error: Missing value after '{s}'\n\n" ++ usage, .{unknown}),
                    error.OutOfMemory => {},
                }
                return err;
            };
            errdefer options.deinit(allocator);

            const config_path = if (options.config_path) |p| try allocator.dupe(u8, p) else try findFromCwd(io, allocator);
            defer if (config_path) |p| allocator.free(p);
            var where: ProjectConfig.Position = .{ .line = 0, .column = 0 };
            const config = ProjectConfig.load(io, allocator, config_path, &where) catch |err| {
                const path = config_path.?;
                if (where.line > 0) {
                    log_helpers.printStderr(io, "Error: {s}:{d}:{d}: {s}\n", .{ path, where.line, where.column, ProjectConfig.describeError(err) });
                } else log_helpers.printStderr(io, "Error: Could not load {s}: {s}\n", .{ path, @errorName(err) });
                return err;
            };
            return .{ .options = options, .config = config };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.options.deinit(allocator);
        }
    };
}

/// The project's settings file for the current directory, as `ProjectConfig.find` looks.
fn findFromCwd(io: std.Io, allocator: std.mem.Allocator) !?[]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return ProjectConfig.find(io, allocator, cwd);
}
