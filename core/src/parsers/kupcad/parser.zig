const std = @import("std");
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const Tag = lexer_mod.Tag;
const Token = lexer_mod.Token;
const ast = @import("../common/ast.zig");
const Node = ast.Node;

pub const ParseError = error{ UnexpectedToken, InvalidExpression, OutOfMemory };

pub const Precedence = enum(u8) {
    none = 0,
    assignment = 1, // = += -= etc
    ternary = 2, // ? :
    logical_or = 3, // ||
    logical_and = 4, // &&
    equality = 5, // == !=
    comparison = 6, // < <= > >=
    bitwise_or = 7, // | ^
    bitwise_and = 8, // & (CSG Intersection)
    shift = 9, // << >>
    range = 10, // .. ...
    term = 11, // + -
    factor = 12, // * / %
    exponent = 13, // **
    unary = 14, // ! -
    call = 15, // . &. () [] ::
};

pub const Parser = struct {
    lexer: *Lexer,
    allocator: std.mem.Allocator,
    b: ast.Builder,
    current: Token,
    next_tok: Token,

    pub fn init(lexer: *Lexer, allocator: std.mem.Allocator) Parser {
        var parser = Parser{ .lexer = lexer, .allocator = allocator, .b = ast.Builder.init(allocator), .current = undefined, .next_tok = undefined };
        parser.next_tok = parser.lexer.next();
        parser.advance();
        return parser;
    }

    fn advance(self: *Parser) void {
        self.current = self.next_tok;
        self.next_tok = self.lexer.next();
    }

    fn expect(self: *Parser, tag: Tag) ParseError!Token {
        if (self.current.tag == tag) {
            const tok = self.current;
            self.advance();
            return tok;
        }
        return ParseError.UnexpectedToken;
    }

    fn skipIgnored(self: *Parser) void {
        while (self.current.tag == .newline or self.current.tag == .comment) self.advance();
    }

    fn isAssignmentOp(tag: Tag) bool {
        return switch (tag) {
            .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal, .percent_equal, .star_star_equal, .or_or_equal, .and_and_equal, .ampersand_equal, .pipe_equal, .caret_equal, .less_less_equal, .greater_greater_equal => true,
            else => false,
        };
    }

    fn tagToAssignmentOp(tag: Tag) ?ast.BinaryOp {
        return switch (tag) {
            .plus_equal => .add,
            .minus_equal => .subtract,
            .star_equal => .multiply,
            .slash_equal => .divide,
            .percent_equal => .modulo,
            .star_star_equal => .exponent,
            .or_or_equal => .logical_or,
            .and_and_equal => .logical_and,
            .ampersand_equal => .bitwise_and,
            .pipe_equal => .bitwise_or,
            .caret_equal => .bitwise_xor,
            .less_less_equal => .shift_left,
            .greater_greater_equal => .shift_right,
            else => null,
        };
    }

    pub fn parseProgram(self: *Parser) ParseError!*Node {
        return self.parseBlock(&.{});
    }

    pub fn parseStatement(self: *Parser) ParseError!*Node {
        self.skipIgnored();
        var stmt = switch (self.current.tag) {
            .keyword_import => try self.parseImportStatement(),
            .keyword_if => try self.parseIfStatement(),
            .keyword_unless => try self.parseUnlessStatement(),
            .keyword_case => try self.parseCaseStatement(),
            .keyword_while => try self.parseWhileStatement(),
            .keyword_def => try self.parseDefStatement(),
            .keyword_class => try self.parseClassStatement(),
            .keyword_module => try self.parseModuleStatement(),
            .keyword_return => try self.parseReturnStatement(),
            .keyword_yield => try self.parseYieldStatement(),
            .keyword_break => try self.parseBreakStatement(),
            .keyword_next => try self.parseNextStatement(),
            .keyword_begin => try self.parseBeginStatement(),
            .param_doc => try self.parseParamDoc(),
            else => try self.parseExprOrMultiAssign(),
        };

        if (self.current.tag == .keyword_if or self.current.tag == .keyword_unless or self.current.tag == .keyword_while or self.current.tag == .keyword_until) {
            const mod_tag = self.current.tag;
            const mod_loc = self.current.loc;
            self.advance();
            const cond = try self.parseExpression(.none);
            const then_block = try self.createNode(.{
                .block = .{ .stmts = try self.allocator.dupe(*Node, &.{stmt}) },
            }, stmt.loc);

            if (mod_tag == .keyword_if or mod_tag == .keyword_unless) {
                stmt = try self.createNode(.{
                    .if_stmt = .{ .condition = cond, .then_branch = then_block, .else_branch = null, .is_unless = (mod_tag == .keyword_unless) },
                }, mod_loc);
            } else {
                stmt = try self.createNode(.{
                    .while_stmt = .{ .condition = cond, .body = then_block, .is_until = (mod_tag == .keyword_until) },
                }, mod_loc);
            }
        }

        return stmt;
    }

    pub fn parseBlock(self: *Parser, end_tags: []const Tag) ParseError!*Node {
        const start_loc = self.current.loc;
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer stmts.deinit(self.allocator);

        while (self.current.tag != .eof) {
            var is_end = false;
            for (end_tags) |end_tag| {
                if (self.current.tag == end_tag) {
                    is_end = true;
                    break;
                }
            }
            if (is_end) break;
            if (self.current.tag == .newline or self.current.tag == .comment) {
                self.advance();
                continue;
            }
            try stmts.append(self.allocator, try self.parseStatement());
            if (self.current.tag == .newline) self.advance();
        }

        return self.createNode(.{ .block = .{ .stmts = try stmts.toOwnedSlice(self.allocator) } }, start_loc);
    }

    // 2. Add the `parseBeginStatement` helper method:
    fn parseBeginStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_begin);
        self.skipIgnored();
        const body = try self.parseBlock(&.{ .keyword_rescue, .keyword_ensure, .keyword_end });

        var rescue_body: ?*Node = null;
        if (self.current.tag == .keyword_rescue) {
            self.advance();
            if (self.current.tag == .arrow) { // Handle `rescue => e`
                self.advance();
                if (self.current.tag == .ident) self.advance();
            }
            self.skipIgnored();
            rescue_body = try self.parseBlock(&.{ .keyword_ensure, .keyword_end });
        }

        var ensure_body: ?*Node = null;
        if (self.current.tag == .keyword_ensure) {
            self.advance();
            self.skipIgnored();
            ensure_body = try self.parseBlock(&.{.keyword_end});
        }
        _ = try self.expect(.keyword_end);

        return self.createNode(.{ .begin_stmt = .{ .body = body, .rescue_body = rescue_body, .ensure_body = ensure_body } }, start_tok.loc);
    }

    fn parseImportStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_import);
        _ = try self.expect(.l_brace);
        var symbols: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer symbols.deinit(self.allocator);

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            self.skipIgnored();
            if (self.current.tag == .ident or self.current.tag == .constant) {
                try symbols.append(self.allocator, self.current.lexeme);
                self.advance();
            } else return ParseError.UnexpectedToken;
            if (self.current.tag == .comma) self.advance() else break;
        }

        _ = try self.expect(.r_brace);
        _ = try self.expect(.keyword_from);
        const path_tok = try self.expect(.string);

        return self.createNode(.{
            .import_stmt = .{ .symbols = try symbols.toOwnedSlice(self.allocator), .path = path_tok.lexeme },
        }, start_tok.loc);
    }

    fn parseIfStatement(self: *Parser) ParseError!*Node {
        const start_tok = self.current;
        if (self.current.tag == .keyword_if or self.current.tag == .keyword_elsif) self.advance() else return ParseError.UnexpectedToken;

        const condition = try self.parseExpression(.none);
        self.skipIgnored();

        const then_branch = try self.parseBlock(&.{ .keyword_elsif, .keyword_else, .keyword_end });
        var else_branch: ?*Node = null;

        if (self.current.tag == .keyword_elsif) {
            else_branch = try self.parseIfStatement();
        } else if (self.current.tag == .keyword_else) {
            self.advance();
            self.skipIgnored();
            else_branch = try self.parseBlock(&.{.keyword_end});
            _ = try self.expect(.keyword_end);
        } else if (self.current.tag == .keyword_end) self.advance();

        return self.createNode(.{ .if_stmt = .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch } }, start_tok.loc);
    }

    fn parseUnlessStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_unless);
        const condition = try self.parseExpression(.none);
        self.skipIgnored();

        const then_branch = try self.parseBlock(&.{ .keyword_else, .keyword_end });
        var else_branch: ?*Node = null;

        if (self.current.tag == .keyword_else) {
            self.advance();
            self.skipIgnored();
            else_branch = try self.parseBlock(&.{.keyword_end});
            _ = try self.expect(.keyword_end);
        } else if (self.current.tag == .keyword_end) self.advance();

        return self.createNode(.{ .if_stmt = .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch, .is_unless = true } }, start_tok.loc);
    }

    fn isMultipleAssignmentStatement(self: *Parser) bool {
        var temp_lexer = self.lexer.*;
        var temp_next = self.next_tok;
        var curr = self.current;
        var has_comma = false;

        while (curr.tag != .newline and curr.tag != .eof) {
            if (isAssignmentOp(curr.tag)) return has_comma;
            if (curr.tag == .comma) {
                has_comma = true;
            } else if (curr.tag != .ident and curr.tag != .constant and curr.tag != .star) {
                return false;
            }
            curr = temp_next;
            temp_next = temp_lexer.next();
        }
        return false;
    }

    fn parseExprOrMultiAssign(self: *Parser) ParseError!*Node {
        const is_multi = if ((self.current.tag == .ident or self.current.tag == .constant or self.current.tag == .star) and (self.next_tok.tag == .comma or self.next_tok.tag == .ident)) self.isMultipleAssignmentStatement() else false;

        if (is_multi) {
            const start_loc = self.current.loc;
            var lhs_list: std.ArrayListUnmanaged(ast.LhsExpr) = .empty;
            errdefer lhs_list.deinit(self.allocator);

            while (self.current.tag != .newline and self.current.tag != .eof) {
                var mod: ?ast.ArgModifier = null;
                if (self.current.tag == .star) {
                    mod = .splat;
                    self.advance();
                }
                if (self.current.tag == .ident or self.current.tag == .constant) {
                    try lhs_list.append(self.allocator, .{ .name = self.current.lexeme, .modifier = mod });
                    self.advance();
                } else return ParseError.UnexpectedToken;

                if (self.current.tag == .comma) {
                    self.advance(); // consume comma
                } else break;
            }

            if (isAssignmentOp(self.current.tag)) {
                const op_tag = self.current.tag;
                self.advance();
                const val_node = try self.parseExpression(.assignment);
                return self.createNode(.{
                    .multiple_assignment = .{
                        .lhs = try lhs_list.toOwnedSlice(self.allocator),
                        .op = tagToAssignmentOp(op_tag),
                        .value = val_node,
                    },
                }, start_loc);
            } else return ParseError.UnexpectedToken;
        }
        return try self.parseExpression(.none);
    }

    fn parseCaseStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_case);
        var condition: ?*Node = null;

        if (self.current.tag != .newline and self.current.tag != .keyword_when) {
            condition = try self.parseExpression(.none);
        }
        self.skipIgnored();

        var when_branches: std.ArrayListUnmanaged(ast.WhenBranch) = .empty;
        errdefer when_branches.deinit(self.allocator);

        while (self.current.tag == .keyword_when) {
            self.advance();
            var conditions: std.ArrayListUnmanaged(*Node) = .empty;
            errdefer conditions.deinit(self.allocator);

            while (self.current.tag != .newline and self.current.tag != .eof) {
                try conditions.append(self.allocator, try self.parseExpression(.none));
                if (self.current.tag == .comma) self.advance() else break;
            }
            self.skipIgnored();

            const body = try self.parseBlock(&.{ .keyword_when, .keyword_else, .keyword_end });
            try when_branches.append(self.allocator, .{
                .conditions = try conditions.toOwnedSlice(self.allocator),
                .body = body,
            });
        }

        var else_branch: ?*Node = null;
        if (self.current.tag == .keyword_else) {
            self.advance();
            self.skipIgnored();
            else_branch = try self.parseBlock(&.{.keyword_end});
        }

        _ = try self.expect(.keyword_end);

        return self.createNode(.{
            .case_stmt = .{
                .condition = condition,
                .when_branches = try when_branches.toOwnedSlice(self.allocator),
                .else_branch = else_branch,
            },
        }, start_tok.loc);
    }

    fn parseWhileStatement(self: *Parser) ParseError!*Node {
        const is_until = (self.current.tag == .keyword_until);
        const start_tok = self.current;
        self.advance(); // consume while or until
        const condition = try self.parseExpression(.none);
        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);
        return self.createNode(.{ .while_stmt = .{ .condition = condition, .body = body, .is_until = is_until } }, start_tok.loc);
    }

    fn parseNextStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_next);
        var val: ?*Node = null;
        if (self.current.tag != .newline and self.current.tag != .eof and self.current.tag != .keyword_end and self.current.tag != .keyword_unless and self.current.tag != .keyword_if and self.current.tag != .keyword_while and self.current.tag != .keyword_until) {
            val = try self.parseExpression(.none);
        }
        return self.createNode(.{ .next_stmt = val }, start_tok.loc);
    }

    fn parseDefStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_def);
        const name_tok = if (self.current.tag == .ident or self.current.tag == .constant) self.current else return ParseError.UnexpectedToken;
        self.advance();
        const params = try self.parseParenParams();
        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.createNode(.{ .def_stmt = .{ .name = name_tok.lexeme, .params = params, .body = body } }, start_tok.loc);
    }

    fn parseClassStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_class);
        const name_tok = if (self.current.tag == .constant or self.current.tag == .ident) self.current else return ParseError.UnexpectedToken;
        self.advance();

        var super_class: ?[]const u8 = null;
        if (self.current.tag == .less) {
            self.advance();
            if (self.current.tag == .constant or self.current.tag == .ident) {
                super_class = self.current.lexeme;
                self.advance();
            }
        }

        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.createNode(.{ .class_stmt = .{ .name = name_tok.lexeme, .super_class = super_class, .body = body } }, start_tok.loc);
    }

    fn parseModuleStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_module);
        const name_tok = if (self.current.tag == .constant or self.current.tag == .ident) self.current else return ParseError.UnexpectedToken;
        self.advance();
        self.skipIgnored();

        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.createNode(.{ .module_stmt = .{ .name = name_tok.lexeme, .body = body } }, start_tok.loc);
    }

    fn parseReturnStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_return);
        var val: ?*Node = null;
        if (self.current.tag != .newline and self.current.tag != .eof and self.current.tag != .keyword_end and self.current.tag != .keyword_unless and self.current.tag != .keyword_if) {
            val = try self.parseExpression(.none);
        }
        return self.createNode(.{ .return_stmt = val }, start_tok.loc);
    }

    fn parseYieldStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_yield);
        var args: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer args.deinit(self.allocator);

        if (self.current.tag == .l_paren) {
            self.advance();
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                try args.append(self.allocator, try self.parseExpression(.none));
                if (self.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
        } else {
            while (self.current.tag != .newline and self.current.tag != .eof and self.current.tag != .keyword_unless and self.current.tag != .keyword_if and self.current.tag != .keyword_end) {
                try args.append(self.allocator, try self.parseExpression(.none));
                if (self.current.tag == .comma) self.advance() else break;
            }
        }
        return self.createNode(.{ .yield_stmt = try args.toOwnedSlice(self.allocator) }, start_tok.loc);
    }

    fn parseBreakStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_break);
        var val: ?*Node = null;
        if (self.current.tag != .newline and self.current.tag != .eof and self.current.tag != .keyword_unless and self.current.tag != .keyword_if and self.current.tag != .keyword_end) {
            val = try self.parseExpression(.none);
        }
        return self.createNode(.{ .break_stmt = val }, start_tok.loc);
    }

    fn parseParamDoc(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.param_doc);
        return self.createNode(.{ .param_doc = tok.lexeme }, tok.loc);
    }

    // --- SHARED DRY ARGUMENT & PARAMETER LOGIC ---

    fn parseArgModifier(self: *Parser) ?ast.ArgModifier {
        switch (self.current.tag) {
            .star => {
                self.advance();
                return .splat;
            },
            .star_star => {
                self.advance();
                return .double_splat;
            },
            .ampersand => {
                self.advance();
                return .block;
            },
            else => return null,
        }
    }

    fn parseNamedArg(self: *Parser) ParseError!ast.NamedArg {
        const mod = self.parseArgModifier();
        var arg_name: []const u8 = "";
        if (self.current.tag == .ident and self.next_tok.tag == .colon) {
            arg_name = self.current.lexeme;
            self.advance();
            self.advance();
        }
        const val = try self.parseExpression(.none);
        return .{ .name = arg_name, .value = val, .modifier = mod };
    }

    fn parseParenArgs(self: *Parser) ParseError![]const ast.NamedArg {
        var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
        errdefer args.deinit(self.allocator);
        if (self.current.tag == .l_paren) {
            self.advance();
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                self.skipIgnored();
                try args.append(self.allocator, try self.parseNamedArg());
                if (self.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
        }
        return args.toOwnedSlice(self.allocator);
    }

    fn parseParam(self: *Parser) ParseError!ast.Param {
        const mod = self.parseArgModifier();
        if (self.current.tag != .ident) return ParseError.UnexpectedToken;
        const param_name = self.current.lexeme;
        self.advance();

        var is_keyword = false;
        var default_val: ?*Node = null;

        if (self.current.tag == .colon) {
            is_keyword = true;
            self.advance();
            if (self.current.tag != .comma and self.current.tag != .r_paren) {
                default_val = try self.parseExpression(.none);
            }
        } else if (self.current.tag == .equal) {
            self.advance();
            default_val = try self.parseExpression(.none);
        }
        return .{ .name = param_name, .default_value = default_val, .modifier = mod, .is_keyword = is_keyword };
    }

    fn parseParenParams(self: *Parser) ParseError![]const ast.Param {
        var params: std.ArrayListUnmanaged(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);
        if (self.current.tag == .l_paren) {
            self.advance();
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                self.skipIgnored();
                try params.append(self.allocator, try self.parseParam());
                if (self.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
        }
        return params.toOwnedSlice(self.allocator);
    }

    // --- EXPRESSION PARSERS ---

    pub fn parseExpression(self: *Parser, precedence: Precedence) ParseError!*Node {
        const start_tok = self.current;
        var left: *Node = undefined;

        switch (start_tok.tag) {
            .number => {
                self.advance();
                left = try self.b.number(start_tok.lexeme, start_tok.loc);
            },
            .string => {
                self.advance();
                left = try self.createNode(.{ .string = start_tok.lexeme }, start_tok.loc);
            },
            .string_start => left = try self.parseInterpolatedString(),
            .symbol => {
                self.advance();
                left = try self.createNode(.{ .symbol = start_tok.lexeme }, start_tok.loc);
            },
            .keyword_true => {
                self.advance();
                left = try self.createNode(.{ .boolean = true }, start_tok.loc);
            },
            .keyword_false => {
                self.advance();
                left = try self.createNode(.{ .boolean = false }, start_tok.loc);
            },
            .keyword_nil => {
                self.advance();
                left = try self.createNode(.nil, start_tok.loc);
            },
            .keyword_self => {
                self.advance();
                left = try self.createNode(.self_expr, start_tok.loc);
            },
            .keyword_super => left = try self.parseSuper(),
            .minus_greater => left = try self.parseLambda(),
            .colon_colon => left = try self.parseTopLevelScopeResolution(),
            .ident, .constant => left = try self.parseIdentifierOrCall(),
            .l_paren => left = try self.parseGroupedExpression(),
            .l_bracket => left = try self.parseArrayLiteral(),
            .l_brace => left = try self.parseHashLiteral(),
            .plus, .minus, .bang, .keyword_not, .tilde => left = try self.parseUnary(),
            .keyword_if => left = try self.parseIfStatement(),
            .keyword_unless => left = try self.parseUnlessStatement(),
            .keyword_case => left = try self.parseCaseStatement(),
            else => return ParseError.InvalidExpression,
        }

        while (@intFromEnum(precedence) < @intFromEnum(getInfixPrecedence(self.current.tag))) {
            const op_tok = self.current;
            left = switch (op_tok.tag) {
                .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal, .percent_equal, .star_star_equal, .or_or_equal, .and_and_equal, .ampersand_equal, .pipe_equal, .caret_equal, .less_less_equal, .greater_greater_equal => try self.parseAssignmentExpr(left),
                .plus, .minus, .star, .slash, .percent, .star_star, .equal_equal, .bang_equal, .less, .less_equal, .greater, .greater_equal, .and_and, .or_or, .dot_dot, .dot_dot_dot, .less_less, .greater_greater, .keyword_and, .keyword_or, .ampersand, .pipe, .caret => try self.parseBinary(left),
                .question => try self.parseTernary(left),
                .dot => try self.parseMethodCall(left, false),
                .ampersand_dot => try self.parseMethodCall(left, true),
                .colon_colon => try self.parseScopeResolution(left),
                .l_bracket => try self.parseIndexAccessOrAssignment(left),
                .l_paren => try self.parseCallOnExpr(left),

                else => break,
            };
        }
        return left;
    }

    fn parseLambda(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.minus_greater);
        const params = try self.parseParenParams();
        self.skipIgnored();

        var body: *Node = undefined;
        if (self.current.tag == .l_brace) {
            self.advance();
            body = try self.parseBlock(&.{.r_brace});
            _ = try self.expect(.r_brace);
        } else if (self.current.tag == .keyword_do) {
            self.advance();
            body = try self.parseBlock(&.{.keyword_end});
            _ = try self.expect(.keyword_end);
        } else {
            return ParseError.UnexpectedToken;
        }

        return self.createNode(.{ .lambda_expr = .{ .params = params, .body = body } }, start_tok.loc);
    }

    fn parseInterpolatedString(self: *Parser) ParseError!*Node {
        const start_tok = self.current;
        var parts: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer parts.deinit(self.allocator);

        try parts.append(self.allocator, try self.createNode(.{ .string = start_tok.lexeme }, start_tok.loc));
        self.advance();

        while (true) {
            self.skipIgnored();
            if (self.current.tag != .string_mid and self.current.tag != .string_end) {
                const expr = try self.parseExpression(.none);
                try parts.append(self.allocator, expr);
            }
            self.skipIgnored();
            if (self.current.tag == .string_end) {
                try parts.append(self.allocator, try self.createNode(.{ .string = self.current.lexeme }, self.current.loc));
                self.advance();
                break;
            } else if (self.current.tag == .string_mid) {
                try parts.append(self.allocator, try self.createNode(.{ .string = self.current.lexeme }, self.current.loc));
                self.advance();
            } else {
                return ParseError.UnexpectedToken;
            }
        }
        return self.createNode(.{ .interpolated_string = try parts.toOwnedSlice(self.allocator) }, start_tok.loc);
    }

    fn parseAssignmentExpr(self: *Parser, left: *Node) ParseError!*Node {
        const op_tag = self.current.tag;
        self.advance();
        const value = try self.parseExpression(.none); // Right associative

        if (left.kind == .identifier) {
            return self.createNode(.{ .assignment = .{
                .name = left.kind.identifier,
                .op = tagToAssignmentOp(op_tag),
                .value = value,
            } }, left.loc);
        } else if (left.kind == .method_call and left.kind.method_call.args.len == 0 and left.kind.method_call.block == null) {
            return self.createNode(.{ .property_assignment = .{
                .target = left.kind.method_call.receiver orelse return ParseError.InvalidExpression,
                .property = left.kind.method_call.method_name,
                .op = tagToAssignmentOp(op_tag),
                .value = value,
            } }, left.loc);
        }
        return ParseError.InvalidExpression;
    }

    fn parseSuper(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.keyword_super);
        const args = try self.parseParenArgs();
        return self.createNode(.{
            .super_call = .{ .args = args },
        }, tok.loc);
    }

    fn parseTopLevelScopeResolution(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.colon_colon);
        const right_tok = if (self.current.tag == .constant or self.current.tag == .ident) self.current else return ParseError.UnexpectedToken;
        self.advance();

        var path_list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer path_list.deinit(self.allocator);
        try path_list.append(self.allocator, right_tok.lexeme);

        return self.createNode(.{
            .namespace_access = .{ .path = try path_list.toOwnedSlice(self.allocator) },
        }, tok.loc);
    }

    fn isCommandCallStart(self: *Parser) bool {
        const tag = self.current.tag;
        if (tag == .newline or tag == .eof or tag == .r_paren or tag == .r_brace or tag == .r_bracket or tag == .comma) return false;
        if (tag == .keyword_do or tag == .l_brace) return true;
        if (isAssignmentOp(tag)) return false;
        if (tag == .keyword_if or tag == .keyword_unless or tag == .keyword_while or tag == .keyword_until) return false;

        if (@intFromEnum(getInfixPrecedence(tag)) == 0) return true;
        return false;
    }

    fn parseCommandArgsAndBlock(self: *Parser) ParseError!struct { args: []const ast.NamedArg, block: ?*Node } {
        var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
        errdefer args.deinit(self.allocator);

        while (self.current.tag != .newline and self.current.tag != .eof and self.current.tag != .keyword_do and self.current.tag != .l_brace and self.current.tag != .r_paren and self.current.tag != .r_bracket and self.current.tag != .r_brace and self.current.tag != .keyword_if and self.current.tag != .keyword_unless and self.current.tag != .keyword_while and self.current.tag != .keyword_until) {
            try args.append(self.allocator, try self.parseNamedArg());
            if (self.current.tag == .comma) self.advance() else break;
        }

        var block_node: ?*Node = null;
        if (self.current.tag == .keyword_do or self.current.tag == .l_brace) {
            block_node = try self.parseBlockClosure();
        }
        return .{ .args = try args.toOwnedSlice(self.allocator), .block = block_node };
    }

    fn parseIdentifierOrCall(self: *Parser) ParseError!*Node {
        const tok = self.current;
        self.advance();
        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            return self.createNode(.{
                .method_call = .{ .receiver = null, .method_name = tok.lexeme, .args = cmd.args, .block = cmd.block, .is_safe = false },
            }, tok.loc);
        }
        return self.createNode(.{ .identifier = tok.lexeme }, tok.loc);
    }

    fn parseArrayLiteral(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.l_bracket);
        var elements: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer elements.deinit(self.allocator);

        while (self.current.tag != .r_bracket and self.current.tag != .eof) {
            self.skipIgnored();
            if (self.current.tag == .r_bracket) break;
            try elements.append(self.allocator, try self.parseExpression(.none));
            if (self.current.tag == .comma) self.advance() else break;
        }
        _ = try self.expect(.r_bracket);
        return self.createNode(.{ .array_literal = try elements.toOwnedSlice(self.allocator) }, start_tok.loc);
    }

    fn parseHashLiteral(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.l_brace);
        var entries: std.ArrayListUnmanaged(ast.HashEntry) = .empty;
        errdefer entries.deinit(self.allocator);

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            self.skipIgnored();
            if (self.current.tag == .r_brace) break;
            var key: *Node = undefined;
            if (self.current.tag == .ident and self.next_tok.tag == .colon) {
                const key_tok = self.current;
                self.advance();
                self.advance();
                key = try self.createNode(.{ .string = key_tok.lexeme }, key_tok.loc);
            } else {
                key = try self.parseExpression(.none);
                if (self.current.tag == .colon or self.current.tag == .arrow) {
                    self.advance();
                } else return ParseError.UnexpectedToken;
            }
            try entries.append(self.allocator, .{ .key = key, .value = try self.parseExpression(.none) });
            if (self.current.tag == .comma) self.advance() else break;
        }
        _ = try self.expect(.r_brace);
        return self.createNode(.{ .hash_literal = try entries.toOwnedSlice(self.allocator) }, start_tok.loc);
    }

    fn parseGroupedExpression(self: *Parser) ParseError!*Node {
        _ = try self.expect(.l_paren);
        const expr = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);
        return expr;
    }

    fn parseUnary(self: *Parser) ParseError!*Node {
        const tok = self.current;
        self.advance();
        const op: ast.UnaryOp = switch (tok.tag) {
            .minus => .negate,
            .plus => .positive,
            .tilde => .bitwise_not,
            else => .not,
        };
        return self.createNode(.{ .unary_op = .{ .op = op, .operand = try self.parseExpression(.unary) } }, tok.loc);
    }

    fn parseBinary(self: *Parser, left: *Node) ParseError!*Node {
        const tok = self.current;
        self.advance();

        if (tok.tag == .dot_dot or tok.tag == .dot_dot_dot) {
            return self.createNode(.{ .range = .{ .start = left, .end = try self.parseExpression(.range), .is_exclusive = (tok.tag == .dot_dot_dot) } }, tok.loc);
        }

        const op = tagToBinaryOp(tok.tag) orelse return ParseError.InvalidExpression;
        const next_prec = if (tok.tag == .star_star)
            @as(Precedence, @enumFromInt(@intFromEnum(getInfixPrecedence(tok.tag)) - 1))
        else
            getInfixPrecedence(tok.tag);

        return self.createNode(.{
            .binary_op = .{ .op = op, .left = left, .right = try self.parseExpression(next_prec) },
        }, tok.loc);
    }

    fn parseTernary(self: *Parser, condition: *Node) ParseError!*Node {
        const q_tok = try self.expect(.question);
        const then_branch = try self.parseExpression(.none);
        _ = try self.expect(.colon);
        const else_branch = try self.parseExpression(.none);
        return self.createNode(.{ .ternary_op = .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch } }, q_tok.loc);
    }

    fn parseIndexAccessOrAssignment(self: *Parser, target: *Node) ParseError!*Node {
        const bracket_tok = try self.expect(.l_bracket);
        const index = try self.parseExpression(.none);
        _ = try self.expect(.r_bracket);

        if (isAssignmentOp(self.current.tag)) {
            const op_tag = self.current.tag;
            self.advance();
            return self.createNode(.{
                .index_assignment = .{
                    .target = target,
                    .index = index,
                    .op = tagToAssignmentOp(op_tag),
                    .value = try self.parseExpression(.assignment),
                },
            }, bracket_tok.loc);
        }
        return self.createNode(.{ .index_access = .{ .target = target, .index = index } }, bracket_tok.loc);
    }

    fn parseCallOnExpr(self: *Parser, receiver_expr: *Node) ParseError!*Node {
        const args = try self.parseParenArgs();
        var block_node: ?*Node = null;
        if (self.current.tag == .keyword_do or self.current.tag == .l_brace) block_node = try self.parseBlockClosure();

        if (receiver_expr.kind == .identifier) {
            return self.createNode(.{
                .method_call = .{ .receiver = null, .method_name = receiver_expr.kind.identifier, .args = args, .block = block_node },
            }, receiver_expr.loc);
        } else {
            return self.createNode(.{
                .method_call = .{ .receiver = receiver_expr, .method_name = "", .args = args, .block = block_node },
            }, receiver_expr.loc);
        }
    }

    fn parseMethodCall(self: *Parser, receiver: *Node, is_safe: bool) ParseError!*Node {
        if (self.current.tag == .dot or self.current.tag == .ampersand_dot) self.advance();
        const method_tok = try self.expect(.ident);

        if (self.current.tag == .l_paren) {
            const args = try self.parseParenArgs();
            var block_node: ?*Node = null;
            if (self.current.tag == .keyword_do or self.current.tag == .l_brace) block_node = try self.parseBlockClosure();
            return self.createNode(.{
                .method_call = .{ .receiver = receiver, .method_name = method_tok.lexeme, .args = args, .block = block_node, .is_safe = is_safe },
            }, method_tok.loc);
        }

        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            return self.createNode(.{
                .method_call = .{ .receiver = receiver, .method_name = method_tok.lexeme, .args = cmd.args, .block = cmd.block, .is_safe = is_safe },
            }, method_tok.loc);
        }

        return self.createNode(.{
            .method_call = .{ .receiver = receiver, .method_name = method_tok.lexeme, .args = &.{}, .block = null, .is_safe = is_safe },
        }, method_tok.loc);
    }

    fn parseScopeResolution(self: *Parser, left: *Node) ParseError!*Node {
        const tok = try self.expect(.colon_colon);
        const right_tok = if (self.current.tag == .constant or self.current.tag == .ident) self.current else return ParseError.UnexpectedToken;
        self.advance();

        if (left.kind == .namespace_access) {
            var path_list: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer path_list.deinit(self.allocator);
            try path_list.appendSlice(self.allocator, left.kind.namespace_access.path);
            try path_list.append(self.allocator, right_tok.lexeme);

            return self.createNode(.{
                .namespace_access = .{ .path = try path_list.toOwnedSlice(self.allocator) },
            }, tok.loc);
        } else if (left.kind == .identifier) {
            var path_list: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer path_list.deinit(self.allocator);
            try path_list.append(self.allocator, left.kind.identifier);
            try path_list.append(self.allocator, right_tok.lexeme);

            return self.createNode(.{
                .namespace_access = .{ .path = try path_list.toOwnedSlice(self.allocator) },
            }, tok.loc);
        } else {
            return ParseError.InvalidExpression;
        }
    }

    fn parseBlockClosure(self: *Parser) ParseError!*Node {
        const is_brace = (self.current.tag == .l_brace);
        const start_tok = if (is_brace) try self.expect(.l_brace) else try self.expect(.keyword_do);
        var params: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer params.deinit(self.allocator);
        if (self.current.tag == .pipe) {
            self.advance();
            while (self.current.tag != .pipe and self.current.tag != .eof) {
                if (self.current.tag == .ident) {
                    try params.append(self.allocator, self.current.lexeme);
                    self.advance();
                } else return ParseError.UnexpectedToken;
                if (self.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.pipe);
        }
        const end_tags: []const Tag = if (is_brace) &.{.r_brace} else &.{.keyword_end};
        const block_node = try self.parseBlock(end_tags);
        if (is_brace) {
            _ = try self.expect(.r_brace);
        } else {
            _ = try self.expect(.keyword_end);
        }
        return self.createNode(.{
            .block = .{ .params = try params.toOwnedSlice(self.allocator), .stmts = block_node.kind.block.stmts },
        }, start_tok.loc);
    }

    fn createNode(self: *Parser, kind: Node.Kind, loc: ast.Location) ParseError!*Node {
        return self.b.create(kind, loc) catch ParseError.OutOfMemory;
    }

    fn getInfixPrecedence(tag: Tag) Precedence {
        return switch (tag) {
            .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal, .percent_equal, .star_star_equal, .or_or_equal, .and_and_equal, .ampersand_equal, .pipe_equal, .caret_equal, .less_less_equal, .greater_greater_equal => .assignment,
            .question => .ternary,
            .or_or, .keyword_or => .logical_or,
            .and_and, .keyword_and => .logical_and,
            .equal_equal, .bang_equal => .equality,
            .less, .less_equal, .greater, .greater_equal => .comparison,
            .pipe, .caret => .bitwise_or,
            .ampersand => .bitwise_and,
            .less_less, .greater_greater => .shift,
            .dot_dot, .dot_dot_dot => .range,
            .plus, .minus => .term,
            .star, .slash, .percent => .factor,
            .star_star => .exponent,
            .dot, .ampersand_dot, .l_paren, .keyword_do, .l_bracket, .colon_colon => .call,
            else => .none,
        };
    }

    fn tagToBinaryOp(tag: Tag) ?ast.BinaryOp {
        return switch (tag) {
            .plus => .add,
            .minus => .subtract,
            .star => .multiply,
            .slash => .divide,
            .percent => .modulo,
            .star_star => .exponent,
            .equal_equal => .equal,
            .bang_equal => .not_equal,
            .less => .less,
            .less_equal => .less_equal,
            .less_less => .shift_left,
            .greater => .greater,
            .greater_equal => .greater_equal,
            .greater_greater => .shift_right,
            .and_and, .keyword_and => .logical_and,
            .or_or, .keyword_or => .logical_or,
            .ampersand => .bitwise_and,
            .pipe => .bitwise_or,
            .caret => .bitwise_xor,
            else => null,
        };
    }
};
