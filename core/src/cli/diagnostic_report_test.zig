const std = @import("std");
const testing = std.testing;
const report = @import("diagnostic_report.zig");
const LineIndex = @import("../core/line_index.zig").LineIndex;
const Style = report.Style;
const ansi = Style.ansi;

test "diagnostic_report: renders location, source line and an underline of the span" {
    const source = "a = 1\r\nb = (2\nc = 3\n";
    const line_index = try LineIndex.init(testing.allocator, source);
    defer line_index.deinit(testing.allocator);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    // "(2" on line 2, column 5, two bytes long; the CRLF of line 1 must not leak into line 2.
    try report.write(&out.writer, .{
        .file_path = "part.kup",
        .source = source,
        .line_index = &line_index,
        .offset = 11,
        .length = 2,
        .severity = .@"error",
        .message = "Unclosed '('",
    }, ansi);
    const expected = ansi.cyan ++ "part.kup:2:5:" ++ ansi.reset ++ " " ++ ansi.red ++ "E:" ++ ansi.reset ++ " Unclosed '('\n" ++
        "b = (2\n" ++
        "    " ++ ansi.red ++ "^^" ++ ansi.reset ++ "\n\n";
    try testing.expectEqualStrings(expected, out.written());
}

test "diagnostic_report: a zero-length span still gets one caret" {
    const source = "x = )";
    const line_index = try LineIndex.init(testing.allocator, source);
    defer line_index.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try report.write(&out.writer, .{ .file_path = "f.kup", .source = source, .line_index = &line_index, .offset = 4, .length = 0, .severity = .warning, .message = "m" }, ansi);
    try testing.expect(std.mem.endsWith(u8, out.written(), "x = )\n    " ++ ansi.yellow ++ "^" ++ ansi.reset ++ "\n\n"));
}

test "diagnostic_report: sourceLine strips CR and handles out-of-range lines" {
    const source = "one\r\ntwo\nthree";
    try testing.expectEqualStrings("one", report.sourceLine(source, 1));
    try testing.expectEqualStrings("two", report.sourceLine(source, 2));
    try testing.expectEqualStrings("three", report.sourceLine(source, 3));
    try testing.expectEqualStrings("", report.sourceLine(source, 9));
}

test "diagnostic_report: the plain style writes no escape codes" {
    const source = "x = )";
    const line_index = try LineIndex.init(testing.allocator, source);
    defer line_index.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try report.write(&out.writer, .{ .file_path = "f.kup", .source = source, .line_index = &line_index, .offset = 4, .length = 1, .severity = .@"error", .message = "m" }, .plain);
    try testing.expectEqualStrings("f.kup:1:5: E: m\nx = )\n    ^\n\n", out.written());
}

test "diagnostic_report: Style.detect colours only a terminal, and honours NO_COLOR and CLICOLOR_FORCE" {
    // A file is never a terminal, as stderr isn't when it is piped or redirected; these used
    // to get escape codes all the same.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "log.txt", .{});
    defer file.close(testing.io);

    const cases = [_]struct { no_color: ?[]const u8 = null, force: ?[]const u8 = null, ansi: bool }{
        .{ .ansi = false },
        .{ .force = "1", .ansi = true },
        .{ .force = "", .ansi = false }, // set but empty counts as unset
        .{ .no_color = "1", .force = "1", .ansi = false },
    };
    for (cases) |case| {
        var env = std.process.Environ.Map.init(testing.allocator);
        defer env.deinit();
        if (case.no_color) |v| try env.put("NO_COLOR", v);
        if (case.force) |v| try env.put("CLICOLOR_FORCE", v);
        const style = Style.detect(testing.io, file, &env);
        try testing.expectEqualStrings(if (case.ansi) ansi.red else "", style.red);
    }
}
