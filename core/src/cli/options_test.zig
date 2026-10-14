const std = @import("std");
const testing = std.testing;
const Args = @import("args.zig").Args;
const CommandOptions = @import("options.zig").CommandOptions;

const Options = CommandOptions(struct { check: bool = false, write: bool = false });

fn parse(items: []const []const u8, unknown: *[]const u8) Options.Error!Options {
    var args: Args = .{ .items = items };
    return Options.parse(testing.allocator, &args, unknown);
}

test "CommandOptions: parses standard file paths" {
    var unknown: []const u8 = "";
    var opts = try parse(&.{ "file1.kup", "dir/" }, &unknown);
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), opts.paths.items.len);
    try testing.expectEqualStrings("file1.kup", opts.paths.items[0]);
    try testing.expectEqualStrings("dir/", opts.paths.items[1]);
    try testing.expectEqual(@as(?[]const u8, null), opts.config_path);
    try testing.expect(!opts.flags.check and !opts.flags.write);
}

test "CommandOptions: parses --config flag and path" {
    var unknown: []const u8 = "";
    var opts = try parse(&.{ "--config", "custom.json", "file.kup" }, &unknown);
    defer opts.deinit(testing.allocator);

    try testing.expectEqualStrings("custom.json", opts.config_path.?);
    try testing.expectEqual(@as(usize, 1), opts.paths.items.len);
    try testing.expectEqualStrings("file.kup", opts.paths.items[0]);
}

test "CommandOptions: sets the command's flags, anywhere among the paths" {
    var unknown: []const u8 = "";
    var opts = try parse(&.{ "a.kup", "--write", "b.kup" }, &unknown);
    defer opts.deinit(testing.allocator);
    try testing.expect(opts.flags.write and !opts.flags.check);
    try testing.expectEqual(@as(usize, 2), opts.paths.items.len);
}

test "CommandOptions: an option the command doesn't take is an error, not a path" {
    // `fmt --check` used to try to read a file named "--check".
    var unknown: []const u8 = "";
    try testing.expectError(error.UnknownOption, parse(&.{ "file.kup", "--chek" }, &unknown));
    try testing.expectEqualStrings("--chek", unknown);
    try testing.expectError(error.UnknownOption, parse(&.{ "-x", "file.kup" }, &unknown));
    try testing.expectEqualStrings("-x", unknown);
}

test "CommandOptions: fails safely on missing --config value" {
    var unknown: []const u8 = "";
    try testing.expectError(error.MissingConfigValue, parse(&.{ "file.kup", "--config" }, &unknown));
}

test "CommandOptions: fails safely on missing file paths" {
    var unknown: []const u8 = "";
    try testing.expectError(error.MissingFilePath, parse(&.{ "--config", "custom.json" }, &unknown));
    try testing.expectError(error.MissingFilePath, parse(&.{"--write"}, &unknown));
}
