//! What KupCAD reads as a name: the characters an identifier starts with and is made of,
//! where one ends, the reserved words, and whether a name can be written bare, as a symbol
//! (`:name`) or a label (`name:`). The lexer scans names with these, and `Value.stringify`
//! and the formatter ask them how to write a name back, so what one writes the other reads.

const std = @import("std");

/// The reserved words. The lexer reads each as its `keyword_<word>` tag and builds its
/// table from this list, so a word without a tag doesn't compile.
pub const KEYWORDS = [_][]const u8{
    "do",     "end",   "if",    "import",  "from",   "class", "def",    "true",
    "false",  "nil",   "else",  "elsif",   "module", "yield", "return", "then",
    "unless", "while", "until", "for",     "break",  "next",  "case",   "when",
    "self",   "super", "and",   "or",      "not",    "begin", "rescue", "ensure",
    "export", "as",    "with",  "private", "public",
};

const KEYWORD_SET = std.StaticStringMap(void).initComptime(blk: {
    var entries: [KEYWORDS.len]struct { []const u8 } = undefined;
    for (KEYWORDS, &entries) |word, *entry| entry.* = .{word};
    break :blk entries;
});

/// Whether `c` can start an identifier: a letter, `_`, `$`, the first byte of a UTF-8
/// sequence, and `@` when `allow_at`.
pub inline fn isStart(c: u8, comptime allow_at: bool) bool {
    if (std.ascii.isAlphabetic(c)) return true;
    if (c == '_' or c == '$') return true;
    if (allow_at and c == '@') return true;
    if (c >= 0xC0) return true;
    return false;
}

/// Whether `c` can be part of an identifier: a letter, a digit, `_`, `$`, `?`, `!`, `@`, or
/// any byte of a UTF-8 sequence.
pub inline fn isChar(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    if (c == '_' or c == '$') return true;
    if (c == '?' or c == '!' or c == '@') return true;
    if (c >= 0x80) return true;
    return false;
}

/// Whether a name starts at `buffer[start]`: an identifier, a constant, an `@name`, or a
/// global (`$name`; a `$` before anything else, another `$` included, starts none, and is a
/// character the language doesn't use).
pub fn startsAt(buffer: []const u8, start: usize) bool {
    if (start >= buffer.len) return false;
    if (buffer[start] != '$') return isStart(buffer[start], true);
    return start + 1 < buffer.len and buffer[start + 1] != '$' and isStart(buffer[start + 1], false);
}

/// Where the name starting at `start` ends: past its characters, each UTF-8 sequence in it
/// a valid one.
pub fn end(buffer: []const u8, start: usize) usize {
    var i = start;
    while (i < buffer.len) {
        const c = buffer[i];
        if (c < 0x80) {
            if (!isChar(c)) break;
            i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(c) catch break;
        if (i + seq_len > buffer.len or !std.unicode.utf8ValidateSlice(buffer[i .. i + seq_len])) break;
        i += seq_len;
    }
    return i;
}

pub fn isKeyword(name: []const u8) bool {
    return KEYWORD_SET.has(name);
}

/// Where the name of a bare symbol starting at `start` ends (`name`, `_internal`, `θ_angle`,
/// `valid?`, `destroy!`, `x=`), or `start` when none starts there. A trailing `=` is part
/// of it unless `>` follows, which makes it `=>`.
pub fn bareSymbolEnd(buffer: []const u8, start: usize) usize {
    if (start >= buffer.len or !isStart(buffer[start], true)) return start;
    var i = start;
    while (i < buffer.len and isChar(buffer[i])) i += 1;
    if (i < buffer.len and buffer[i] == '=' and (i + 1 == buffer.len or buffer[i + 1] != '>')) i += 1;
    return i;
}

/// Whether `name` reads back from `:name`; any other symbol (`%i[a-b]`) is written quoted
/// or in `%i[]`.
pub fn isBareSymbol(name: []const u8) bool {
    return name.len > 0 and bareSymbolEnd(name, 0) == name.len;
}

/// Whether `name` reads as one identifier or constant, as the name of a map key or named
/// argument written `name:` must; a keyword (`if`) or any other name isn't one.
pub fn isLabelName(name: []const u8) bool {
    return startsAt(name, 0) and end(name, 0) == name.len and !isKeyword(name);
}
