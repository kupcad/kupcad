const std = @import("std");
const common_token = @import("../common/token.zig");

pub const Tag = enum {
    eof,
    newline,
    ident,
    constant,
    number,
    string,
    string_start,
    string_mid,
    string_end,
    symbol,
    param_doc,
    comment,
    keyword_do,
    keyword_end,
    keyword_if,
    keyword_import,
    keyword_from,
    keyword_class,
    keyword_def,
    keyword_true,
    keyword_false,
    keyword_nil,
    keyword_else,
    keyword_elsif,
    keyword_module,
    keyword_yield,
    keyword_return,
    keyword_unless,
    keyword_while,
    keyword_break,
    keyword_case,
    keyword_when,
    keyword_self,
    keyword_super,

    equal_equal,
    bang_equal,
    less_equal,
    greater_equal,
    less,
    greater,
    and_and,
    or_or,
    bang,
    star_star,
    star,
    slash,
    percent,
    pipe,
    question,
    plus,
    minus,
    ampersand,

    // Assignments & Rockets
    equal,
    plus_equal,
    minus_equal,
    star_equal,
    slash_equal,
    percent_equal,
    star_star_equal,
    and_and_equal,
    or_or_equal,
    arrow,
    minus_greater, // ->
    dot_dot,
    dot,
    colon_colon, // ::
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

const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "do", .keyword_do },
    .{ "end", .keyword_end },
    .{ "if", .keyword_if },
    .{ "import", .keyword_import },
    .{ "from", .keyword_from },
    .{ "class", .keyword_class },
    .{ "def", .keyword_def },
    .{ "true", .keyword_true },
    .{ "false", .keyword_false },
    .{ "nil", .keyword_nil },
    .{ "else", .keyword_else },
    .{ "elsif", .keyword_elsif },
    .{ "module", .keyword_module },
    .{ "yield", .keyword_yield },
    .{ "return", .keyword_return },
    .{ "unless", .keyword_unless },
    .{ "while", .keyword_while },
    .{ "break", .keyword_break },
    .{ "case", .keyword_case },
    .{ "when", .keyword_when },
    .{ "self", .keyword_self },
    .{ "super", .keyword_super },
});

inline fn isIdentStart(c: u8) bool {
    if (std.ascii.isAlphabetic(c)) return true;
    return switch (c) {
        '_', '@', '$' => true,
        else => false,
    };
}

inline fn isIdentChar(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return switch (c) {
        '_', '?', '!', '@', '$' => true,
        else => false,
    };
}

pub const Lexer = struct {
    buffer: []const u8,
    index: usize,
    line: u32,
    col: u32,
    file_id: u32,

    brace_depth: u32 = 0,
    interp_stack: [8]u32 = undefined,
    interp_depth: usize = 0,

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
        if (self.index >= self.buffer.len) return self.makeToken(.eof);

        const start_loc = self.getLoc();
        const c = self.peek();

        return switch (c) {
            '\n' => self.consumeNewline(start_loc),
            '.' => self.consumeDotOrRange(start_loc),
            ',' => self.consumeChar(.comma, start_loc),
            '(' => self.consumeChar(.l_paren, start_loc),
            ')' => self.consumeChar(.r_paren, start_loc),
            '[' => self.consumeChar(.l_bracket, start_loc),
            ']' => self.consumeChar(.r_bracket, start_loc),
            '{' => {
                self.brace_depth += 1;
                return self.consumeChar(.l_brace, start_loc);
            },
            '}' => {
                if (self.brace_depth > 0) {
                    self.brace_depth -= 1;
                    return self.consumeChar(.r_brace, start_loc);
                } else if (self.interp_depth > 0) {
                    self.interp_depth -= 1;
                    self.brace_depth = self.interp_stack[self.interp_depth];
                    self.advance();
                    return self.consumeStringBody(start_loc, false);
                } else {
                    return self.consumeChar(.r_brace, start_loc);
                }
            },
            ':' => self.consumeSymbolOrColon(start_loc),
            '"' => self.consumeString(start_loc),
            '#' => self.consumeCommentOrParam(start_loc),
            '=', '!', '<', '>', '&', '|', '*', '/', '%', '?', '+', '-' => self.consumeOperator(start_loc),
            else => {
                if (isIdentStart(c)) return self.consumeIdentOrKeyword(start_loc);
                if (std.ascii.isDigit(c)) return self.consumeNumber(start_loc);
                self.advance();
                return self.makeToken(.eof);
            },
        };
    }

    inline fn getLoc(self: *const Lexer) common_token.Location {
        return .{ .line = self.line, .col = self.col, .file_id = self.file_id };
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.index < self.buffer.len) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r') self.advance() else break;
        }
    }

    fn consumeDotOrRange(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance();
        if (self.index < self.buffer.len and self.peek() == '.') {
            self.advance();
            return .{ .tag = .dot_dot, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
        }
        return .{ .tag = .dot, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn consumeCommentOrParam(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        while (self.index < self.buffer.len and self.peek() != '\n') self.advance();
        const lexeme = self.buffer[start..self.index];

        var i: usize = 1;
        while (i < lexeme.len and (lexeme[i] == ' ' or lexeme[i] == '\t')) i += 1;

        if (i + 6 <= lexeme.len and std.ascii.eqlIgnoreCase(lexeme[i .. i + 6], "@param")) {
            return .{ .tag = .param_doc, .loc = start_loc, .lexeme = lexeme };
        }
        return .{ .tag = .comment, .loc = start_loc, .lexeme = lexeme };
    }

    fn consumeIdentOrKeyword(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        const is_constant = std.ascii.isUpper(self.peek());

        while (self.index < self.buffer.len) {
            if (isIdentChar(self.peek())) self.advance() else break;
        }

        const lexeme = self.buffer[start..self.index];
        var tag = if (is_constant) Tag.constant else Tag.ident;

        if (keywords.get(lexeme)) |kw_tag| tag = kw_tag;
        return .{ .tag = tag, .loc = start_loc, .lexeme = lexeme };
    }

    fn consumeOperator(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        const c1 = self.peek();
        self.advance();

        const c2 = if (self.index < self.buffer.len) self.peek() else 0;
        const c3 = if (self.index + 1 < self.buffer.len) self.buffer[self.index + 1] else 0;

        const tag: Tag = switch (c1) {
            '=' => if (c2 == '=') .equal_equal else if (c2 == '>') .arrow else .equal,
            '+' => if (c2 == '=') .plus_equal else .plus,
            '-' => if (c2 == '=') .minus_equal else if (c2 == '>') .minus_greater else .minus,
            '*' => if (c2 == '*' and c3 == '=') .star_star_equal else if (c2 == '*') .star_star else if (c2 == '=') .star_equal else .star,
            '/' => if (c2 == '=') .slash_equal else .slash,
            '%' => if (c2 == '=') .percent_equal else .percent,
            '|' => if (c2 == '|' and c3 == '=') .or_or_equal else if (c2 == '|') .or_or else .pipe,
            '&' => if (c2 == '&' and c3 == '=') .and_and_equal else if (c2 == '&') .and_and else .ampersand,
            '!' => if (c2 == '=') .bang_equal else .bang,
            '<' => if (c2 == '=') .less_equal else .less,
            '>' => if (c2 == '=') .greater_equal else .greater,
            '?' => .question,
            else => return self.makeToken(.eof),
        };

        if (tag == .star_star_equal or tag == .or_or_equal or tag == .and_and_equal) {
            self.advance();
            self.advance();
        } else if (tag == .equal_equal or tag == .bang_equal or tag == .less_equal or
            tag == .greater_equal or tag == .and_and or tag == .or_or or tag == .star_star or
            tag == .plus_equal or tag == .minus_equal or tag == .star_equal or tag == .slash_equal or
            tag == .percent_equal or tag == .arrow or tag == .minus_greater)
        {
            self.advance();
        }

        return .{ .tag = tag, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn consumeSymbolOrColon(self: *Lexer, start_loc: common_token.Location) Token {
        self.advance();
        if (self.index < self.buffer.len and self.peek() == ':') {
            self.advance();
            return .{ .tag = .colon_colon, .loc = start_loc, .lexeme = "::" };
        }
        if (self.index < self.buffer.len and std.ascii.isAlphabetic(self.peek())) {
            const start = self.index;
            while (self.index < self.buffer.len and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_')) {
                self.advance();
            }
            return .{ .tag = .symbol, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
        }
        return .{ .tag = .colon, .loc = start_loc, .lexeme = ":" };
    }

    fn consumeNumber(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        while (self.index < self.buffer.len) {
            const c = self.peek();
            if (std.ascii.isDigit(c)) {
                self.advance();
            } else if (c == '.') {
                if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '.') break;
                self.advance();
            } else {
                break;
            }
        }
        return .{ .tag = .number, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn consumeString(self: *Lexer, start_loc: common_token.Location) Token {
        self.advance();
        return self.consumeStringBody(start_loc, true);
    }

    fn consumeStringBody(self: *Lexer, start_loc: common_token.Location, is_start: bool) Token {
        const start = self.index;
        while (self.index < self.buffer.len) {
            const c = self.peek();
            if (c == '\\') {
                self.advance();
                if (self.index < self.buffer.len) self.advance();
                continue;
            }
            if (c == '#' and self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '{') {
                const lexeme = self.buffer[start..self.index];
                self.advance();
                self.advance();

                if (self.interp_depth < self.interp_stack.len) {
                    self.interp_stack[self.interp_depth] = self.brace_depth;
                    self.interp_depth += 1;
                    self.brace_depth = 0;
                }
                return .{ .tag = if (is_start) .string_start else .string_mid, .loc = start_loc, .lexeme = lexeme };
            }
            if (c == '"') {
                const lexeme = self.buffer[start..self.index];
                self.advance();
                return .{ .tag = if (is_start) .string else .string_end, .loc = start_loc, .lexeme = lexeme };
            }
            self.advance();
        }
        return self.makeToken(.eof);
    }

    fn consumeNewline(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance();
        self.line += 1;
        self.col = 1;
        return .{ .tag = .newline, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn consumeChar(self: *Lexer, tag: Tag, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance();
        return .{ .tag = tag, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    inline fn peek(self: *const Lexer) u8 {
        return self.buffer[self.index];
    }

    inline fn advance(self: *Lexer) void {
        self.index += 1;
        self.col += 1;
    }

    fn makeToken(self: *const Lexer, tag: Tag) Token {
        return .{ .tag = tag, .loc = self.getLoc(), .lexeme = "" };
    }
};
