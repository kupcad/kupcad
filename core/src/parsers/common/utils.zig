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
        while (index.* < buffer.len) {
            const c = buffer[index.*];
            if (std.ascii.isDigit(c)) {
                index.* += 1;
                col.* += 1;
            } else if (c == '.') {
                if (index.* + 1 < buffer.len and buffer[index.* + 1] == '.') break;
                index.* += 1;
                col.* += 1;
            } else {
                break;
            }
        }
        return buffer[start..index.*];
    }

    pub inline fn isIdentStart(c: u8, comptime allow_at: bool) bool {
        if (std.ascii.isAlphabetic(c)) return true;
        if (c == '_' or c == '$') return true;
        if (allow_at and c == '@') return true;
        return false;
    }

    pub inline fn isIdentChar(c: u8, comptime is_kupcad: bool) bool {
        if (std.ascii.isAlphanumeric(c)) return true;
        if (c == '_' or c == '$') return true;
        if (is_kupcad and (c == '?' or c == '!' or c == '@')) return true;
        return false;
    }
};
