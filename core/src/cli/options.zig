//! Argument parsing shared by the commands that take files or directories (`check`, `fmt`):
//! `CommandOptions` turns a flags struct into `--name` options, `CommandSetup` parses them,
//! reporting failures with the command's usage, and `Settings` gives each file its project's
//! configuration.

const std = @import("std");
const ProjectConfig = @import("config.zig").ProjectConfig;
const owned_keys = @import("../core/owned_keys.zig");
const Reporter = @import("reporter.zig").Reporter;

/// The arguments of a command that takes files or directories, `--config <file>` and the
/// options in `Flags`: a bool field `check` is the switch `--check`, a `?[]const u8` field
/// `format` the option `--format <value>`. Anything else starting with `-` is an error, not
/// a path: `fmt --check` used to read a file named "--check". A path is required unless
/// `Flags` has a `stdin` switch and it is given: then the input is what is piped in.
pub fn CommandOptions(comptime Flags: type) type {
    return struct {
        const Self = @This();

        config_path: ?[]const u8 = null,
        flags: Flags = .{},
        paths: std.ArrayList([]const u8) = .empty,

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
            const from_stdin = if (@hasField(Flags, "stdin")) self.flags.stdin else false;
            if (self.paths.items.len == 0 and !from_stdin) return error.MissingFilePath;
            return self;
        }

        fn setOption(self: *Self, arg: []const u8, args_iter: anytype) Error!void {
            inline for (comptime @typeInfo(Flags).@"struct".field_names) |name| {
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

/// The settings each file a command takes is read with: the file `--config` names for every
/// one (`given`), else the .kupcad.json nearest the file's folder, as `kupcad build` finds a
/// script's (ProjectConfig.forScript), read once per folder. `check` and `fmt` read the one
/// nearest the current directory for every file, so `kupcad check sub/a.kup` didn't apply
/// `sub/.kupcad.json`, which it did run inside `sub`.
pub const Settings = struct {
    allocator: std.mem.Allocator,
    reporter: Reporter,
    given: ?ProjectConfig = null,
    /// What each folder's files are read with (keys owned): null for settings that couldn't
    /// be read, which was reported.
    by_folder: std.StringHashMapUnmanaged(?ProjectConfig) = .empty,

    pub fn deinit(self: *Settings) void {
        owned_keys.deinit(&self.by_folder, self.allocator, .borrowed);
    }

    /// The settings of the file at `file_path`; null when they couldn't be read (reported once
    /// per folder), and the file must count as failed.
    pub fn forFile(self: *Settings, file_path: []const u8) !?ProjectConfig {
        if (self.given) |config| return config;
        const folder = std.fs.path.dirname(file_path) orelse ".";
        if (self.by_folder.get(folder)) |known| return known;
        var failure: ?ProjectConfig.Failure = null;
        defer if (failure) |*f| f.deinit(self.allocator);
        const config: ?ProjectConfig = ProjectConfig.forScript(self.reporter.io, self.allocator, file_path, &failure) catch |err| blk: {
            const f = failure orelse return err;
            self.reporter.err("Error: {f}\n", .{f});
            break :blk null;
        };
        const entry = try owned_keys.getOrPutOwned(&self.by_folder, self.allocator, folder);
        entry.value_ptr.* = config;
        return config;
    }
};

/// Parses a command's arguments and loads the settings `--config` names, if any, reporting
/// what went wrong (followed by `usage`) so the command only has to return failure.
pub fn CommandSetup(comptime Flags: type) type {
    return struct {
        const Self = @This();

        options: CommandOptions(Flags),
        settings: Settings,

        pub fn init(allocator: std.mem.Allocator, reporter: Reporter, args_iter: anytype, comptime usage: []const u8) !Self {
            var unknown: []const u8 = "";
            var options = CommandOptions(Flags).parse(allocator, args_iter, &unknown) catch |err| {
                switch (err) {
                    error.MissingConfigValue => reporter.err("Error: Missing file after --config\n\n" ++ usage, .{}),
                    error.MissingFilePath => reporter.err("Error: Missing file path\n\n" ++ usage, .{}),
                    error.UnknownOption => reporter.err("Error: Unknown option '{s}'\n\n" ++ usage, .{unknown}),
                    error.MissingOptionValue => reporter.err("Error: Missing value after '{s}'\n\n" ++ usage, .{unknown}),
                    error.OutOfMemory => {},
                }
                return err;
            };
            errdefer options.deinit(allocator);

            var settings: Settings = .{ .allocator = allocator, .reporter = reporter };
            if (options.config_path) |path| {
                var failure: ?ProjectConfig.Failure = null;
                defer if (failure) |*f| f.deinit(allocator);
                settings.given = ProjectConfig.load(reporter.io, allocator, path, &failure) catch |err| {
                    if (failure) |f| reporter.err("Error: {f}\n", .{f});
                    return err;
                };
            }
            return .{ .options = options, .settings = settings };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.options.deinit(allocator);
            self.settings.deinit();
        }
    };
}
