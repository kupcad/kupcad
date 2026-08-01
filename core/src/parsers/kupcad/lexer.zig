const std = @import("std");
const common_token = @import("../common/token.zig");

pub const Tag = enum {
    eof,
    newline,
    ident,
    constant,
    number,
    string,
    symbol,
    param_doc,
    comment,

    keyword_do,
    keyword_end,
    keyword_if,
    keyword_import,
    keyword_from,

    plus,
    minus,
    ampersand,
    equal,
    dot,
    comma,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    colon,
};

pub const Token = common_token.Token(Tag);

pub const Lexer = struct {
    buffer: []const u8,
    index: usize,
    line: u32,
    col: u32,
    file_id: u32,

    pub fn init(buffer: []const u8, file_id: u32) Lexer {
        return .{
            .buffer = buffer,
            .index = 0,
            .line = 1,
            .col = 1,
            .file_id = file_id,
        };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.index >= self.buffer.len) {
            return self.makeToken(.eof, 0);
        }

        const start_loc = common_token.Location{ .line = self.line, .col = self.col, .file_id = self.file_id };
        const c = self.peek();

        return switch (c) {
            '\n' => self.consumeNewline(start_loc),
            '+' => self.consumeChar(.plus, start_loc),
            '-' => self.consumeChar(.minus, start_loc),
            '&' => self.consumeChar(.ampersand, start_loc),
            '=' => self.consumeChar(.equal, start_loc),
            '.' => self.consumeChar(.dot, start_loc),
            ',' => self.consumeChar(.comma, start_loc),
            '(' => self.consumeChar(.l_paren, start_loc),
            ')' => self.consumeChar(.r_paren, start_loc),
            '[' => self.consumeChar(.l_bracket, start_loc),
            ']' => self.consumeChar(.r_bracket, start_loc),
            '{' => self.consumeChar(.l_brace, start_loc),
            '}' => self.consumeChar(.r_brace, start_loc),
            ':' => self.consumeSymbolOrColon(start_loc),
            '"' => self.consumeString(start_loc),
            '#' => self.consumeCommentOrParam(start_loc),
            else => {
                if (std.ascii.isAlphabetic(c) or c == '_') {
                    return self.consumeIdentOrKeyword(start_loc);
                } else if (std.ascii.isDigit(c)) {
                    return self.consumeNumber(start_loc);
                }
                self.advance();
                return self.makeToken(.eof, 0);
            },
        };
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.index < self.buffer.len) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn consumeCommentOrParam(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        while (self.index < self.buffer.len and self.peek() != '\n') {
            self.advance();
        }
        const lexeme = self.buffer[start..self.index];

        var i: usize = 1;
        while (i < lexeme.len and (lexeme[i] == ' ' or lexeme[i] == '\t')) {
            i += 1;
        }

        if (i + 6 <= lexeme.len and std.ascii.eqlIgnoreCase(lexeme[i .. i + 6], "@param")) {
            return .{ .tag = .param_doc, .loc = start_loc, .lexeme = lexeme };
        }

        return .{ .tag = .comment, .loc = start_loc, .lexeme = lexeme };
    }

    fn consumeIdentOrKeyword(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        const is_constant = std.ascii.isUpper(self.peek());

        while (self.index < self.buffer.len) {
            const c = self.peek();
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '?' or c == '!') {
                self.advance();
            } else {
                break;
            }
        }

        const lexeme = self.buffer[start..self.index];
        var tag = if (is_constant) Tag.constant else Tag.ident;

        if (std.mem.eql(u8, lexeme, "do")) tag = .keyword_do;
        if (std.mem.eql(u8, lexeme, "end")) tag = .keyword_end;
        if (std.mem.eql(u8, lexeme, "if")) tag = .keyword_if;
        if (std.mem.eql(u8, lexeme, "import")) tag = .keyword_import;
        if (std.mem.eql(u8, lexeme, "from")) tag = .keyword_from;

        return .{ .tag = tag, .loc = start_loc, .lexeme = lexeme };
    }

    fn consumeSymbolOrColon(self: *Lexer, start_loc: common_token.Location) Token {
        self.advance();
        if (self.index < self.buffer.len and std.ascii.isAlphabetic(self.peek())) {
            const start = self.index;
            while (self.index < self.buffer.len and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_')) {
                self.advance();
            }
            return .{ .tag = .symbol, .loc = start_loc, .lexeme = self.buffer[start_loc.col - 1 .. self.index] };
        }
        return .{ .tag = .colon, .loc = start_loc, .lexeme = ":" };
    }

    fn consumeNumber(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        while (self.index < self.buffer.len) {
            const c = self.peek();
            if (std.ascii.isDigit(c) or c == '.') {
                self.advance();
            } else {
                break;
            }
        }
        return .{ .tag = .number, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn consumeString(self: *Lexer, start_loc: common_token.Location) Token {
        self.advance();
        const start = self.index;
        while (self.index < self.buffer.len and self.peek() != '"') {
            self.advance();
        }
        const lexeme = self.buffer[start..self.index];
        if (self.index < self.buffer.len) self.advance();
        return .{ .tag = .string, .loc = start_loc, .lexeme = lexeme };
    }

    fn consumeNewline(self: *Lexer, start_loc: common_token.Location) Token {
        self.advance();
        self.line += 1;
        self.col = 1;
        return .{ .tag = .newline, .loc = start_loc, .lexeme = "\\n" };
    }

    fn consumeChar(self: *Lexer, tag: Tag, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance();
        return .{ .tag = tag, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn peek(self: *const Lexer) u8 {
        return self.buffer[self.index];
    }

    fn advance(self: *Lexer) void {
        self.index += 1;
        self.col += 1;
    }

    fn makeToken(self: *const Lexer, tag: Tag, len: usize) Token {
        _ = len;
        return .{
            .tag = tag,
            .loc = .{ .line = self.line, .col = self.col, .file_id = self.file_id },
            .lexeme = "",
        };
    }
};
