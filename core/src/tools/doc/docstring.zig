//! `parse`: reads a `# @tag text` comment, and the comment lines that continue it, into its tag
//! and its text, as YARD does. `kupcad doc` reads a script's header with it (extractor.zig);
//! to the lexer and the parser such a line is a comment like any other.

const std = @import("std");

/// How far a line must be indented past its `#` to continue the tag above it, as in YARD.
const CONTINUATION_INDENT = 2;
/// How many columns a tab counts for in that indentation.
const TAB_WIDTH = 3;

pub const Docstring = struct {
    /// The tag's name, without its `@`: "title" in `# @title Bracket`; a slice of the text read.
    tag: []const u8,
    /// The text after the tag, its continuation lines joined by newlines, as YARD keeps them
    /// (a renderer folds them). Owned by the caller.
    content: []u8,
};

/// The docstring `raw` starts with: its first line `# @tag text`, and each comment line after it
/// that continues it (indented two spaces or more past its `#`, starting no other tag); null
/// when the first line holds no tag. Reading stops at the first line that doesn't continue it.
pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !?Docstring {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    const first_text = afterHash(lines.first()) orelse return null;
    const text = std.mem.trimStart(u8, first_text, " \t");
    if (text.len < 2 or text[0] != '@') return null;
    const tag_end = std.mem.findAny(u8, text, " \t\r") orelse text.len;

    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(allocator);
    try content.appendSlice(allocator, trimLine(text[tag_end..]));
    while (lines.next()) |line| {
        const rest = afterHash(line) orelse break;
        const continuation = continuationText(rest) orelse break;
        try content.append(allocator, '\n');
        try content.appendSlice(allocator, trimEnd(continuation));
    }
    // A blank continuation line last adds nothing
    content.shrinkRetainingCapacity(std.mem.trimEnd(u8, content.items, "\n").len);
    return .{ .tag = text[1..tag_end], .content = try content.toOwnedSlice(allocator) };
}

/// What follows the `#` of a comment line (indentation before it allowed), or null when
/// `line` is no comment.
fn afterHash(line: []const u8) ?[]const u8 {
    const text = std.mem.trimStart(u8, line, " \t\r");
    if (text.len == 0 or text[0] != '#') return null;
    return text[1..];
}

/// The text of a line continuing a tag, `rest` what follows its `#`: without the one space a
/// comment starts with and the two of the continuation's indentation, so deeper indentation
/// stays (a list nested in the text). Null when it doesn't continue one.
fn continuationText(rest: []const u8) ?[]const u8 {
    var indent: usize = 0;
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {
        indent += if (rest[i] == '\t') TAB_WIDTH else 1;
    }
    if (indent < CONTINUATION_INDENT or (i < rest.len and rest[i] == '@')) return null;

    var consumed: usize = 0;
    var start: usize = 0;
    while (start < rest.len and consumed < 1 + CONTINUATION_INDENT) : (start += 1) {
        switch (rest[start]) {
            ' ' => consumed += 1,
            '\t' => consumed += TAB_WIDTH,
            else => break,
        }
    }
    return rest[start..];
}

/// The text of the tag line after the tag: without the spaces around it.
fn trimLine(text: []const u8) []const u8 {
    return std.mem.trimStart(u8, trimEnd(text), " \t");
}

fn trimEnd(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, " \t\r");
}
