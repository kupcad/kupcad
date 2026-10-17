//! `LexerUtils`, the scanning helpers lexer.zig reads its source with: whitespace, numbers,
//! identifiers and quoted strings.

const std = @import("std");

pub const LexerUtils = struct {
    /// Past spaces, tabs and carriage returns; a newline is a token, so it stays.
    pub fn skipWhitespace(buffer: []const u8, index: *usize) void {
        while (index.* < buffer.len) {
            const c = buffer[index.*];
            if (c != ' ' and c != '\t' and c != '\r') break;
            index.* += 1;
        }
    }

    pub fn consumeNumber(buffer: []const u8, index: *usize) []const u8 {
        const start = index.*;
        if (start >= buffer.len) return buffer[start..index.*];

        // Check for Hexadecimal (0x), Binary (0b), and Octal (0o)
        if (buffer[index.*] == '0' and index.* + 1 < buffer.len) {
            const next_c = buffer[index.* + 1];
            if (next_c == 'x' or next_c == 'X') {
                index.* += 2;
                while (index.* < buffer.len) {
                    const c = buffer[index.*];
                    if (std.ascii.isHex(c) or c == '_') {
                        index.* += 1;
                    } else break;
                }
                return buffer[start..index.*];
            } else if (next_c == 'b' or next_c == 'B') {
                index.* += 2;
                while (index.* < buffer.len) {
                    const c = buffer[index.*];
                    if (c == '0' or c == '1' or c == '_') {
                        index.* += 1;
                    } else break;
                }
                return buffer[start..index.*];
            } else if (next_c == 'o' or next_c == 'O') {
                index.* += 2;
                while (index.* < buffer.len) {
                    const c = buffer[index.*];
                    if ((c >= '0' and c <= '7') or c == '_') {
                        index.* += 1;
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
            } else if (c == '.') {
                // Avoid range operator `..`
                if (index.* + 1 < buffer.len and buffer[index.* + 1] == '.') break;

                // Only consume '.' as a decimal point IF the next character is a digit
                // If it is followed by an identifier (e.g., `3.14159.round`), leave the dot for method dispatch
                if (index.* + 1 < buffer.len and std.ascii.isDigit(buffer[index.* + 1])) {
                    index.* += 1;
                } else break;
            } else if (c == 'e' or c == 'E') {
                var advance_count: usize = 1;
                if (index.* + 1 < buffer.len and (buffer[index.* + 1] == '+' or buffer[index.* + 1] == '-')) {
                    advance_count = 2;
                }
                if (index.* + advance_count < buffer.len and std.ascii.isDigit(buffer[index.* + advance_count])) {
                    index.* += advance_count;
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

    pub inline fn isIdentChar(c: u8) bool {
        if (std.ascii.isAlphanumeric(c)) return true;
        if (c == '_' or c == '$') return true;
        if (c == '?' or c == '!' or c == '@') return true;
        if (c >= 0x80) return true; // Allow UTF-8 continuation bytes
        return false;
    }

    pub fn consumeIdentLexeme(buffer: []const u8, index: *usize) []const u8 {
        const start = index.*;
        while (index.* < buffer.len) {
            const c = buffer[index.*];
            if (c < 0x80) {
                // Standard ASCII parsing
                if (isIdentChar(c)) {
                    index.* += 1;
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
                } else {
                    break;
                }
            }
        }

        // Allow exactly one '?' or '!' strictly as a terminal identifier suffix
        if (index.* < buffer.len) {
            const c = buffer[index.*];
            if (c == '?' or c == '!') {
                index.* += 1;
            }
        }

        return buffer[start..index.*];
    }

    /// The text between `quote` at `index` and the next unescaped `quote`, leaving `index`
    /// past it; null when the buffer ends first (`index` is then at its end).
    pub fn consumeQuotedString(
        buffer: []const u8,
        index: *usize,
        quote: u8,
    ) ?[]const u8 {
        index.* += 1;
        const start = index.*;
        while (index.* < buffer.len) {
            const c = buffer[index.*];
            if (c == '\\') {
                index.* += 1;
                if (index.* < buffer.len) {
                    index.* += 1;
                }
                continue;
            }
            if (c == quote) {
                index.* += 1;
                return buffer[start .. index.* - 1];
            }
            index.* += 1;
        }
        return null;
    }
};
