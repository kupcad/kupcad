const std = @import("std");
const common_token = @import("../../core/token.zig");
const utils = @import("../utils.zig");

pub const Tag = enum {
    eof,
    invalid,
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
    keyword_then,
    keyword_return,
    keyword_unless,
    keyword_while,
    keyword_until,
    keyword_break,
    keyword_next,
    keyword_case,
    keyword_when,
    keyword_self,
    keyword_super,
    keyword_and,
    keyword_or,
    keyword_not,
    keyword_begin,
    keyword_rescue,
    keyword_ensure,
    keyword_export,
    keyword_with,
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
    caret, // ^
    tilde, // ~
    percent_w,
    percent_i,
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
    ampersand_equal, // &=
    pipe_equal, // |=
    caret_equal, // ^=
    less_less_equal, // <<=
    greater_greater_equal, // >>=
    arrow,
    minus_greater, // ->
    less_less, // <<
    greater_greater, // >>
    dot_dot,
    dot_dot_dot,
    dot,
    ampersand_dot, // &.
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

pub const keywords = std.StaticStringMap(Tag).initComptime(.{
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
    .{ "then", .keyword_then },
    .{ "unless", .keyword_unless },
    .{ "while", .keyword_while },
    .{ "until", .keyword_until },
    .{ "break", .keyword_break },
    .{ "next", .keyword_next },
    .{ "case", .keyword_case },
    .{ "when", .keyword_when },
    .{ "self", .keyword_self },
    .{ "super", .keyword_super },
    .{ "and", .keyword_and },
    .{ "or", .keyword_or },
    .{ "not", .keyword_not },
    .{ "begin", .keyword_begin },
    .{ "rescue", .keyword_rescue },
    .{ "ensure", .keyword_ensure },
    .{ "export", .keyword_export },
    .{ "with", .keyword_with },
});

inline fn isIdentStart(c: u8) bool {
    return utils.LexerUtils.isIdentStart(c, true);
}

inline fn isIdentChar(c: u8) bool {
    return utils.LexerUtils.isIdentChar(c, false);
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
            '.' => {
                if (self.index + 1 < self.buffer.len and std.ascii.isDigit(self.buffer[self.index + 1])) {
                    return self.consumeNumber(start_loc);
                }
                return self.consumeDotOrRange(start_loc);
            },
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
                    self.advance(); // consume '}'
                    const content_loc = self.getLoc();
                    return self.consumeStringBody(content_loc, false, '"');
                } else {
                    return self.consumeChar(.r_brace, start_loc);
                }
            },
            ':' => self.consumeSymbolOrColon(start_loc),
            '\'' => self.consumeString(start_loc, '\''),
            '"' => self.consumeString(start_loc, '"'),
            '#' => self.consumeCommentOrParam(start_loc),
            '=', '!', '<', '>', '&', '|', '*', '/', '?', '+', '-', '^', '~' => self.consumeOperator(start_loc),
            '%' => self.consumePercentOrModulo(start_loc),
            else => {
                if (isIdentStart(c)) return self.consumeIdentOrKeyword(start_loc);
                if (std.ascii.isDigit(c)) return self.consumeNumber(start_loc);

                // Return an invalid token for unknown characters to trigger parser diagnostics
                const invalid_lexeme = self.buffer[self.index .. self.index + 1];
                self.advance();
                return .{ .tag = .invalid, .loc = start_loc, .lexeme = invalid_lexeme };
            },
        };
    }

    inline fn getLoc(self: *const Lexer) common_token.Location {
        return .{ .line = self.line, .col = self.col, .offset = @intCast(self.index), .length = 0, .file_id = self.file_id };
    }

    fn skipWhitespace(self: *Lexer) void {
        utils.LexerUtils.skipWhitespace(self.buffer, &self.index, &self.line, &self.col, false);
    }

    fn consumePercentOrModulo(self: *Lexer, start_loc: common_token.Location) Token {
        const c2 = if (self.index + 1 < self.buffer.len) self.buffer[self.index + 1] else 0;
        const c3 = if (self.index + 2 < self.buffer.len) self.buffer[self.index + 2] else 0;
        if ((c2 == 'w' or c2 == 'i') and (c3 == '[' or c3 == '{' or c3 == '(' or c3 == '<')) {
            return self.consumePercentLiteral(start_loc);
        }
        return self.consumeOperator(start_loc);
    }

    fn consumePercentLiteral(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance(); // %
        const kind = self.peek(); // w or i
        self.advance();
        const open_delim = self.peek();
        self.advance();

        const close_delim: u8 = switch (open_delim) {
            '[' => ']',
            '{' => '}',
            '(' => ')',
            '<' => '>',
            else => open_delim,
        };

        while (self.index < self.buffer.len and self.peek() != close_delim) {
            if (self.peek() == '\n') {
                self.line += 1;
                self.col = 1;
            }
            self.advance();
        }
        if (self.index < self.buffer.len) self.advance(); // consume close delim

        const tag: Tag = if (kind == 'w') .percent_w else .percent_i;
        return .{ .tag = tag, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn consumeDotOrRange(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance();
        if (self.index < self.buffer.len and self.peek() == '.') {
            self.advance();
            if (self.index < self.buffer.len and self.peek() == '.') {
                self.advance();
                return .{ .tag = .dot_dot_dot, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
            }
            return .{ .tag = .dot_dot, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
        }
        return .{ .tag = .dot, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn consumeCommentOrParam(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        // Consume the initial comment line
        while (self.index < self.buffer.len and self.peek() != '\n') self.advance();

        const first_line = self.buffer[start..self.index];
        var i: usize = 1; // Start after '#'
        while (i < first_line.len and (first_line[i] == ' ' or first_line[i] == '\t')) i += 1;

        // Check if this is a YARD/Lookbook docstring annotation (@tag)
        if (i < first_line.len and first_line[i] == '@') {
            const base_indent = i - 1; // Number of spaces between '#' and '@'
            while (self.index < self.buffer.len and self.peek() == '\n') {
                var lookahead = self.index + 1;
                // Skip horizontal whitespace leading up to '#'
                while (lookahead < self.buffer.len and (self.buffer[lookahead] == ' ' or self.buffer[lookahead] == '\t')) : (lookahead += 1) {}
                if (lookahead < self.buffer.len and self.buffer[lookahead] == '#') {
                    lookahead += 1; // Skip '#'
                    var spaces_after_hash: usize = 0;
                    while (lookahead < self.buffer.len and (self.buffer[lookahead] == ' ' or self.buffer[lookahead] == '\t')) : (lookahead += 1) {
                        spaces_after_hash += 1;
                    }

                    // Continuation rule:
                    // Must have strictly MORE spaces after '#' than the tag line AND must NOT start a new '@' tag
                    if (spaces_after_hash > base_indent and lookahead < self.buffer.len and self.buffer[lookahead] != '@') {
                        self.advance(); // consume '\n'
                        self.line += 1;
                        self.col = 1;
                        while (self.index < self.buffer.len and self.peek() != '\n') self.advance();
                        continue;
                    }
                }
                break;
            }
            return .{ .tag = .param_doc, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
        }
        return .{ .tag = .comment, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
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
            '|' => if (c2 == '|' and c3 == '=') .or_or_equal else if (c2 == '|') .or_or else if (c2 == '=') .pipe_equal else .pipe,
            '&' => if (c2 == '&' and c3 == '=') .and_and_equal else if (c2 == '&') .and_and else if (c2 == '.') .ampersand_dot else if (c2 == '=') .ampersand_equal else .ampersand,
            '!' => if (c2 == '=') .bang_equal else .bang,
            '<' => if (c2 == '=') .less_equal else if (c2 == '<' and c3 == '=') .less_less_equal else if (c2 == '<') .less_less else .less,
            '>' => if (c2 == '=') .greater_equal else if (c2 == '>' and c3 == '=') .greater_greater_equal else if (c2 == '>') .greater_greater else .greater,
            '?' => .question,
            '^' => if (c2 == '=') .caret_equal else .caret,
            '~' => .tilde,
            else => return self.makeToken(.eof),
        };

        // Ensure proper multi-char operator advances for *= and other augmented assignments
        if (tag == .star_star_equal or tag == .or_or_equal or tag == .and_and_equal or tag == .less_less_equal or tag == .greater_greater_equal) {
            self.advance();
            self.advance();
        } else if (tag == .equal_equal or tag == .bang_equal or tag == .less_equal or
            tag == .greater_equal or tag == .and_and or tag == .or_or or tag == .star_star or
            tag == .plus_equal or tag == .minus_equal or tag == .star_equal or tag == .slash_equal or
            tag == .percent_equal or tag == .arrow or tag == .minus_greater or tag == .less_less or tag == .greater_greater or tag == .ampersand_dot or tag == .ampersand_equal or tag == .pipe_equal or tag == .caret_equal)
        {
            self.advance();
        }
        return .{ .tag = tag, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn consumeIdentOrKeyword(self: *Lexer, start_loc: common_token.Location) Token {
        const is_constant = std.ascii.isUpper(self.peek());
        const lexeme = utils.LexerUtils.consumeIdentLexeme(self.buffer, &self.index, &self.col, false);
        var tag = if (is_constant) Tag.constant else Tag.ident;
        if (keywords.get(lexeme)) |kw_tag| tag = kw_tag;
        return .{ .tag = tag, .loc = start_loc, .lexeme = lexeme };
    }

    fn consumeString(self: *Lexer, start_loc: common_token.Location, quote: u8) Token {
        if (quote == '\'') {
            const lexeme = utils.LexerUtils.consumeQuotedString(self.buffer, &self.index, &self.line, &self.col, '\'');
            var content_loc = start_loc;
            content_loc.offset += 1;
            content_loc.col += 1;
            return .{ .tag = .string, .loc = content_loc, .lexeme = lexeme };
        }
        self.advance();
        const content_loc = self.getLoc();
        return self.consumeStringBody(content_loc, true, quote);
    }

    fn consumeSymbolOrColon(self: *Lexer, start_loc: common_token.Location) Token {
        self.advance(); // consume ':'
        if (self.index < self.buffer.len and self.peek() == ':') {
            self.advance();
            return .{ .tag = .colon_colon, .loc = start_loc, .lexeme = "::" };
        }
        var is_symbol = true;
        if (self.index >= 2) {
            const prev = self.buffer[self.index - 2];
            if (isIdentChar(prev) or prev == '"' or prev == '\'' or prev == ']' or prev == ')' or prev == '}') {
                is_symbol = false;
            }
        }

        // Quoted Symbols (e.g. :"key name")
        if (is_symbol and self.index < self.buffer.len and (self.peek() == '"' or self.peek() == '\'')) {
            const quote = self.peek();
            self.advance();
            const start = self.index;
            while (self.index < self.buffer.len and self.peek() != quote) {
                self.advance();
            }
            const lexeme = self.buffer[start..self.index];
            if (self.index < self.buffer.len) self.advance();

            // Shift the start offset forward so the AST maps to the inner content
            var content_loc = start_loc;
            content_loc.offset = @intCast(start);
            return .{ .tag = .symbol, .loc = content_loc, .lexeme = lexeme };
        }

        // Standard Symbols (e.g. :name)
        if (is_symbol and self.index < self.buffer.len and std.ascii.isAlphabetic(self.peek())) {
            const start = self.index;
            while (self.index < self.buffer.len and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_')) {
                self.advance();
            }

            // Shift the start offset forward so the AST maps to the inner content
            // instead of including the ':' in the offset (which causes strings like ":scre" on length bounds).
            var content_loc = start_loc;
            content_loc.offset = @intCast(start);
            return .{ .tag = .symbol, .loc = content_loc, .lexeme = self.buffer[start..self.index] };
        }
        return .{ .tag = .colon, .loc = start_loc, .lexeme = ":" };
    }

    fn consumeNumber(self: *Lexer, start_loc: common_token.Location) Token {
        const lexeme = utils.LexerUtils.consumeNumber(self.buffer, &self.index, &self.col);
        return .{ .tag = .number, .loc = start_loc, .lexeme = lexeme };
    }

    fn consumeStringBody(self: *Lexer, start_loc: common_token.Location, is_start: bool, quote: u8) Token {
        const start = self.index;
        while (self.index < self.buffer.len) {
            const c = self.peek();
            if (c == '\n') {
                self.line += 1;
                self.col = 0;
            }
            if (c == '\\') {
                self.advance();
                if (self.index < self.buffer.len) self.advance();
                continue;
            }
            if (quote == '"' and c == '#' and self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '{') {
                const lexeme = self.buffer[start..self.index];
                self.advance();
                self.advance();

                if (self.interp_depth >= self.interp_stack.len) {
                    return .{ .tag = .invalid, .loc = start_loc, .lexeme = "Interpolation depth exceeded" };
                }
                self.interp_stack[self.interp_depth] = self.brace_depth;
                self.interp_depth += 1;
                self.brace_depth = 0;
                return .{ .tag = if (is_start) .string_start else .string_mid, .loc = start_loc, .lexeme = lexeme };
            }
            if (c == quote) {
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

    pub fn lexAll(self: *Lexer, allocator: std.mem.Allocator) !common_token.TokenList(Tag) {
        var tags = std.ArrayListUnmanaged(Tag).empty;
        var starts = std.ArrayListUnmanaged(u32).empty;
        var lengths = std.ArrayListUnmanaged(u32).empty;

        // Pre-allocation heuristic: ~1 token per 4 bytes of source code
        const estimated_tokens = self.buffer.len / 4;
        try tags.ensureTotalCapacity(allocator, estimated_tokens);
        try starts.ensureTotalCapacity(allocator, estimated_tokens);
        try lengths.ensureTotalCapacity(allocator, estimated_tokens);

        errdefer tags.deinit(allocator);
        errdefer starts.deinit(allocator);
        errdefer lengths.deinit(allocator);

        while (true) {
            const tok = self.next();
            try tags.append(allocator, tok.tag);
            try starts.append(allocator, tok.loc.offset);
            try lengths.append(allocator, @intCast(tok.lexeme.len));
            if (tok.tag == .eof) break;
        }

        return .{
            .tags = try tags.toOwnedSlice(allocator),
            .starts = try starts.toOwnedSlice(allocator),
            .lengths = try lengths.toOwnedSlice(allocator),
        };
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
