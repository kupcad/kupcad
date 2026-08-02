const std = @import("std");

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

        // 1. Check for Hexadecimal (0x), Binary (0b), and Octal (0o)
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

        // 2. Standard Decimal, Leading Dot (.5), and Scientific Notation (1.5e-3)
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
        return false;
    }

    pub inline fn isIdentChar(c: u8, comptime is_openscad: bool) bool {
        if (std.ascii.isAlphanumeric(c)) return true;
        if (c == '_' or c == '$') return true;
        if (!is_openscad and (c == '?' or c == '!' or c == '@')) return true;
        return false;
    }
};
