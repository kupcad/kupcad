//! The escapes of string literals (string_escape.zig): each decodes to its value, an escape
//! no literal takes is a Problem placed at it, and a value written back decodes to itself.

const std = @import("std");
const string_escape = @import("string_escape.zig");
const Problem = string_escape.Problem;
const unescapeInto = string_escape.unescapeInto;
const unescapeRawInto = string_escape.unescapeRawInto;
const unescapeHeredocInto = string_escape.unescapeHeredocInto;
const appendEscaped = string_escape.appendEscaped;

fn expectDecodes(expected: []const u8, text: []const u8) !void {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(std.testing.allocator);
    var problem: Problem = undefined;
    try unescapeInto(&decoded, std.testing.allocator, text, &problem);
    try std.testing.expectEqualStrings(expected, decoded.items);
}

fn expectProblem(expected: Problem, text: []const u8) !void {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(std.testing.allocator);
    var problem: Problem = undefined;
    errdefer std.debug.print("text: {s}\n", .{text});
    try std.testing.expectError(error.InvalidEscape, unescapeInto(&decoded, std.testing.allocator, text, &problem));
    try std.testing.expectEqual(expected, problem);
}

test "string_escape: escaping a value and decoding the result gives the value back" {
    const values = [_][]const u8{ "plain", "tab\there", "line\nbreak", "quote \" back \\ slash", "interp #{x} and # alone", "\x00\x07\x08\x0c\x0b\x1b\r", "é and 😀", "" };
    for (values) |value| {
        var literal: std.ArrayList(u8) = .empty;
        defer literal.deinit(std.testing.allocator);
        try appendEscaped(&literal, std.testing.allocator, value);
        try expectDecodes(value, literal.items);
        try std.testing.expect(std.mem.findScalar(u8, literal.items, '\n') == null);
    }
}

test "string_escape: \\u takes 4 hex digits, or 1 to 6 in braces, as UTF-8" {
    try expectDecodes("é", "\\u00e9");
    try expectDecodes("é", "\\u00E9");
    try expectDecodes("Ø mm", "\\u00d8 mm");
    try expectDecodes("é1", "\\u00e91"); // only four digits are the escape
    try expectDecodes("A", "\\u{41}");
    try expectDecodes("😀", "\\u{1F600}");
    try expectDecodes("\u{10FFFF}", "\\u{10FFFF}");
    try expectDecodes("\x00", "\\u{0}");
    try expectDecodes("⌀ 5", "\\u{2300} 5");
}

test "string_escape: a malformed \\u, a surrogate or a code point past U+10FFFF is an error" {
    try expectProblem(.{ .offset = 0, .len = 4, .kind = .malformed_unicode }, "\\u12g4");
    try expectProblem(.{ .offset = 2, .len = 4, .kind = .malformed_unicode }, "a \\u12");
    try expectProblem(.{ .offset = 0, .len = 2, .kind = .malformed_unicode }, "\\u");
    try expectProblem(.{ .offset = 0, .len = 4, .kind = .malformed_unicode }, "\\u{}");
    try expectProblem(.{ .offset = 0, .len = 5, .kind = .malformed_unicode }, "\\u{41");
    try expectProblem(.{ .offset = 0, .len = 9, .kind = .malformed_unicode }, "\\u{1234567}");
    try expectProblem(.{ .offset = 0, .len = 6, .kind = .surrogate, .value = 0xD800 }, "\\uD800");
    try expectProblem(.{ .offset = 0, .len = 8, .kind = .surrogate, .value = 0xDFFF }, "\\u{DFFF}");
    try expectProblem(.{ .offset = 0, .len = 10, .kind = .beyond_unicode, .value = 0x110000 }, "\\u{110000}");
}

test "string_escape: a backslash before a letter or digit no escape uses is an error" {
    try expectProblem(.{ .offset = 1, .len = 2, .kind = .unknown, .value = 'q' }, "a\\qb");
    try expectProblem(.{ .offset = 7, .len = 2, .kind = .unknown, .value = 'd' }, "C:\\temp\\data");
    try expectProblem(.{ .offset = 0, .len = 2, .kind = .unknown, .value = '1' }, "\\1");
    try expectProblem(.{ .offset = 0, .len = 2, .kind = .unknown, .value = '\n' }, "\\\nnext line");
    try expectProblem(.{ .offset = 1, .len = 1, .kind = .unknown }, "a\\");
}

test "string_escape: a backslash before punctuation or a space stands for it" {
    try expectDecodes("\"'\\#{}()[]<>|/!. ", "\\\"\\'\\\\\\#\\{\\}\\(\\)\\[\\]\\<\\>\\|\\/\\!\\.\\ ");
    try expectDecodes("\n\t\r\x0c\x0b\x08\x07\x1b\x00", "\\n\\t\\r\\f\\v\\b\\a\\e\\0");
}

fn expectRaw(expected: []const u8, text: []const u8, open: u8) !void {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(std.testing.allocator);
    try unescapeRawInto(&decoded, std.testing.allocator, text, open);
    try std.testing.expectEqualStrings(expected, decoded.items);
}

fn expectHeredoc(expected: []const u8, body: []const u8, strip_indent: bool) !void {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(std.testing.allocator);
    var problem: Problem = undefined;
    try unescapeHeredocInto(&decoded, std.testing.allocator, body, strip_indent, &problem);
    try std.testing.expectEqualStrings(expected, decoded.items);
}

test "string_escape: a <<~ heredoc loses its least indented line's indentation" {
    try expectHeredoc("a\n  b\nc\n", "    a\n      b\n    c\n", true);
    // A line of only spaces and tabs doesn't count, and loses what it can.
    try expectHeredoc("a\n\n \n b\n", "  a\n\n   \n   b\n", true);
    // A tab is one column; an escaped one is text, not indentation.
    try expectHeredoc("a\n b\n", "\ta\n\t b\n", true);
    try expectHeredoc("\t a\nb\n", "\\t a\nb\n", true);
    // Escapes are decoded after the indentation goes; CRLF line ends stay.
    try expectHeredoc("x\ty\r\nz\r\n", "  x\\ty\r\n  z\r\n", true);
    try expectHeredoc("", "", true);
}

test "string_escape: <<- and << heredocs keep their text as written" {
    try expectHeredoc("    a\n      b\n", "    a\n      b\n", false);
    try expectHeredoc("  \t\n", "  \\t\n", false);
}

test "string_escape: a heredoc's invalid escape is placed from the start of the body" {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(std.testing.allocator);
    var problem: Problem = undefined;
    try std.testing.expectError(error.InvalidEscape, unescapeHeredocInto(&decoded, std.testing.allocator, "  ok\n  a\\qb\n", true, &problem));
    try std.testing.expectEqual(@as(usize, 8), problem.offset);
    try std.testing.expectEqual(@as(u32, 'q'), problem.value);
}

test "string_escape: a single-quoted literal has only \\\\ and its delimiter as escapes" {
    try expectRaw("C:\\data\\n", "C:\\data\\n", '\'');
    try expectRaw("it's \\ here", "it\\'s \\\\ here", '\'');
    try expectRaw("\\u00e9 \\q", "\\u00e9 \\q", '\'');
    try expectRaw("a ) b ( c \\]", "a \\) b \\( c \\]", '(');
    try expectRaw("trailing \\", "trailing \\", '\'');
}
