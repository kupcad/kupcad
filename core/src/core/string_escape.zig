//! The escape sequences of string literals: what `\n`, `\"` and the rest decode to when a
//! script is parsed, and how a decoded value is written back as a literal (the formatter,
//! for a string whose source text can't be reused). The two agree, so a value written and
//! parsed again is the same value.

const std = @import("std");

/// The byte an escape letter stands for; a letter with no meaning stands for itself
/// (`\"`, `\\`, `\#` and any other).
pub fn decode(letter: u8) u8 {
    return switch (letter) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'f' => 12,
        'v' => 11,
        'b' => 8,
        'a' => 7,
        'e' => 27,
        '0' => 0,
        else => letter,
    };
}

/// `text` with its escape sequences decoded, appended to `out`. A backslash ending the
/// text stands for itself.
pub fn unescapeInto(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            try out.append(allocator, decode(text[i + 1]));
            i += 1;
        } else {
            try out.append(allocator, text[i]);
        }
    }
}

/// `value` as the content of a double-quoted literal, appended to `out`: the characters
/// `decode` has letters for, the quote, the backslash and a `#{` are escaped; everything
/// else is written as it is.
pub fn appendEscaped(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value, 0..) |c, i| {
        const escaped: ?[]const u8 = switch (c) {
            '\n' => "\\n",
            '\t' => "\\t",
            '\r' => "\\r",
            12 => "\\f",
            11 => "\\v",
            8 => "\\b",
            7 => "\\a",
            27 => "\\e",
            0 => "\\0",
            '"' => "\\\"",
            '\\' => "\\\\",
            '#' => if (i + 1 < value.len and value[i + 1] == '{') "\\#" else null,
            else => null,
        };
        if (escaped) |e| try out.appendSlice(allocator, e) else try out.append(allocator, c);
    }
}

test "string_escape: escaping a value and decoding the result gives the value back" {
    const values = [_][]const u8{ "plain", "tab\there", "line\nbreak", "quote \" back \\ slash", "interp #{x} and # alone", "\x00\x07\x08\x0c\x0b\x1b\r", "" };
    for (values) |value| {
        var literal: std.ArrayListUnmanaged(u8) = .empty;
        defer literal.deinit(std.testing.allocator);
        try appendEscaped(&literal, std.testing.allocator, value);
        var decoded: std.ArrayListUnmanaged(u8) = .empty;
        defer decoded.deinit(std.testing.allocator);
        try unescapeInto(&decoded, std.testing.allocator, literal.items);
        try std.testing.expectEqualStrings(value, decoded.items);
        try std.testing.expect(std.mem.indexOfScalar(u8, literal.items, '\n') == null);
    }
}

test "string_escape: unknown escapes and a trailing backslash stand for themselves" {
    var decoded: std.ArrayListUnmanaged(u8) = .empty;
    defer decoded.deinit(std.testing.allocator);
    try unescapeInto(&decoded, std.testing.allocator, "a\\qb\\");
    try std.testing.expectEqualStrings("aqb\\", decoded.items);
}
