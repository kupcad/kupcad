const std = @import("std");
const testing = std.testing;
const CommandOptions = @import("options.zig").CommandOptions;

const MockArgs = struct {
    args: []const []const u8,
    index: usize = 0,

    pub fn next(self: *@This()) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        const arg = self.args[self.index];
        self.index += 1;
        return arg;
    }
};

test "CommandOptions: parses standard file paths" {
    var mock = MockArgs{ .args = &[_][]const u8{ "file1.kup", "dir/" } };
    var opts = try CommandOptions.parse(testing.allocator, &mock);
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), opts.paths.items.len);
    try testing.expectEqualStrings("file1.kup", opts.paths.items[0]);
    try testing.expectEqualStrings("dir/", opts.paths.items[1]);
    try testing.expectEqual(@as(?[]const u8, null), opts.config_path);
}

test "CommandOptions: parses --config flag and path" {
    var mock = MockArgs{ .args = &[_][]const u8{ "--config", "custom.json", "file.kup" } };
    var opts = try CommandOptions.parse(testing.allocator, &mock);
    defer opts.deinit(testing.allocator);

    try testing.expectEqualStrings("custom.json", opts.config_path.?);
    try testing.expectEqual(@as(usize, 1), opts.paths.items.len);
    try testing.expectEqualStrings("file.kup", opts.paths.items[0]);
}

test "CommandOptions: fails safely on missing --config value" {
    var mock = MockArgs{ .args = &[_][]const u8{ "file.kup", "--config" } };
    const result = CommandOptions.parse(testing.allocator, &mock);
    try testing.expectError(error.MissingConfigValue, result);
}

test "CommandOptions: fails safely on missing file paths" {
    var mock = MockArgs{ .args = &[_][]const u8{ "--config", "custom.json" } };
    const result = CommandOptions.parse(testing.allocator, &mock);
    try testing.expectError(error.MissingFilePath, result);
}
