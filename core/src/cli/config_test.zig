const std = @import("std");
const testing = std.testing;
const ProjectConfig = @import("config.zig").ProjectConfig;
const FILE_NAME = @import("config.zig").FILE_NAME;
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

test "ProjectConfig: a file that can't be read is named, with where and why" {
    // Each command said it its own way, two naming the script with the file's position
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = FILE_NAME, .data = "{\n  \"random_plugin\": true\n}" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const script = try std.fs.path.join(testing.allocator, &.{ root, "part.kup" });
    defer testing.allocator.free(script);
    var failure: ?ProjectConfig.Failure = null;
    defer if (failure) |*f| f.deinit(testing.allocator);
    try testing.expectError(error.UnknownField, ProjectConfig.forScript(testing.io, testing.allocator, script, &failure));
    const said = try std.fmt.allocPrint(testing.allocator, "{f}", .{failure.?});
    defer testing.allocator.free(said);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}{c}{s}:2:18: unknown setting (see the lint rules with `kupcad check --help`)", .{ root, std.fs.path.sep, FILE_NAME });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, said);
    // A file that can't be read has no place
    failure.?.deinit(testing.allocator);
    failure = null;
    try testing.expectError(error.FileNotFound, ProjectConfig.load(testing.io, testing.allocator, "/nonexistent/kupcad/.kupcad.json", &failure));
    const missing = try std.fmt.allocPrint(testing.allocator, "{f}", .{failure.?});
    defer testing.allocator.free(missing);
    try testing.expectEqualStrings("Could not load /nonexistent/kupcad/.kupcad.json: FileNotFound", missing);
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

test "ProjectConfig: find looks in the folder, then each folder above it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "project/parts/small");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "project/" ++ FILE_NAME, .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const nested = try std.fs.path.join(testing.allocator, &.{ root, "project", "parts", "small" });
    defer testing.allocator.free(nested);
    const found = (try ProjectConfig.find(testing.io, testing.allocator, nested)).?;
    defer testing.allocator.free(found);
    const expected = try std.fs.path.join(testing.allocator, &.{ root, "project", FILE_NAME });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, found);

    // The nearest one wins.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "project/parts/" ++ FILE_NAME, .data = "{}" });
    const nearer = (try ProjectConfig.find(testing.io, testing.allocator, nested)).?;
    defer testing.allocator.free(nearer);
    try testing.expect(std.mem.endsWith(u8, nearer, "parts" ++ std.fs.path.sep_str ++ FILE_NAME));
}
