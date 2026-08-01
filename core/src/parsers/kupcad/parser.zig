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
    range = 7, // ..
    term = 8, // + -
    factor = 9, // * / %
    exponent = 10, // **
    unary = 11, // ! -
    call = 12, // . () [] ::
};

pub const Parser = struct {
    lexer: *Lexer,
    allocator: std.mem.Allocator,
    current: Token,
    next_tok: Token,

    pub fn init(lexer: *Lexer, allocator: std.mem.Allocator) Parser {
        var parser = Parser{ .lexer = lexer, .allocator = allocator, .current = undefined, .next_tok = undefined };
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
            .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal, .percent_equal, .star_star_equal, .or_or_equal, .and_and_equal => true,
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
            .param_doc => try self.parseParamDoc(),
            else => try self.parseExpression(.none),
        };

        // Command Syntax check at the statement level
        if (stmt.kind == .identifier and self.current.tag != .newline and self.current.tag != .eof and self.current.tag != .keyword_if and self.current.tag != .keyword_unless) {
            if (@intFromEnum(getInfixPrecedence(self.current.tag)) == 0 and self.current.tag != .keyword_do and self.current.tag != .colon) {
                var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
                errdefer args.deinit(self.allocator);
                while (self.current.tag != .newline and self.current.tag != .eof and self.current.tag != .keyword_do) {
                    var arg_name: []const u8 = "";
                    if (self.current.tag == .ident and self.next_tok.tag == .colon) {
                        arg_name = self.current.lexeme;
                        self.advance();
                        self.advance();
                    }
                    try args.append(self.allocator, .{ .name = arg_name, .value = try self.parseExpression(.none) });
                    if (self.current.tag == .comma) self.advance() else break;
                }
                var block_node: ?*Node = null;
                if (self.current.tag == .keyword_do) block_node = try self.parseDoBlock();
                stmt = try self.createNode(.{
                    .method_call = .{ .receiver = null, .method_name = stmt.kind.identifier, .args = try args.toOwnedSlice(self.allocator), .block = block_node },
                }, stmt.loc);
            }
        }

        if (self.current.tag == .keyword_if or self.current.tag == .keyword_unless) {
            const is_unless = (self.current.tag == .keyword_unless);
            const mod_loc = self.current.loc;
            self.advance();
            const cond = try self.parseExpression(.none);
            const then_block = try self.createNode(.{
                .block = .{ .stmts = try self.allocator.dupe(*Node, &.{stmt}) },
            }, stmt.loc);
            stmt = try self.createNode(.{
                .if_stmt = .{ .condition = cond, .then_branch = then_block, .else_branch = null, .is_unless = is_unless },
            }, mod_loc);
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
        const start_tok = try self.expect(.keyword_while);
        const condition = try self.parseExpression(.none);
        self.skipIgnored();

        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.createNode(.{ .while_stmt = .{ .condition = condition, .body = body } }, start_tok.loc);
    }

    fn parseDefStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_def);
        const name_tok = if (self.current.tag == .ident or self.current.tag == .constant) self.current else return ParseError.UnexpectedToken;
        self.advance();

        var params: std.ArrayListUnmanaged(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);

        if (self.current.tag == .l_paren) {
            self.advance();
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                self.skipIgnored();
                if (self.current.tag == .ident) {
                    const param_name = self.current.lexeme;
                    self.advance();
                    var default_val: ?*Node = null;
                    if (self.current.tag == .equal) {
                        self.advance();
                        default_val = try self.parseExpression(.none);
                    }
                    try params.append(self.allocator, .{ .name = param_name, .default_value = default_val });
                }
                if (self.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
        }

        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.createNode(.{ .def_stmt = .{ .name = name_tok.lexeme, .params = try params.toOwnedSlice(self.allocator), .body = body } }, start_tok.loc);
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
        var val: ?*Node = null;
        if (self.current.tag != .newline and self.current.tag != .eof and self.current.tag != .keyword_unless and self.current.tag != .keyword_if and self.current.tag != .keyword_end) {
            val = try self.parseExpression(.none);
        }
        return self.createNode(.{ .yield_stmt = val }, start_tok.loc);
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

    pub fn parseExpression(self: *Parser, precedence: Precedence) ParseError!*Node {
        const start_tok = self.current;
        var left = switch (start_tok.tag) {
            .number => try self.parseNumber(),
            .string => try self.parseString(),
            .string_start => try self.parseInterpolatedString(),
            .symbol => try self.parseSymbol(),
            .keyword_true, .keyword_false => try self.parseBoolean(),
            .keyword_nil => try self.parseNil(),
            .keyword_self => try self.parseSelf(),
            .keyword_super => try self.parseSuper(),
            .colon_colon => try self.parseTopLevelScopeResolution(),
            .ident, .constant => try self.parseIdentifierOrAssignmentOrCall(),
            .l_paren => try self.parseGroupedExpression(),
            .l_bracket => try self.parseArrayLiteral(),
            .l_brace => try self.parseHashLiteral(),
            .minus, .bang => try self.parseUnary(),
            .keyword_if => try self.parseIfStatement(),
            .keyword_unless => try self.parseUnlessStatement(),
            .keyword_case => try self.parseCaseStatement(),
            else => return ParseError.InvalidExpression,
        };

        while (@intFromEnum(precedence) < @intFromEnum(getInfixPrecedence(self.current.tag))) {
            const op_tok = self.current;
            left = switch (op_tok.tag) {
                .plus, .minus, .star, .slash, .percent, .star_star, .equal_equal, .bang_equal, .less, .less_equal, .greater, .greater_equal, .and_and, .or_or, .dot_dot => try self.parseBinary(left),
                .question => try self.parseTernary(left),
                .dot => try self.parseMethodCall(left),
                .colon_colon => try self.parseScopeResolution(left),
                .l_bracket => try self.parseIndexAccessOrAssignment(left),
                .l_paren, .keyword_do => try self.parseCallOnExpr(left),
                else => break,
            };
        }
        return left;
    }

    fn parseNumber(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.number);
        const val = std.fmt.parseFloat(f64, tok.lexeme) catch return ParseError.InvalidExpression;
        return self.createNode(.{ .number = val }, tok.loc);
    }

    fn parseString(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.string);
        return self.createNode(.{ .string = tok.lexeme }, tok.loc);
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

    fn parseSymbol(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.symbol);
        return self.createNode(.{ .symbol = tok.lexeme }, tok.loc);
    }

    fn parseBoolean(self: *Parser) ParseError!*Node {
        const tok = self.current;
        self.advance();
        return self.createNode(.{ .boolean = tok.tag == .keyword_true }, tok.loc);
    }

    fn parseNil(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.keyword_nil);
        return self.createNode(.nil, tok.loc);
    }

    fn parseSelf(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.keyword_self);
        return self.createNode(.self_expr, tok.loc);
    }

    fn parseSuper(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.keyword_super);
        var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
        errdefer args.deinit(self.allocator);

        if (self.current.tag == .l_paren) {
            self.advance();
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                self.skipIgnored();
                var arg_name: []const u8 = "";
                if (self.current.tag == .ident and self.next_tok.tag == .colon) {
                    arg_name = self.current.lexeme;
                    self.advance();
                    self.advance();
                }
                try args.append(self.allocator, .{ .name = arg_name, .value = try self.parseExpression(.none) });
                if (self.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
        }

        return self.createNode(.{
            .super_call = .{ .args = try args.toOwnedSlice(self.allocator) },
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

    fn parseIdentifierOrAssignmentOrCall(self: *Parser) ParseError!*Node {
        const tok = self.current;
        self.advance();

        // Multiple assignment: x, y, z = get_coordinates()
        if (self.current.tag == .comma) {
            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer names.deinit(self.allocator);
            try names.append(self.allocator, tok.lexeme);

            while (self.current.tag == .comma) {
                self.advance();
                if (self.current.tag == .ident or self.current.tag == .constant) {
                    try names.append(self.allocator, self.current.lexeme);
                    self.advance();
                } else return ParseError.UnexpectedToken;
            }

            if (isAssignmentOp(self.current.tag)) {
                const op_tag = self.current.tag;
                self.advance();
                const val_node = try self.parseExpression(.assignment);
                return self.createNode(.{
                    .multiple_assignment = .{
                        .names = try names.toOwnedSlice(self.allocator),
                        .op = tagToAssignmentOp(op_tag),
                        .value = val_node,
                    },
                }, tok.loc);
            } else return ParseError.UnexpectedToken;
        }

        if (isAssignmentOp(self.current.tag)) {
            const op_tag = self.current.tag;
            self.advance();
            const val_node = try self.parseExpression(.assignment);
            return self.createNode(.{
                .assignment = .{
                    .name = tok.lexeme,
                    .op = tagToAssignmentOp(op_tag),
                    .value = val_node,
                },
            }, tok.loc);
        }

        // Lookahead for command calls inside expressions
        if (self.current.tag != .newline and self.current.tag != .eof and self.current.tag != .r_paren and self.current.tag != .r_brace and self.current.tag != .r_bracket and self.current.tag != .comma) {
            if (@intFromEnum(getInfixPrecedence(self.current.tag)) == 0 and self.current.tag != .keyword_do and self.current.tag != .colon) {
                var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
                errdefer args.deinit(self.allocator);
                while (self.current.tag != .newline and self.current.tag != .eof and self.current.tag != .keyword_do and self.current.tag != .r_paren and self.current.tag != .r_brace and self.current.tag != .r_bracket) {
                    var arg_name: []const u8 = "";
                    if (self.current.tag == .ident and self.next_tok.tag == .colon) {
                        arg_name = self.current.lexeme;
                        self.advance();
                        self.advance();
                    }
                    try args.append(self.allocator, .{ .name = arg_name, .value = try self.parseExpression(.none) });
                    if (self.current.tag == .comma) self.advance() else break;
                }
                var block_node: ?*Node = null;
                if (self.current.tag == .keyword_do) block_node = try self.parseDoBlock();
                return self.createNode(.{
                    .method_call = .{ .receiver = null, .method_name = tok.lexeme, .args = try args.toOwnedSlice(self.allocator), .block = block_node },
                }, tok.loc);
            }
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
        const op: ast.UnaryOp = if (tok.tag == .minus) .negate else .not;
        return self.createNode(.{ .unary_op = .{ .op = op, .operand = try self.parseExpression(.unary) } }, tok.loc);
    }

    fn parseBinary(self: *Parser, left: *Node) ParseError!*Node {
        const tok = self.current;
        self.advance();

        if (tok.tag == .dot_dot) {
            return self.createNode(.{ .range = .{ .start = left, .end = try self.parseExpression(.range) } }, tok.loc);
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
        var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
        errdefer args.deinit(self.allocator);

        if (self.current.tag == .l_paren) {
            self.advance();
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                self.skipIgnored();
                var arg_name: []const u8 = "";
                if (self.current.tag == .ident and self.next_tok.tag == .colon) {
                    arg_name = self.current.lexeme;
                    self.advance();
                    self.advance();
                }
                try args.append(self.allocator, .{ .name = arg_name, .value = try self.parseExpression(.none) });
                if (self.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
        }

        var block_node: ?*Node = null;
        if (self.current.tag == .keyword_do) block_node = try self.parseDoBlock();

        if (receiver_expr.kind == .identifier) {
            return self.createNode(.{
                .method_call = .{ .receiver = null, .method_name = receiver_expr.kind.identifier, .args = try args.toOwnedSlice(self.allocator), .block = block_node },
            }, receiver_expr.loc);
        } else {
            return self.createNode(.{
                .method_call = .{ .receiver = receiver_expr, .method_name = "", .args = try args.toOwnedSlice(self.allocator), .block = block_node },
            }, receiver_expr.loc);
        }
    }

    fn parseMethodCall(self: *Parser, receiver: *Node) ParseError!*Node {
        if (self.current.tag == .dot) self.advance();
        const method_tok = try self.expect(.ident);

        var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
        errdefer args.deinit(self.allocator);

        if (self.current.tag == .l_paren) {
            self.advance();
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                self.skipIgnored();
                var arg_name: []const u8 = "";
                if (self.current.tag == .ident and self.next_tok.tag == .colon) {
                    arg_name = self.current.lexeme;
                    self.advance();
                    self.advance();
                }
                try args.append(self.allocator, .{ .name = arg_name, .value = try self.parseExpression(.none) });
                if (self.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
        }

        var block_node: ?*Node = null;
        if (self.current.tag == .keyword_do) block_node = try self.parseDoBlock();

        return self.createNode(.{
            .method_call = .{ .receiver = receiver, .method_name = method_tok.lexeme, .args = try args.toOwnedSlice(self.allocator), .block = block_node },
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

    fn parseDoBlock(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_do);
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

        const block_node = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.createNode(.{
            .block = .{ .params = try params.toOwnedSlice(self.allocator), .stmts = block_node.kind.block.stmts },
        }, start_tok.loc);
    }

    fn createNode(self: *Parser, kind: Node.Kind, loc: ast.Location) ParseError!*Node {
        const node = self.allocator.create(Node) catch return ParseError.OutOfMemory;
        node.* = .{ .kind = kind, .loc = loc };
        return node;
    }

    fn getInfixPrecedence(tag: Tag) Precedence {
        return switch (tag) {
            .question => .ternary,
            .or_or => .logical_or,
            .and_and => .logical_and,
            .equal_equal, .bang_equal => .equality,
            .less, .less_equal, .greater, .greater_equal => .comparison,
            .dot_dot => .range,
            .plus, .minus => .term,
            .star, .slash, .percent => .factor,
            .star_star => .exponent,
            .dot, .l_paren, .keyword_do, .l_bracket, .colon_colon => .call,
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
            .greater => .greater,
            .greater_equal => .greater_equal,
            .and_and => .logical_and,
            .or_or => .logical_or,
            else => null,
        };
    }
};
