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
    keyword_if,
    keyword_else,
    keyword_true,
    keyword_false,
    keyword_undef,

    bang_equal,
    less_equal,
    greater_equal,
    less,
    greater,
    and_and,
    or_or,
    bang,
    block_comment,

    mod_root,
    mod_debug,

    star, // * (acts as multiply AND modifier)
    percent, // % (acts as modulo AND modifier)
    question, // ? (ternary)
    colon, // : (ternary)
    caret, // ^ (exponentiation)
    plus,
    minus,
    slash,
    equal,
    equal_equal,
    comma,
    dot,
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
            '#' => self.consumeChar(.mod_debug, start_loc),
            '/' => self.consumeSlashOrComment(start_loc),
            ',' => self.consumeChar(.comma, start_loc),
            '.' => self.consumeChar(.dot, start_loc),
            ';' => self.consumeChar(.semicolon, start_loc),
            '(' => self.consumeChar(.l_paren, start_loc),
            ')' => self.consumeChar(.r_paren, start_loc),
            '[' => self.consumeChar(.l_bracket, start_loc),
            ']' => self.consumeChar(.r_bracket, start_loc),
            '{' => self.consumeChar(.l_brace, start_loc),
            '}' => self.consumeChar(.r_brace, start_loc),
            '"' => self.consumeString(start_loc),
            '^' => self.consumeChar(.caret, start_loc),
            ':' => self.consumeChar(.colon, start_loc),
            '=', '!', '<', '>', '&', '|', '*', '%', '?' => self.consumeOperator(start_loc),
            else => {
                if (std.ascii.isAlphabetic(c) or c == '_' or c == '$') {
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

    fn consumeOperator(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        const c1 = self.peek();
        self.advance();
        const c2 = if (self.index < self.buffer.len) self.peek() else 0;

        const tag: Tag = switch (c1) {
            '=' => if (c2 == '=') .equal_equal else .equal,
            '!' => if (c2 == '=') .bang_equal else .bang, // Parser will map .bang contextually to NOT or Root mod
            '<' => if (c2 == '=') .less_equal else .less,
            '>' => if (c2 == '=') .greater_equal else .greater,
            '&' => if (c2 == '&') .and_and else return .{ .tag = .eof, .loc = start_loc, .lexeme = "" },
            '|' => if (c2 == '|') .or_or else return .{ .tag = .eof, .loc = start_loc, .lexeme = "" },
            '*' => .star,
            '%' => .percent,
            '?' => .question,
            else => return .{ .tag = .eof, .loc = start_loc, .lexeme = "" },
        };

        if (tag == .equal_equal or tag == .bang_equal or tag == .less_equal or
            tag == .greater_equal or tag == .and_and or tag == .or_or)
        {
            self.advance(); // consume second character
        }

        return .{ .tag = tag, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn consumeSlashOrComment(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance();
        if (self.index < self.buffer.len) {
            if (self.peek() == '/') {
                // Line comment
                while (self.index < self.buffer.len and self.peek() != '\n') {
                    self.advance();
                }
                return .{ .tag = .comment, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
            } else if (self.peek() == '*') {
                // Block comment
                self.advance();
                while (self.index < self.buffer.len) {
                    if (self.peek() == '*' and self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '/') {
                        self.advance(); // consume *
                        self.advance(); // consume /
                        break;
                    }
                    if (self.peek() == '\n') {
                        self.line += 1;
                        self.col = 0; // Will become 1 on advance
                    }
                    self.advance();
                }
                return .{ .tag = .block_comment, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
            }
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
        if (std.mem.eql(u8, lexeme, "if")) tag = .keyword_if;
        if (std.mem.eql(u8, lexeme, "else")) tag = .keyword_else;
        if (std.mem.eql(u8, lexeme, "true")) tag = .keyword_true;
        if (std.mem.eql(u8, lexeme, "false")) tag = .keyword_false;
        if (std.mem.eql(u8, lexeme, "undef")) tag = .keyword_undef;

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
        while (self.index < self.buffer.len) {
            const c = self.peek();
            if (c == '\\') {
                // Skip the escape character and the escaped character
                self.advance();
                if (self.index < self.buffer.len) {
                    self.advance();
                }
                continue;
            }
            if (c == '"') {
                break; // End of string
            }
            self.advance();
        }
        const lexeme = self.buffer[start..self.index];
        if (self.index < self.buffer.len) self.advance(); // consume ending quote
        return .{ .tag = .string, .loc = start_loc, .lexeme = lexeme };
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
