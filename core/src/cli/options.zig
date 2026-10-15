const std = @import("std");
const ProjectConfig = @import("config.zig").ProjectConfig;
const log_helpers = @import("../log.zig");

/// The arguments of a command that takes files or directories, `--config <file>` and the
/// switches in `Flags`, a struct of bools where field `check` is `--check`. Anything else
/// starting with `-` is an error, not a path: `fmt --check` used to read a file named
/// "--check".
pub fn CommandOptions(comptime Flags: type) type {
    return struct {
        const Self = @This();

        config_path: ?[]const u8 = null,
        flags: Flags = .{},
        paths: std.ArrayListUnmanaged([]const u8) = .empty,

        pub const Error = error{ MissingConfigValue, MissingFilePath, UnknownOption, OutOfMemory };

        /// On error.UnknownOption, `unknown` is set to the argument.
        pub fn parse(allocator: std.mem.Allocator, args_iter: anytype, unknown: *[]const u8) Error!Self {
            var self: Self = .{};
            errdefer self.paths.deinit(allocator);
            while (args_iter.next()) |arg| {
                if (std.mem.eql(u8, arg, "--config")) {
                    self.config_path = args_iter.next() orelse return error.MissingConfigValue;
                } else if (std.mem.startsWith(u8, arg, "-")) {
                    if (!self.setFlag(arg)) {
                        unknown.* = arg;
                        return error.UnknownOption;
                    }
                } else {
                    try self.paths.append(allocator, arg);
                }
            }
            if (self.paths.items.len == 0) return error.MissingFilePath;
            return self;
        }

        fn setFlag(self: *Self, arg: []const u8) bool {
            inline for (comptime std.meta.fieldNames(Flags)) |name| {
                if (std.mem.eql(u8, arg, "--" ++ name)) {
                    @field(self.flags, name) = true;
                    return true;
                }
            }
            return false;
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
                    error.OutOfMemory => {},
                }
                return err;
            };
            errdefer options.deinit(allocator);

            var where: ProjectConfig.Position = .{ .line = 0, .column = 0 };
            const config = ProjectConfig.load(io, allocator, options.config_path, &where) catch |err| {
                const path = options.config_path orelse ".kupcad.json";
                if (where.line > 0) {
                    log_helpers.printStderr(io, "Error: {s}:{d}:{d}: {s}\n", .{ path, where.line, where.column, configProblem(err) });
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

/// What a `.kupcad.json` parse error means.
fn configProblem(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownField => "unknown setting (see the lint rules with `kupcad check --help`)",
        error.InvalidEnumTag => "unknown value (a lint rule's level is off, info, warning or error)",
        error.SyntaxError, error.UnexpectedEndOfInput => "invalid JSON",
        else => @errorName(err),
    };
}
