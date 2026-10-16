//! The escape sequences of string literals: what `\n`, `\"`, `\u{1F600}` and the rest decode
//! to when a script is parsed, and how a decoded value is written back as a literal (the
//! formatter, for a string whose source text can't be reused). The two agree, so a value
//! written and parsed again is the same value.
//!
//! A backslash before a letter or digit must start a known escape: `\q` or `\d` is a syntax
//! error, where it used to stand for the letter. A backslash before any other printable
//! ASCII character (a quote, `\`, `#`, a %-literal's delimiter, a space) stands for it.

const std = @import("std");

/// The most hex digits `\u{...}` takes, enough for U+10FFFF.
const MAX_BRACED_HEX_DIGITS = 6;
/// The hex digits `\uXXXX` takes.
const UNBRACED_HEX_DIGITS = 4;
/// The last Unicode code point.
const MAX_CODE_POINT = 0x10FFFF;

/// Why a backslash in `text` starts no escape sequence, and where.
pub const Problem = struct {
    /// The sequence's backslash, as an offset into the text, and its length.
    offset: usize,
    len: usize,
    kind: Kind,
    /// The letter after the backslash (`unknown`), or the code point (`surrogate`,
    /// `beyond_unicode`).
    value: u32 = 0,

    pub const Kind = enum {
        /// A letter, digit or other character no escape starts with, or nothing at all
        /// (the text ends at the backslash).
        unknown,
        /// `\u` without 4 hex digits, or `\u{` without 1 to 6 and a closing brace.
        malformed_unicode,
        /// `\u` naming a UTF-16 surrogate (U+D800 to U+DFFF), which is no character.
        surrogate,
        /// `\u` naming a code point past U+10FFFF.
        beyond_unicode,
    };
};

pub const Error = error{InvalidEscape} || std.mem.Allocator.Error;

/// The byte an escape letter stands for, or null when the letter starts no simple escape.
fn decodeLetter(letter: u8) ?u8 {
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
        else => if (letter < 0x80 and std.ascii.isPrint(letter) and !std.ascii.isAlphanumeric(letter)) letter else null,
    };
}

/// `text` with its escape sequences decoded, appended to `out`. At the first backslash that
/// starts none, fails with error.InvalidEscape and describes it in `problem`.
pub fn unescapeInto(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8, problem: *Problem) Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\\') {
            try out.append(allocator, text[i]);
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i + 1] == 'u') {
            var bytes: [4]u8 = undefined;
            const seq = try decodeUnicode(text, i, &bytes, problem);
            try out.appendSlice(allocator, bytes[0..seq.bytes]);
            i += seq.len;
            continue;
        }
        const letter: ?u8 = if (i + 1 < text.len) text[i + 1] else null;
        const byte = if (letter) |l| decodeLetter(l) else null;
        try out.append(allocator, byte orelse {
            problem.* = .{ .offset = i, .len = if (letter != null) 2 else 1, .kind = .unknown, .value = letter orelse 0 };
            return error.InvalidEscape;
        });
        i += 2;
    }
}

/// A decoded `\u` sequence: the UTF-8 bytes it wrote and how long it is in the text.
const UnicodeSequence = struct { bytes: u3, len: usize };

/// The `\uXXXX` or `\u{X...}` at `at` (its backslash), as UTF-8 in `bytes`.
fn decodeUnicode(text: []const u8, at: usize, bytes: *[4]u8, problem: *Problem) error{InvalidEscape}!UnicodeSequence {
    const digits_at = at + 2;
    const braced = digits_at < text.len and text[digits_at] == '{';
    const first = if (braced) digits_at + 1 else digits_at;
    var end = first;
    const max_digits: usize = if (braced) MAX_BRACED_HEX_DIGITS else UNBRACED_HEX_DIGITS;
    while (end < text.len and end - first < max_digits and std.ascii.isHex(text[end])) end += 1;
    const digit_count = end - first;
    const closed = !braced or (end < text.len and text[end] == '}');
    const len = end + @intFromBool(braced and closed) - at;
    if ((braced and (digit_count == 0 or !closed)) or (!braced and digit_count != UNBRACED_HEX_DIGITS)) {
        problem.* = .{ .offset = at, .len = len, .kind = .malformed_unicode };
        return error.InvalidEscape;
    }
    // At most 6 hex digits, so it fits
    const code_point = std.fmt.parseInt(u32, text[first..end], 16) catch unreachable;
    if (code_point > MAX_CODE_POINT or (code_point >= 0xD800 and code_point <= 0xDFFF)) {
        problem.* = .{ .offset = at, .len = len, .kind = if (code_point > MAX_CODE_POINT) .beyond_unicode else .surrogate, .value = code_point };
        return error.InvalidEscape;
    }
    // A code point no surrogate and within Unicode always encodes
    const written = std.unicode.utf8Encode(@intCast(code_point), bytes) catch unreachable;
    return .{ .bytes = written, .len = len };
}

/// `value` as the content of a double-quoted literal, appended to `out`: the characters
/// `decodeLetter` has letters for, the quote, the backslash and a `#{` are escaped;
/// everything else is written as it is.
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

fn expectDecodes(expected: []const u8, text: []const u8) !void {
    var decoded: std.ArrayListUnmanaged(u8) = .empty;
    defer decoded.deinit(std.testing.allocator);
    var problem: Problem = undefined;
    try unescapeInto(&decoded, std.testing.allocator, text, &problem);
    try std.testing.expectEqualStrings(expected, decoded.items);
}

fn expectProblem(expected: Problem, text: []const u8) !void {
    var decoded: std.ArrayListUnmanaged(u8) = .empty;
    defer decoded.deinit(std.testing.allocator);
    var problem: Problem = undefined;
    errdefer std.debug.print("text: {s}\n", .{text});
    try std.testing.expectError(error.InvalidEscape, unescapeInto(&decoded, std.testing.allocator, text, &problem));
    try std.testing.expectEqual(expected, problem);
}

test "string_escape: escaping a value and decoding the result gives the value back" {
    const values = [_][]const u8{ "plain", "tab\there", "line\nbreak", "quote \" back \\ slash", "interp #{x} and # alone", "\x00\x07\x08\x0c\x0b\x1b\r", "é and 😀", "" };
    for (values) |value| {
        var literal: std.ArrayListUnmanaged(u8) = .empty;
        defer literal.deinit(std.testing.allocator);
        try appendEscaped(&literal, std.testing.allocator, value);
        try expectDecodes(value, literal.items);
        try std.testing.expect(std.mem.indexOfScalar(u8, literal.items, '\n') == null);
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
