const std = @import("std");
const testing = std.testing;
const report = @import("diagnostic_report.zig");
const LineIndex = @import("../core/line_index.zig").LineIndex;
const Color = report.Color;

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
    });
    const expected = Color.cyan ++ "part.kup:2:5:" ++ Color.reset ++ " " ++ Color.red ++ "E:" ++ Color.reset ++ " Unclosed '('\n" ++
        "b = (2\n" ++
        "    " ++ Color.red ++ "^^" ++ Color.reset ++ "\n\n";
    try testing.expectEqualStrings(expected, out.written());
}

test "diagnostic_report: a zero-length span still gets one caret" {
    const source = "x = )";
    const line_index = try LineIndex.init(testing.allocator, source);
    defer line_index.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try report.write(&out.writer, .{ .file_path = "f.kup", .source = source, .line_index = &line_index, .offset = 4, .length = 0, .severity = .warning, .message = "m" });
    try testing.expect(std.mem.endsWith(u8, out.written(), "x = )\n    " ++ Color.yellow ++ "^" ++ Color.reset ++ "\n\n"));
}

test "diagnostic_report: sourceLine strips CR and handles out-of-range lines" {
    const source = "one\r\ntwo\nthree";
    try testing.expectEqualStrings("one", report.sourceLine(source, 1));
    try testing.expectEqualStrings("two", report.sourceLine(source, 2));
    try testing.expectEqualStrings("three", report.sourceLine(source, 3));
    try testing.expectEqualStrings("", report.sourceLine(source, 9));
}
