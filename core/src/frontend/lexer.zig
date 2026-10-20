//! Splits KupCAD source into tokens: `Lexer.next` returns one `Token` at a time (tags in
//! `Tag`, reserved words in `keywords`), tracking string interpolation on a stack of
//! `InterpState`s, and `lexAll` collects the whole buffer into a token list for the parser.

const std = @import("std");
const common_token = @import("../core/token.zig");
const utils = @import("utils.zig");
const string_escape = @import("../core/string_escape.zig");

pub const Tag = enum {
    eof,
    /// A character that starts no token.
    invalid,
    /// A string, quoted symbol or %-literal the file ends inside; the token is the rest of it.
    unterminated_string,
    /// A heredoc whose terminator line never comes; the token is the terminator's name.
    unterminated_heredoc,
    /// A token on a heredoc opener's line that runs onto the next line, where the body is.
    runs_into_heredoc,
    /// `#{` nested deeper than the lexer tracks.
    interpolation_too_deep,
    newline,
    semicolon,
    ident,
    constant,
    number,
    string,
    /// A single-quoted string or `%q(...)`: only `\\` and its delimiter are escapes, as in Ruby.
    raw_string,
    /// A heredoc's opener, `<<~NAME`, `<<-NAME` or `<<NAME`; its body is in `TokenList.heredocs`.
    heredoc,
    string_start,
    string_mid,
    string_end,
    symbol,
    docstring,
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
    keyword_for,
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
    keyword_as,
    keyword_with,
    keyword_private,
    keyword_public,
    equal_equal,
    bang_equal,
    less_equal,
    greater_equal,
    less_equal_greater,
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

    pub fn operatorLen(tag: Tag) usize {
        return switch (tag) {
            .star_star_equal, .or_or_equal, .and_and_equal, .greater_greater_equal => 3,
            .equal_equal, .bang_equal, .greater_equal, .and_and, .or_or, .star_star, .plus_equal, .minus_equal, .star_equal, .slash_equal, .percent_equal, .arrow, .minus_greater, .greater_greater, .ampersand_dot, .ampersand_equal, .pipe_equal, .caret_equal => 2,
            else => 1,
        };
    }
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
    .{ "for", .keyword_for },
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
    .{ "as", .keyword_as },
    .{ "with", .keyword_with },
    .{ "private", .keyword_private },
    .{ "public", .keyword_public },
});

inline fn isIdentStart(c: u8) bool {
    return utils.LexerUtils.isIdentStart(c, true);
}

inline fn isIdentChar(c: u8) bool {
    return utils.LexerUtils.isIdentChar(c);
}

/// Where the name of a bare symbol starting at `start` ends (`name`, `_internal`, `θ_angle`,
/// `valid?`, `destroy!`, `x=`), or `start` when none starts there. A trailing `=` is part
/// of it unless `>` follows, which makes it `=>`.
fn bareSymbolEnd(buffer: []const u8, start: usize) usize {
    if (start >= buffer.len or !isIdentStart(buffer[start])) return start;
    var end = start;
    while (end < buffer.len and isIdentChar(buffer[end])) end += 1;
    if (end < buffer.len and buffer[end] == '=' and (end + 1 == buffer.len or buffer[end + 1] != '>')) end += 1;
    return end;
}

/// Whether `name` reads back from `:name`; any other symbol (`%i[a-b]`) is written quoted
/// or in `%i[]`.
pub fn isBareSymbol(name: []const u8) bool {
    return name.len > 0 and bareSymbolEnd(name, 0) == name.len;
}

/// Whether `name` lexes as one identifier or constant, as the name of a map key or named
/// argument written `name:` must; a keyword (`if`) or any other name isn't one.
pub fn isLabelName(name: []const u8) bool {
    var lexer = Lexer.init(name, 0);
    const tok = lexer.next();
    return (tok.tag == .ident or tok.tag == .constant) and tok.lexeme.len == name.len;
}

pub const InterpState = struct {
    brace_depth: u32,
    open_delim: u8,
    close_delim: u8,
    string_nesting: u32,
};

pub const Lexer = struct {
    buffer: []const u8,
    index: usize,
    file_id: u32,
    brace_depth: u32 = 0,
    interp_stack: [64]InterpState,
    interp_depth: usize = 0,
    /// The last token was `.`, `&.` or `def`: a word now names a method, so `x.class`,
    /// `r.end` and `def end` lex an identifier, not a keyword (as in Ruby).
    expect_method_name: bool = false,
    /// Where the body of the `.heredoc` token `next` returned last starts, and its length.
    heredoc_body_start: usize = 0,
    heredoc_body_len: usize = 0,
    /// Set on a line with heredoc openers: where the line after their bodies starts, which
    /// is where the next opener's body starts and where lexing goes on after the line.
    heredoc_resume: ?usize = null,

    pub fn init(buffer: []const u8, file_id: u32) Lexer {
        return .{
            .buffer = buffer,
            .index = 0,
            .file_id = file_id,
            // SAFETY: The stack is guarded by interp_depth. Uninitialized elements are never read before being written
            .interp_stack = undefined,
        };
    }

    pub fn next(self: *Lexer) Token {
        var tok = self.scan();
        // A token is one slice of the source, so it can't skip a body: one that runs past
        // the opener's line (a string, a docstring) would read the body as its own text.
        if (self.heredoc_resume != null and tok.tag != .newline and std.mem.findScalar(u8, tok.lexeme, '\n') != null) {
            tok.tag = .runs_into_heredoc;
            self.skipHeredocBodies();
        }
        self.expect_method_name = switch (tok.tag) {
            .dot, .ampersand_dot, .keyword_def => true,
            else => false,
        };
        return tok;
    }

    fn scan(self: *Lexer) Token {
        self.skipWhitespace();
        if (self.index >= self.buffer.len) return self.makeToken(.eof);

        const start_loc = self.getLoc();
        const c = self.peek();

        return switch (c) {
            '\n' => self.consumeNewline(start_loc),
            ';' => self.consumeChar(.semicolon, start_loc),
            '.' => self.consumeDot(start_loc),
            ',' => self.consumeChar(.comma, start_loc),
            '(' => self.consumeChar(.l_paren, start_loc),
            ')' => self.consumeChar(.r_paren, start_loc),
            '[' => self.consumeChar(.l_bracket, start_loc),
            ']' => self.consumeChar(.r_bracket, start_loc),
            '{' => self.consumeOpenCurlyBrace(start_loc),
            '}' => self.consumeClosedCurlyBrace(start_loc),
            ':' => self.consumeSymbolOrColon(start_loc),
            '\'' => self.consumeString(start_loc, '\''),
            '"' => self.consumeString(start_loc, '"'),
            '#' => self.consumeCommentOrParam(start_loc),
            '=', '!', '<', '>', '&', '|', '*', '/', '?', '+', '-', '^', '~' => self.consumeOperator(start_loc),
            '%' => self.consumePercentOrModulo(start_loc),
            '$' => self.consumeGlobal(start_loc),
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
        return .{ .offset = @intCast(self.index), .length = 0, .file_id = self.file_id };
    }

    fn skipWhitespace(self: *Lexer) void {
        utils.LexerUtils.skipWhitespace(self.buffer, &self.index);
    }

    /// Where the line after the one holding `pos` starts, or the end of the buffer.
    fn lineAfter(self: *const Lexer, pos: usize) usize {
        const nl = std.mem.findScalarPos(u8, self.buffer, pos, '\n') orelse return self.buffer.len;
        return nl + 1;
    }

    inline fn consumePercentInterpolated(self: *Lexer) Token {
        if (self.index >= self.buffer.len) return self.makeToken(.eof);

        const open_delim = self.peek();
        self.advance();
        const close_delim = string_escape.closingDelimiter(open_delim);
        const content_loc = self.getLoc();
        return self.consumeStringBody(content_loc, true, open_delim, close_delim, 1);
    }

    fn consumeDot(self: *Lexer, start_loc: common_token.Location) Token {
        if (self.index + 1 < self.buffer.len and std.ascii.isDigit(self.buffer[self.index + 1])) {
            return self.consumeNumber(start_loc);
        }
        return self.consumeDotOrRange(start_loc);
    }

    fn consumeOpenCurlyBrace(self: *Lexer, start_loc: common_token.Location) Token {
        self.brace_depth += 1;
        return self.consumeChar(.l_brace, start_loc);
    }

    fn consumeClosedCurlyBrace(self: *Lexer, start_loc: common_token.Location) Token {
        if (self.brace_depth > 0) {
            self.brace_depth -= 1;
            return self.consumeChar(.r_brace, start_loc);
        } else if (self.interp_depth > 0) {
            self.interp_depth -= 1;

            const state = self.interp_stack[self.interp_depth];
            self.brace_depth = state.brace_depth;
            self.advance(); // consume '}'

            const content_loc = self.getLoc();
            return self.consumeStringBody(content_loc, false, state.open_delim, state.close_delim, state.string_nesting);
        } else {
            return self.consumeChar(.r_brace, start_loc);
        }
    }

    fn consumePercentOrModulo(self: *Lexer, start_loc: common_token.Location) Token {
        const c2 = if (self.index + 1 < self.buffer.len) self.buffer[self.index + 1] else 0;
        const c3 = if (self.index + 2 < self.buffer.len) self.buffer[self.index + 2] else 0;

        // Explicit percent literals (%w, %W, %i, %I, %q, %Q) are ALWAYS literals
        if (c3 != 0 and !std.ascii.isAlphanumeric(c3) and !std.ascii.isWhitespace(c3)) {
            if (c2 == 'w' or c2 == 'W' or c2 == 'i' or c2 == 'I' or c2 == 'q') {
                return self.consumePercentLiteral(start_loc, true);
            }

            if (c2 == 'Q') {
                self.advance(); // %
                self.advance(); // Q
                return self.consumePercentInterpolated();
            }
        }

        // A bare % is ALWAYS a modulo operator.
        return self.consumeOperator(start_loc);
    }

    fn consumePercentLiteral(self: *Lexer, start_loc: common_token.Location, has_letter: bool) Token {
        const full_start = self.index;
        self.advance(); // %

        var kind: u8 = 0;
        if (has_letter) {
            kind = self.peek(); // w, W, i, I, or q
            self.advance();
        }

        const open_delim = self.peek();
        self.advance();

        const inner_start = self.index;
        const close_delim = string_escape.closingDelimiter(open_delim);

        const is_paired = (open_delim != close_delim);
        var nesting_depth: u32 = 1;

        while (self.index < self.buffer.len) {
            const c = self.peek();

            if (c == '\\') {
                self.advance();
                if (self.index < self.buffer.len) self.advance();
                continue;
            }

            if (is_paired) {
                if (c == open_delim) nesting_depth += 1;
                if (c == close_delim) nesting_depth -= 1;
                if (nesting_depth == 0) break;
            } else {
                if (c == close_delim) break;
            }

            self.advance();
        }

        if (self.index == self.buffer.len) return .{ .tag = .unterminated_string, .loc = start_loc, .lexeme = self.buffer[full_start..] };
        const inner_end = self.index;
        self.advance(); // consume close delim

        const tag: Tag = if (!has_letter or kind == 'q') .raw_string else if (kind == 'w' or kind == 'W') .percent_w else .percent_i;

        if (!has_letter or kind == 'q') {
            // For raw strings (%q), the parser expects exactly the inner content.
            var content_loc = start_loc;
            content_loc.offset = @intCast(inner_start);
            return .{ .tag = tag, .loc = content_loc, .lexeme = self.buffer[inner_start..inner_end] };
        } else {
            // %w and %i arrays are handled by the parser directly using the full lexeme string
            return .{ .tag = tag, .loc = start_loc, .lexeme = self.buffer[full_start..self.index] };
        }
    }

    fn consumeDotOrRange(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance(); // .

        if (self.index < self.buffer.len and self.peek() == '.') {
            self.advance(); // .

            if (self.index < self.buffer.len and self.peek() == '.') {
                self.advance(); // .
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

        // Identify the end of the first line, stripping \r for tag parsing
        var first_line_end = self.index;
        if (first_line_end > start and self.buffer[first_line_end - 1] == '\r') first_line_end -= 1;

        const first_line = self.buffer[start..first_line_end];
        var i: usize = 1; // Start after '#'
        while (i < first_line.len and (first_line[i] == ' ' or first_line[i] == '\t')) i += 1;

        var tag: Tag = .comment;

        // Check if this is a YARD/Lookbook docstring annotation (@tag)
        if (i < first_line.len and first_line[i] == '@') {
            tag = .docstring;
            const base_indent = i - 1; // Number of spaces between '#' and '@'
            while (self.index < self.buffer.len) {
                if (self.index >= self.buffer.len or self.peek() != '\n') break;

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
                        while (self.index < self.buffer.len and self.peek() != '\n') self.advance();
                        continue;
                    }
                }
                break;
            }
        }

        // Trim trailing \r from the final docstring or comment lexeme
        var end_idx = self.index;
        if (end_idx > start and self.buffer[end_idx - 1] == '\r') end_idx -= 1;
        return .{ .tag = tag, .loc = start_loc, .lexeme = self.buffer[start..end_idx] };
    }

    fn consumeOperator(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        const c1 = self.peek();
        self.advance(); // operator

        const c2 = if (self.index < self.buffer.len) self.peek() else 0;
        const c3 = if (self.index + 1 < self.buffer.len) self.buffer[self.index + 1] else 0;

        // Route all Less-Than / Heredoc logic to a dedicated sub-method
        if (c1 == '<') {
            return self.consumeLessOperator(start_loc, start, c2, c3);
        }

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
            '>' => if (c2 == '=') .greater_equal else if (c2 == '>' and c3 == '=') .greater_greater_equal else if (c2 == '>') .greater_greater else .greater,
            '?' => .question,
            '^' => if (c2 == '=') .caret_equal else .caret,
            '~' => .tilde,
            else => return self.makeToken(.eof),
        };

        // Ensure proper multi-char operator advances for *= and other augmented assignments
        self.index = start + tag.operatorLen();

        return .{ .tag = tag, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn consumeLessOperator(self: *Lexer, start_loc: common_token.Location, start: usize, c2: u8, c3: u8) Token {
        if (c2 == '=' and c3 == '>') {
            self.advance();
            self.advance();
            return .{ .tag = .less_equal_greater, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
        } else if (c2 == '=') {
            self.advance();
            return .{ .tag = .less_equal, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
        } else if (c2 == '<' and c3 == '=') {
            self.advance();
            self.advance();
            return .{ .tag = .less_less_equal, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
        } else if (c2 == '<') {
            return self.consumeHeredocOrShift(start_loc, start, c3);
        }

        return .{ .tag = .less, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    fn consumeHeredocOrShift(self: *Lexer, start_loc: common_token.Location, start: usize, c3: u8) Token {
        const is_tilde = (c3 == '~');
        const is_dash = (c3 == '-');

        var term_start = self.index + 1;
        if (is_tilde or is_dash) term_start += 1;

        if (term_start < self.buffer.len and isIdentStart(self.buffer[term_start])) {
            var term_end = term_start;
            while (term_end < self.buffer.len and isIdentChar(self.buffer[term_end])) {
                term_end += 1;
            }

            const terminator = self.buffer[term_start..term_end];
            // The body is read now and skipped when the opener's line ends, so the rest of
            // the line (`f(<<~EOS)`, `<<~EOS.strip`) is lexed as code first, as in Ruby.
            const body_start = self.heredoc_resume orelse self.lineAfter(term_end);
            var line_start = body_start;
            while (line_start < self.buffer.len) : (line_start = self.lineAfter(line_start)) {
                // The terminator alone on its line, indented or not
                var name_start = line_start;
                while (name_start < self.buffer.len and (self.buffer[name_start] == ' ' or self.buffer[name_start] == '\t')) name_start += 1;
                const name_end = name_start + terminator.len;
                if (name_end > self.buffer.len or !std.mem.eql(u8, self.buffer[name_start..name_end], terminator)) continue;
                if (name_end < self.buffer.len and self.buffer[name_end] != '\n' and self.buffer[name_end] != '\r') continue;

                self.heredoc_body_start = body_start;
                self.heredoc_body_len = line_start - body_start;
                self.heredoc_resume = self.lineAfter(name_end);
                self.index = term_end;
                return .{ .tag = .heredoc, .loc = start_loc, .lexeme = self.buffer[start..term_end] };
            }

            var terminator_loc = start_loc;
            terminator_loc.offset = @intCast(term_start);
            self.index = self.buffer.len;
            return .{ .tag = .unterminated_heredoc, .loc = terminator_loc, .lexeme = terminator };
        }

        // Fallback: It wasn't a valid Heredoc terminator, so it's just a Left Shift <<
        self.advance();
        return .{ .tag = .less_less, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    /// `$name`, a global. A `$` that starts no name is a character the language doesn't use
    /// (it was a variable named `$`).
    fn consumeGlobal(self: *Lexer, start_loc: common_token.Location) Token {
        const next_c: u8 = if (self.index + 1 < self.buffer.len) self.buffer[self.index + 1] else 0;
        if (next_c != '$' and utils.LexerUtils.isIdentStart(next_c, false)) return self.consumeIdentOrKeyword(start_loc);
        return self.consumeChar(.invalid, start_loc);
    }

    fn consumeIdentOrKeyword(self: *Lexer, start_loc: common_token.Location) Token {
        const is_constant = std.ascii.isUpper(self.peek());
        const lexeme = utils.LexerUtils.consumeIdentLexeme(self.buffer, &self.index);
        var tag = if (is_constant) Tag.constant else Tag.ident;
        if (keywords.get(lexeme)) |kw_tag| {
            // `self` stays a keyword after `def`, for `def self.name`.
            if (!self.expect_method_name or kw_tag == .keyword_self) tag = kw_tag;
        }
        return .{ .tag = tag, .loc = start_loc, .lexeme = lexeme };
    }

    fn consumeString(self: *Lexer, start_loc: common_token.Location, quote: u8) Token {
        if (quote == '\'') {
            const start = self.index;
            const lexeme = utils.LexerUtils.consumeQuotedString(self.buffer, &self.index, '\'') orelse
                return .{ .tag = .unterminated_string, .loc = start_loc, .lexeme = self.buffer[start..] };
            var content_loc = start_loc;
            content_loc.offset += 1;
            return .{ .tag = .raw_string, .loc = content_loc, .lexeme = lexeme };
        }
        self.advance();
        const content_loc = self.getLoc();
        return self.consumeStringBody(content_loc, true, quote, quote, 1);
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
            const content_offset = self.index + 1; // skip quote in AST offset
            const lexeme = utils.LexerUtils.consumeQuotedString(self.buffer, &self.index, quote) orelse
                return .{ .tag = .unterminated_string, .loc = start_loc, .lexeme = self.buffer[start_loc.offset..] };

            var content_loc = start_loc;
            content_loc.offset = @intCast(content_offset);
            return .{ .tag = .symbol, .loc = content_loc, .lexeme = lexeme };
        }

        // Standard Symbols (e.g. :name, :valid?, :x=)
        const start = self.index;
        const end = bareSymbolEnd(self.buffer, start);
        if (is_symbol and end > start) {
            self.index = end;
            var content_loc = start_loc;
            content_loc.offset = @intCast(start);
            return .{ .tag = .symbol, .loc = content_loc, .lexeme = self.buffer[start..end] };
        }

        return .{ .tag = .colon, .loc = start_loc, .lexeme = ":" };
    }

    fn consumeNumber(self: *Lexer, start_loc: common_token.Location) Token {
        const lexeme = utils.LexerUtils.consumeNumber(self.buffer, &self.index);
        return .{ .tag = .number, .loc = start_loc, .lexeme = lexeme };
    }

    fn consumeStringBody(self: *Lexer, start_loc: common_token.Location, is_start: bool, open_delim: u8, close_delim: u8, initial_nesting: u32) Token {
        const start = self.index;
        const is_paired = open_delim != close_delim;
        var nesting_depth = initial_nesting;

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

                if (self.interp_depth >= self.interp_stack.len) {
                    return .{ .tag = .interpolation_too_deep, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
                }
                self.interp_stack[self.interp_depth] = .{
                    .brace_depth = self.brace_depth,
                    .open_delim = open_delim,
                    .close_delim = close_delim,
                    .string_nesting = nesting_depth,
                };
                self.interp_depth += 1;
                self.brace_depth = 0;
                return .{ .tag = if (is_start) .string_start else .string_mid, .loc = start_loc, .lexeme = lexeme };
            }

            if (is_paired) {
                if (c == open_delim) nesting_depth += 1;
                if (c == close_delim) nesting_depth -= 1;
                if (nesting_depth == 0) {
                    const lexeme = self.buffer[start..self.index];
                    self.advance();
                    return .{ .tag = if (is_start) .string else .string_end, .loc = start_loc, .lexeme = lexeme };
                }
            } else {
                if (c == close_delim) {
                    const lexeme = self.buffer[start..self.index];
                    self.advance();
                    return .{ .tag = if (is_start) .string else .string_end, .loc = start_loc, .lexeme = lexeme };
                }
            }
            self.advance();
        }
        return .{ .tag = .unterminated_string, .loc = start_loc, .lexeme = self.buffer[start..] };
    }

    fn consumeNewline(self: *Lexer, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance();
        const lexeme = self.buffer[start..self.index];
        self.skipHeredocBodies(); // the end of a line with heredoc openers: their bodies come next
        return .{ .tag = .newline, .loc = start_loc, .lexeme = lexeme };
    }

    /// Past the bodies of the heredocs opened on the line just left, already read.
    fn skipHeredocBodies(self: *Lexer) void {
        const resume_at = self.heredoc_resume orelse return;
        self.index = @max(self.index, resume_at);
        self.heredoc_resume = null;
    }

    fn consumeChar(self: *Lexer, tag: Tag, start_loc: common_token.Location) Token {
        const start = self.index;
        self.advance();
        return .{ .tag = tag, .loc = start_loc, .lexeme = self.buffer[start..self.index] };
    }

    pub fn lexAll(self: *Lexer, allocator: std.mem.Allocator) !common_token.TokenList(Tag) {
        var tags = std.ArrayList(Tag).empty;
        errdefer tags.deinit(allocator);
        var starts = std.ArrayList(u32).empty;
        errdefer starts.deinit(allocator);
        var lengths = std.ArrayList(u32).empty;
        errdefer lengths.deinit(allocator);
        var heredocs = std.ArrayList(common_token.Heredoc).empty;
        errdefer heredocs.deinit(allocator);

        // Pre-allocation heuristic: ~1 token per 4 bytes of source code
        const estimated_tokens = self.buffer.len / 4;
        try tags.ensureTotalCapacity(allocator, estimated_tokens);
        try starts.ensureTotalCapacity(allocator, estimated_tokens);
        try lengths.ensureTotalCapacity(allocator, estimated_tokens);

        while (true) {
            const tok = self.next();
            if (tok.tag == .heredoc) try heredocs.append(allocator, .{
                .token = @intCast(tags.items.len),
                .body_start = @intCast(self.heredoc_body_start),
                .body_len = @intCast(self.heredoc_body_len),
            });
            try tags.append(allocator, tok.tag);
            try starts.append(allocator, tok.loc.offset);
            try lengths.append(allocator, @intCast(tok.lexeme.len));
            if (tok.tag == .eof) break;
        }

        // Each owned slice leaves its list, so the list's errdefer no longer covers it.
        const tag_slice = try tags.toOwnedSlice(allocator);
        errdefer allocator.free(tag_slice);
        const start_slice = try starts.toOwnedSlice(allocator);
        errdefer allocator.free(start_slice);
        const length_slice = try lengths.toOwnedSlice(allocator);
        errdefer allocator.free(length_slice);
        return .{
            .tags = tag_slice,
            .starts = start_slice,
            .lengths = length_slice,
            .heredocs = try heredocs.toOwnedSlice(allocator),
        };
    }

    inline fn peek(self: *const Lexer) u8 {
        return self.buffer[self.index];
    }

    inline fn advance(self: *Lexer) void {
        self.index += 1;
    }

    fn makeToken(self: *const Lexer, tag: Tag) Token {
        return .{ .tag = tag, .loc = self.getLoc(), .lexeme = "" };
    }
};
