const std = @import("std");

pub const Location = struct {
    line: u32,
    col: u32,
    offset: u32,
    length: u32 = 0,
    file_id: u32, // Maps to a file path in your centralized Symbol/String Pool
};

pub const Comment = struct {
    lexeme: []const u8,
    loc: Location,
};

/// A generic Token wrapper that takes a language-specific Tag enum.
pub fn Token(comptime TagType: type) type {
    return struct {
        tag: TagType,
        loc: Location,
        lexeme: []const u8,
    };
}

/// A generic 2-token buffered lexer wrapper providing unified lookahead for parsers.
pub fn BufferedLexer(comptime LexerType: type, comptime TokenType: type, comptime TagType: type) type {
    return struct {
        lexer: *LexerType,
        previous: TokenType,
        current: TokenType,
        next_tok: TokenType,

        const Self = @This();

        pub fn init(lexer: *LexerType) Self {
            var self = Self{
                .lexer = lexer,
                .previous = .{ .tag = .eof, .loc = .{ .line = 1, .col = 1, .offset = 0, .length = 0, .file_id = 0 }, .lexeme = "" },
                .current = undefined,
                .next_tok = undefined,
            };
            self.next_tok = lexer.next();
            self.advance();
            return self;
        }

        pub fn advance(self: *Self) void {
            self.previous = self.current;
            self.current = self.next_tok;
            self.next_tok = self.lexer.next();
        }

        pub inline fn peekTag(self: *const Self) TagType {
            return self.next_tok.tag;
        }

        pub inline fn peekToken(self: *const Self) TokenType {
            return self.next_tok;
        }
    };
}
