const std = @import("std");
const testing = std.testing;
const ProjectConfig = @import("config.zig").ProjectConfig;
const Level = @import("../tools/lint/config.zig").Level;

test "ProjectConfig: defaults are applied correctly" {
    const config = ProjectConfig{};

    // Check Formatter defaults
    try testing.expectEqual(@as(u8, 2), config.fmt.indent_width);
    try testing.expectEqual(true, config.fmt.sort_imports);

    // Every lint rule warns by default
    try testing.expectEqual(Level.warning, config.lint.@"nonpositive-size");
    try testing.expectEqual(Level.warning, config.lint.@"unused-variable");
}

test "ProjectConfig: parses partial JSON and retains defaults" {
    const json_source =
        \\{
        \\  "fmt": {
        \\    "indent_width": 4
        \\  },
        \\  "lint": {
        \\    "unused-variable": "off",
        \\    "self-subtraction": "error"
        \\  }
        \\}
    ;

    const config = try ProjectConfig.parse(testing.allocator, json_source, null);

    // 1. Verify overridden fields
    try testing.expectEqual(@as(u8, 4), config.fmt.indent_width);
    try testing.expectEqual(Level.off, config.lint.@"unused-variable");
    try testing.expectEqual(Level.@"error", config.lint.@"self-subtraction");

    // 2. Verify untouched fields kept their defaults
    try testing.expectEqual(true, config.fmt.sort_imports);
    try testing.expectEqual(Level.warning, config.lint.@"nonpositive-size");
}

test "ProjectConfig: an unknown setting or level is an error, with where it is" {
    // A mistyped rule used to be ignored, leaving the rule on.
    const cases = [_]struct { src: []const u8, err: anyerror, line: u64 }{
        .{ .src = "{\n  \"lint\": {\n    \"unused-variabel\": \"off\"\n  }\n}", .err = error.UnknownField, .line = 3 },
        .{ .src = "{\n  \"lint\": { \"unused-variable\": \"warn\" }\n}", .err = error.InvalidEnumTag, .line = 2 },
        .{ .src = "{ \"random_plugin\": true }", .err = error.UnknownField, .line = 1 },
    };
    for (cases) |case| {
        var where: ProjectConfig.Position = .{ .line = 0, .column = 0 };
        try testing.expectError(case.err, ProjectConfig.parse(testing.allocator, case.src, &where));
        try testing.expectEqual(case.line, where.line);
    }
}

test "ProjectConfig: gracefully fails on malformed JSON" {
    // Missing comma after indent_width and missing closing braces
    const json_source =
        \\{
        \\  "fmt": {
        \\    "indent_width": 4
        \\  "lint": {
        \\}
    ;

    try testing.expectError(error.SyntaxError, ProjectConfig.parse(testing.allocator, json_source, null));
}
