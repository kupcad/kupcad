const std = @import("std");
const testing = std.testing;

pub fn ExpectedToken(comptime TagType: type) type {
    return struct {
        tag: TagType,
        lexeme: []const u8,
    };
}

pub inline fn t(tag: anytype, lexeme: []const u8) ExpectedToken(@TypeOf(tag)) {
    return .{ .tag = tag, .lexeme = lexeme };
}

pub fn expectTokens(comptime LexerType: type, source: []const u8, expected: anytype) !void {
    var lexer = LexerType.init(source, 0);
    inline for (expected) |exp| {
        const tok = lexer.next();
        try testing.expectEqual(exp.tag, tok.tag);
        try testing.expectEqualStrings(exp.lexeme, tok.lexeme);
    }
}
