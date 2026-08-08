const std = @import("std");

pub const SlashKind = enum {
    slash,
    comment,
    block_comment,
};

pub const SlashResult = struct {
    lexeme: []const u8,
    kind: SlashKind,
};

pub const LexerUtils = struct {
    pub fn skipWhitespace(buffer: []const u8, index: *usize, line: *u32, col: *u32, comptime skip_newlines: bool) void {
        while (index.* < buffer.len) {
            const c = buffer[index.*];
            if (c == ' ' or c == '\t' or c == '\r') {
                index.* += 1;
                col.* += 1;
            } else if (skip_newlines and c == '\n') {
                index.* += 1;
                line.* += 1;
                col.* = 1;
            } else {
                break;
            }
        }
    }

    pub fn consumeNumber(buffer: []const u8, index: *usize, col: *u32) []const u8 {
        const start = index.*;
        if (start >= buffer.len) return buffer[start..index.*];

        // Check for Hexadecimal (0x), Binary (0b), and Octal (0o)
        if (buffer[index.*] == '0' and index.* + 1 < buffer.len) {
            const next_c = buffer[index.* + 1];
            if (next_c == 'x' or next_c == 'X') {
                index.* += 2;
                col.* += 2;
                while (index.* < buffer.len) {
                    const c = buffer[index.*];
                    if (std.ascii.isHex(c) or c == '_') {
                        index.* += 1;
                        col.* += 1;
                    } else break;
                }
                return buffer[start..index.*];
            } else if (next_c == 'b' or next_c == 'B') {
                index.* += 2;
                col.* += 2;
                while (index.* < buffer.len) {
                    const c = buffer[index.*];
                    if (c == '0' or c == '1' or c == '_') {
                        index.* += 1;
                        col.* += 1;
                    } else break;
                }
                return buffer[start..index.*];
            } else if (next_c == 'o' or next_c == 'O') {
                index.* += 2;
                col.* += 2;
                while (index.* < buffer.len) {
                    const c = buffer[index.*];
                    if ((c >= '0' and c <= '7') or c == '_') {
                        index.* += 1;
                        col.* += 1;
                    } else break;
                }
                return buffer[start..index.*];
            }
        }

        // Standard Decimal, Leading Dot (.5), and Scientific Notation (1.5e-3)
        while (index.* < buffer.len) {
            const c = buffer[index.*];
            if (std.ascii.isDigit(c) or c == '_') {
                index.* += 1;
                col.* += 1;
            } else if (c == '.') {
                if (index.* + 1 < buffer.len and buffer[index.* + 1] == '.') break; // Avoid range operator `..`
                index.* += 1;
                col.* += 1;
            } else if (c == 'e' or c == 'E') {
                var advance_count: usize = 1;
                if (index.* + 1 < buffer.len and (buffer[index.* + 1] == '+' or buffer[index.* + 1] == '-')) {
                    advance_count = 2;
                }
                if (index.* + advance_count < buffer.len and std.ascii.isDigit(buffer[index.* + advance_count])) {
                    index.* += advance_count;
                    col.* += @intCast(advance_count);
                } else break;
            } else break;
        }
        return buffer[start..index.*];
    }

    pub inline fn isIdentStart(c: u8, comptime allow_at: bool) bool {
        if (std.ascii.isAlphabetic(c)) return true;
        if (c == '_' or c == '$') return true;
        if (allow_at and c == '@') return true;
        if (c >= 0xC0) return true; // Allow UTF-8 multi-byte start characters
        return false;
    }

    pub inline fn isIdentChar(c: u8, comptime is_openscad: bool) bool {
        if (std.ascii.isAlphanumeric(c)) return true;
        if (c == '_' or c == '$') return true;
        if (!is_openscad and (c == '?' or c == '!' or c == '@')) return true;
        if (c >= 0x80) return true; // Allow UTF-8 continuation bytes
        return false;
    }

    pub fn consumeIdentLexeme(
        buffer: []const u8,
        index: *usize,
        col: *u32,
        comptime is_openscad: bool,
    ) []const u8 {
        const start = index.*;
        while (index.* < buffer.len) {
            const c = buffer[index.*];
            if (c < 0x80) {
                // Standard ASCII parsing
                if (isIdentChar(c, is_openscad)) {
                    index.* += 1;
                    col.* += 1;
                } else {
                    break;
                }
            } else {
                // UTF-8 Validation and Stepping
                const seq_len = std.unicode.utf8ByteSequenceLength(c) catch break;
                if (index.* + seq_len <= buffer.len) {
                    const slice = buffer[index.* .. index.* + seq_len];
                    // Validate it forms a legal Unicode codepoint
                    _ = std.unicode.utf8Decode(slice) catch break;
                    index.* += seq_len;
                    col.* += 1; // Advance col by 1 visual character
                } else {
                    break;
                }
            }
        }
        return buffer[start..index.*];
    }

    pub fn consumeSlashOrComment(
        buffer: []const u8,
        index: *usize,
        line: *u32,
        col: *u32,
    ) SlashResult {
        const start = index.*;
        index.* += 1;
        col.* += 1;

        if (index.* < buffer.len) {
            if (buffer[index.*] == '/') {
                while (index.* < buffer.len and buffer[index.*] != '\n') {
                    index.* += 1;
                    col.* += 1;
                }
                return .{ .lexeme = buffer[start..index.*], .kind = .comment };
            } else if (buffer[index.*] == '*') {
                index.* += 1;
                col.* += 1;
                while (index.* < buffer.len) {
                    if (buffer[index.*] == '*' and index.* + 1 < buffer.len and buffer[index.* + 1] == '/') {
                        index.* += 2;
                        col.* += 2;
                        break;
                    }
                    if (buffer[index.*] == '\n') {
                        line.* += 1;
                        col.* = 0;
                    }
                    index.* += 1;
                    col.* += 1;
                }
                return .{ .lexeme = buffer[start..index.*], .kind = .block_comment };
            }
        }
        return .{ .lexeme = "/", .kind = .slash };
    }

    pub fn consumeQuotedString(
        buffer: []const u8,
        index: *usize,
        line: *u32,
        col: *u32,
        quote: u8,
    ) []const u8 {
        index.* += 1;
        col.* += 1;
        const start = index.*;
        while (index.* < buffer.len) {
            const c = buffer[index.*];
            if (c == '\n') {
                line.* += 1;
                col.* = 0;
            }
            if (c == '\\') {
                index.* += 1;
                col.* += 1;
                if (index.* < buffer.len) {
                    index.* += 1;
                    col.* += 1;
                }
                continue;
            }
            if (c == quote) {
                break;
            }
            index.* += 1;
            col.* += 1;
        }
        const lexeme = buffer[start..index.*];
        if (index.* < buffer.len) {
            index.* += 1;
            col.* += 1;
        }
        return lexeme;
    }
};
