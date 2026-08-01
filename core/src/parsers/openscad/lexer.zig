const std = @import("std");
const common_token = @import("../common/token.zig");

pub const Tag = enum {
    eof,
    ident,
    number,
    string,
    comment,

    keyword_module,
    keyword_function,
    keyword_include,
    keyword_use,
    keyword_for,
    keyword_intersection_for,
    keyword_let,

    mod_disable,
    mod_root,
    mod_debug,
    mod_transparent,

    plus,
    minus,
    slash,
    equal,
    equal_equal,
    comma,
    semicolon,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
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
            return .{ .tag = .eof, .loc = .{ .line = self.line, .col = self.col, .file_id = self.file_id }, .lexeme = "" };
        }

        const start_loc = common_token.Location{ .line = self.line, .col = self.col, .file_id = self.file_id };
        const c = self.peek();

        return switch (c) {
            '+' => self.consumeChar(.plus, start_loc),
            '-' => self.consumeChar(.minus, start_loc),
            '=' => self.consumeEqual(start_loc),
            '*' => self.consumeChar(.mod_disable, start_loc),
            '!' => self.consumeChar(.mod_root, start_loc),
            '#' => self.consumeChar(.mod_debug, start_loc),
            '%' => self.consumeChar(.mod_transparent, start_loc),
            '/' => self.consumeSlashOrComment(start_loc),
            ',' => self.consumeChar(.comma, start_loc),
            ';' => self.consumeChar(.semicolon, start_loc),
            '(' => self.consumeChar(.l_paren, start_loc),
            ')' => self.consumeChar(.r_paren, start_loc),
            '[' => self.consumeChar(.l_bracket, start_loc),
            ']' => self.consumeChar(.r_bracket, start_loc),
            '{' => self.consumeChar(.l_brace, start_loc),
            '}' => self.consumeChar(.r_brace, start_loc),
            '"' => self.consumeString(start_loc),
            else => {
                if (std.ascii.isAlphabetic(c) or c == '_') {
                    return self.consumeIdentOrKeyword(start_loc);
                } else if (std.ascii.isDigit(c)) {
                    return self.consumeNumber(start_loc);
                }
                self.advance();
                return .{ .tag = .eof, .loc = start_loc, .lexeme = "" };
            },
        };
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.index < self.buffer.len) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r') {
                self.advance();
            } else if (c == '\n') {
                self.advance();
                self.line += 1;
                self.col = 1;
            } else {
                break;
            }
        }
    }

    fn consumeSlashOrComment(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance();
        if (self.index < self.buffer.len and self.peek() == '/') {
            while (self.index < self.buffer.len and self.peek() != '\n') {
                self.advance();
            }
            return .{ .tag = .comment, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
        }
        return .{ .tag = .slash, .loc = start_loc, .lexeme = "/" };
    }

    fn consumeIdentOrKeyword(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        while (self.index < self.buffer.len) {
            const c = self.peek();
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$') {
                self.advance();
            } else {
                break;
            }
        }

        const lexeme = self.buffer[start..self.index];
        var tag = Tag.ident;

        if (std.mem.eql(u8, lexeme, "module")) tag = .keyword_module;
        if (std.mem.eql(u8, lexeme, "function")) tag = .keyword_function;
        if (std.mem.eql(u8, lexeme, "include")) tag = .keyword_include;
        if (std.mem.eql(u8, lexeme, "use")) tag = .keyword_use;
        if (std.mem.eql(u8, lexeme, "for")) tag = .keyword_for;
        if (std.mem.eql(u8, lexeme, "let")) tag = .keyword_let;

        return .{ .tag = tag, .loc = start_loc, .lexeme = lexeme };
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

    fn consumeEqual(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance();
        if (self.index < self.buffer.len and self.peek() == '=') {
            self.advance();
            return .{ .tag = .equal_equal, .loc = start_loc, .lexeme = "==" };
        }
        return .{ .tag = .equal, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
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
};
