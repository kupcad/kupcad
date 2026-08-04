const std = @import("std");
const testing = std.testing;
const ProjectConfig = @import("config.zig").ProjectConfig;

test "ProjectConfig: defaults are applied correctly" {
    const config = ProjectConfig{};

    // Check Formatter defaults
    try testing.expectEqual(@as(u8, 2), config.fmt.indent_width);
    try testing.expectEqual(true, config.fmt.sort_imports);

    // Check Linter defaults
    try testing.expectEqual(true, config.lint.check_negative_dims);
    try testing.expectEqual(true, config.lint.check_unused_vars);
}

test "ProjectConfig: parses partial JSON and retains defaults" {
    const json_source =
        \\{
        \\  "fmt": {
        \\    "indent_width": 4
        \\  },
        \\  "lint": {
        \\    "check_unused_vars": false,
        \\    "check_self_subtraction": false
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(ProjectConfig, testing.allocator, json_source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const config = parsed.value;

    // 1. Verify overridden fields
    try testing.expectEqual(@as(u8, 4), config.fmt.indent_width);
    try testing.expectEqual(false, config.lint.check_unused_vars);
    try testing.expectEqual(false, config.lint.check_self_subtraction);

    // 2. Verify untouched fields kept their defaults
    try testing.expectEqual(true, config.fmt.sort_imports);
    try testing.expectEqual(true, config.lint.check_negative_dims);
    try testing.expectEqual(true, config.lint.check_unreachable_code);
    try testing.expectEqual(true, config.lint.check_param_docs);
}

test "ProjectConfig: gracefully ignores unknown fields" {
    const json_source =
        \\{
        \\  "random_plugin": true,
        \\  "lint": {
        \\    "future_rule_we_did_not_implement_yet": "warn"
        \\  }
        \\}
    ;

    // If `.ignore_unknown_fields = true` wasn't set, this would throw an error
    const parsed = try std.json.parseFromSlice(ProjectConfig, testing.allocator, json_source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const config = parsed.value;
    try testing.expectEqual(true, config.lint.check_unused_vars); // Should remain default
}
