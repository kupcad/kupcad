const std = @import("std");
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const Tag = lexer_mod.Tag;
const Token = lexer_mod.Token;
const ast = @import("../common/ast.zig");
const Node = ast.Node;

pub const ParseError = error{
    UnexpectedToken,
    InvalidExpression,
    OutOfMemory,
};

pub const Precedence = enum(u8) {
    none = 0,
    ternary = 1, // ? :
    logical_or = 2, // ||
    logical_and = 3, // &&
    equality = 4, // == !=
    comparison = 5, // < <= > >=
    term = 6, // + -
    factor = 7, // * / %
    exponent = 8, // ^
    unary = 9, // ! -
    call = 10, // . () []
};

pub const Parser = struct {
    lexer: *Lexer,
    allocator: std.mem.Allocator,
    b: ast.Builder,
    current: Token,

    pub fn init(lexer: *Lexer, allocator: std.mem.Allocator) Parser {
        var parser = Parser{
            .lexer = lexer,
            .allocator = allocator,
            .b = ast.Builder.init(allocator),
            .current = undefined,
        };
        parser.advance();
        return parser;
    }

    fn advance(self: *Parser) void {
        self.current = self.lexer.next();
    }

    fn expect(self: *Parser, tag: Tag) ParseError!Token {
        if (self.current.tag == tag) {
            const tok = self.current;
            self.advance();
            return tok;
        }
        return ParseError.UnexpectedToken;
    }

    pub fn parseProgram(self: *Parser) ParseError!*Node {
        return self.parseBlock();
    }

    pub fn parseBlock(self: *Parser) ParseError!*Node {
        const start_loc = self.current.loc;
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer stmts.deinit(self.allocator);

        while (self.current.tag != .eof and self.current.tag != .r_brace) {
            if (self.current.tag == .comment or self.current.tag == .block_comment) {
                self.advance();
                continue;
            }
            const stmt = try self.parseStatement();
            try stmts.append(self.allocator, stmt);
        }

        const stmts_slice = try stmts.toOwnedSlice(self.allocator);
        return self.createNode(.{
            .block = .{ .stmts = stmts_slice },
        }, start_loc);
    }

    pub fn parseStatement(self: *Parser) ParseError!*Node {
        while (self.current.tag == .comment or self.current.tag == .block_comment) {
            self.advance();
        }
        return switch (self.current.tag) {
            .keyword_module => try self.parseModuleDecl(),
            .keyword_function => try self.parseFunctionDecl(),
            .keyword_include, .keyword_use => try self.parseIncludeOrUse(),
            .keyword_if => try self.parseIfStatement(),
            .keyword_for, .keyword_intersection_for => try self.parseForLoop(),
            .keyword_let => try self.parseLetStatement(),
            .keyword_assert, .keyword_echo => try self.parseAssertOrEcho(),
            .bang, .mod_debug, .star, .percent => try self.parseModifierCall(),
            .l_brace => try self.parseScopedBlock(),
            else => try self.parseInstantiationOrAssignment(),
        };
    }

    fn parseScopedBlock(self: *Parser) ParseError!*Node {
        _ = try self.expect(.l_brace);
        const block_node = try self.parseBlock();
        _ = try self.expect(.r_brace);
        return block_node;
    }

    fn parseIncludeOrUse(self: *Parser) ParseError!*Node {
        const is_use = (self.current.tag == .keyword_use);
        const start_tok = self.current;
        self.advance();

        var path_str: []const u8 = "";

        if (self.current.tag == .less) {
            self.advance();
            var path_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer path_buf.deinit(self.allocator);
            while (self.current.tag != .greater and self.current.tag != .eof) {
                try path_buf.appendSlice(self.allocator, self.current.lexeme);
                self.advance();
            }
            _ = try self.expect(.greater);
            path_str = try self.allocator.dupe(u8, path_buf.items);
        } else if (self.current.tag == .string) {
            path_str = try self.allocator.dupe(u8, self.current.lexeme);
            self.advance();
        } else {
            return ParseError.UnexpectedToken;
        }

        return self.createNode(.{
            .include_stmt = .{
                .path = path_str,
                .is_use = is_use,
            },
        }, start_tok.loc);
    }

    fn parseModuleDecl(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_module);
        const name_tok = try self.expect(.ident);

        var params: std.ArrayListUnmanaged(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);

        if (self.current.tag == .l_paren) {
            self.advance();
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                if (self.current.tag == .ident) {
                    const pname = self.current.lexeme;
                    self.advance();
                    var default_val: ?*Node = null;
                    if (self.current.tag == .equal) {
                        self.advance();
                        default_val = try self.parseExpression(.none);
                    }
                    try params.append(self.allocator, .{ .name = pname, .default_value = default_val });
                }
                if (self.current.tag == .comma) {
                    self.advance();
                } else {
                    break;
                }
            }
            _ = try self.expect(.r_paren);
        }

        const body = if (self.current.tag == .l_brace) blk: {
            self.advance();
            const b = try self.parseBlock();
            _ = try self.expect(.r_brace);
            break :blk b;
        } else try self.parseStatement();

        const params_slice = try params.toOwnedSlice(self.allocator);
        return self.createNode(.{
            .module_stmt = .{
                .name = name_tok.lexeme,
                .params = params_slice,
                .body = body,
            },
        }, start_tok.loc);
    }

    fn parseFunctionDecl(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_function);
        const name_tok = try self.expect(.ident);

        var params: std.ArrayListUnmanaged(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);

        if (self.current.tag == .l_paren) {
            self.advance();
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                if (self.current.tag == .ident) {
                    const pname = self.current.lexeme;
                    self.advance();
                    var default_val: ?*Node = null;
                    if (self.current.tag == .equal) {
                        self.advance();
                        default_val = try self.parseExpression(.none);
                    }
                    try params.append(self.allocator, .{ .name = pname, .default_value = default_val });
                }
                if (self.current.tag == .comma) {
                    self.advance();
                } else {
                    break;
                }
            }
            _ = try self.expect(.r_paren);
        }

        _ = try self.expect(.equal);
        const body_expr = try self.parseExpression(.none);
        if (self.current.tag == .semicolon) {
            self.advance();
        }

        const params_slice = try params.toOwnedSlice(self.allocator);
        return self.createNode(.{
            .def_stmt = .{
                .name = name_tok.lexeme,
                .params = params_slice,
                .body = body_expr,
            },
        }, start_tok.loc);
    }

    fn parseIfStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_if);
        _ = try self.expect(.l_paren);
        const cond = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);

        const then_branch = if (self.current.tag == .l_brace) blk: {
            self.advance();
            const b = try self.parseBlock();
            _ = try self.expect(.r_brace);
            break :blk b;
        } else try self.parseStatement();

        var else_branch: ?*Node = null;
        if (self.current.tag == .keyword_else) {
            self.advance();
            else_branch = if (self.current.tag == .l_brace) blk: {
                self.advance();
                const b = try self.parseBlock();
                _ = try self.expect(.r_brace);
                break :blk b;
            } else try self.parseStatement();
        }

        return self.createNode(.{
            .if_stmt = .{
                .condition = cond,
                .then_branch = then_branch,
                .else_branch = else_branch,
            },
        }, start_tok.loc);
    }

    fn parseForLoop(self: *Parser) ParseError!*Node {
        const is_intersection = (self.current.tag == .keyword_intersection_for);
        const start_tok = self.current;
        self.advance();

        _ = try self.expect(.l_paren);
        var bindings: std.ArrayListUnmanaged(ast.ForBinding) = .empty;
        errdefer bindings.deinit(self.allocator);

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const range_node = try self.parseExpression(.none);
            try bindings.append(self.allocator, .{ .name = var_tok.lexeme, .range = range_node });
            if (self.current.tag == .comma) self.advance() else break;
        }
        _ = try self.expect(.r_paren);

        const body = if (self.current.tag == .l_brace) blk: {
            self.advance();
            const b = try self.parseBlock();
            _ = try self.expect(.r_brace);
            break :blk b;
        } else try self.parseStatement();

        return self.createNode(.{
            .for_stmt = .{
                .bindings = try bindings.toOwnedSlice(self.allocator),
                .body = body,
                .is_intersection = is_intersection,
            },
        }, start_tok.loc);
    }

    fn parseForClause(self: *Parser) ParseError!*Node {
        const is_intersection = (self.current.tag == .keyword_intersection_for);
        const start_tok = self.current;
        self.advance();

        _ = try self.expect(.l_paren);
        var bindings: std.ArrayListUnmanaged(ast.ForBinding) = .empty;
        errdefer bindings.deinit(self.allocator);

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const range_node = try self.parseExpression(.none);
            try bindings.append(self.allocator, .{ .name = var_tok.lexeme, .range = range_node });
            if (self.current.tag == .comma) self.advance() else break;
        }
        _ = try self.expect(.r_paren);

        const empty_body = try self.createNode(.{
            .block = .{ .stmts = &.{} },
        }, start_tok.loc);

        return self.createNode(.{
            .for_stmt = .{
                .bindings = try bindings.toOwnedSlice(self.allocator),
                .body = empty_body,
                .is_intersection = is_intersection,
            },
        }, start_tok.loc);
    }

    fn parseLetClause(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_let);
        _ = try self.expect(.l_paren);
        var assignments: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer assignments.deinit(self.allocator);

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const val_expr = try self.parseExpression(.none);
            const assign_node = try self.createNode(.{
                .assignment = .{
                    .name = var_tok.lexeme,
                    .op = null,
                    .value = val_expr,
                },
            }, var_tok.loc);
            try assignments.append(self.allocator, assign_node);
            if (self.current.tag == .comma) {
                self.advance();
            } else {
                break;
            }
        }
        _ = try self.expect(.r_paren);

        return self.createNode(.{
            .block = .{ .stmts = try assignments.toOwnedSlice(self.allocator) },
        }, start_tok.loc);
    }

    fn parseIfClause(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_if);
        _ = try self.expect(.l_paren);
        const cond = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);

        const empty_then = try self.createNode(.{
            .block = .{ .stmts = &.{} },
        }, start_tok.loc);

        return self.createNode(.{
            .if_stmt = .{
                .condition = cond,
                .then_branch = empty_then,
                .else_branch = null,
            },
        }, start_tok.loc);
    }

    fn parseLetStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_let);
        _ = try self.expect(.l_paren);
        var assignments: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer assignments.deinit(self.allocator);

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const val_expr = try self.parseExpression(.none);
            const assign_node = try self.createNode(.{
                .assignment = .{
                    .name = var_tok.lexeme,
                    .op = null,
                    .value = val_expr,
                },
            }, var_tok.loc);
            try assignments.append(self.allocator, assign_node);
            if (self.current.tag == .comma) {
                self.advance();
            } else {
                break;
            }
        }
        _ = try self.expect(.r_paren);

        const body = if (self.current.tag == .l_brace) blk: {
            self.advance();
            const b = try self.parseBlock();
            _ = try self.expect(.r_brace);
            break :blk b;
        } else try self.parseStatement();

        var stmts_list: std.ArrayListUnmanaged(*Node) = .empty;
        try stmts_list.appendSlice(self.allocator, assignments.items);
        try stmts_list.append(self.allocator, body);

        return self.createNode(.{
            .block = .{ .stmts = try stmts_list.toOwnedSlice(self.allocator) },
        }, start_tok.loc);
    }

    fn parseAssertOrEcho(self: *Parser) ParseError!*Node {
        const start_tok = self.current;
        self.advance();

        _ = try self.expect(.l_paren);
        var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
        errdefer args.deinit(self.allocator);

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            var arg_name: []const u8 = "";
            if (self.current.tag == .ident and self.peekNextTag() == .equal) {
                arg_name = self.current.lexeme;
                self.advance();
                self.advance();
            }
            const arg_val = try self.parseExpression(.none);
            try args.append(self.allocator, .{ .name = arg_name, .value = arg_val });
            if (self.current.tag == .comma) {
                self.advance();
            } else {
                break;
            }
        }
        _ = try self.expect(.r_paren);

        const call_node = try self.createNode(.{
            .method_call = .{
                .receiver = null,
                .method_name = start_tok.lexeme,
                .args = try args.toOwnedSlice(self.allocator),
            },
        }, start_tok.loc);

        if (self.current.tag == .semicolon) {
            self.advance();
            return call_node;
        } else if (self.current.tag == .l_brace) {
            self.advance();
            const child_block = try self.parseBlock();
            _ = try self.expect(.r_brace);
            var copy = call_node.kind.method_call;
            copy.block = child_block;
            call_node.kind = .{ .method_call = copy };
            return call_node;
        } else if (self.current.tag != .r_brace and self.current.tag != .eof) {
            const child_stmt = try self.parseStatement();
            var copy = call_node.kind.method_call;
            copy.block = child_stmt;
            call_node.kind = .{ .method_call = copy };
            return call_node;
        }

        return call_node;
    }

    fn parseModifierCall(self: *Parser) ParseError!*Node {
        const mod_tok = self.current;
        self.advance();
        const child = try self.parseStatement();
        return self.createNode(.{
            .modifier_call = .{
                .modifier = mod_tok.lexeme,
                .child = child,
            },
        }, mod_tok.loc);
    }

    fn parseInstantiationOrAssignment(self: *Parser) ParseError!*Node {
        const target_tok = self.current;
        if (target_tok.tag == .ident and self.peekNextTag() == .equal) {
            self.advance();
            self.advance();
            const val = try self.parseExpression(.none);
            if (self.current.tag == .semicolon) {
                self.advance();
            }
            return self.createNode(.{
                .assignment = .{
                    .name = target_tok.lexeme,
                    .op = null,
                    .value = val,
                },
            }, target_tok.loc);
        }

        const expr = try self.parseExpression(.none);

        if (expr.kind == .method_call) {
            var call_copy = expr.kind.method_call;

            if (self.current.tag == .l_brace) {
                self.advance();
                const children_block = try self.parseBlock();
                _ = try self.expect(.r_brace);
                call_copy.block = children_block;
                expr.kind = .{ .method_call = call_copy };
            } else if (self.current.tag != .semicolon and self.current.tag != .r_brace and self.current.tag != .eof) {
                const child_stmt = try self.parseStatement();
                call_copy.block = child_stmt;
                expr.kind = .{ .method_call = call_copy };
            }
        }

        if (self.current.tag == .semicolon) {
            self.advance();
        }

        return expr;
    }

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
            .keyword_true => {
                self.advance();
                left = try self.createNode(.{ .boolean = true }, start_tok.loc);
            },
            .keyword_false => {
                self.advance();
                left = try self.createNode(.{ .boolean = false }, start_tok.loc);
            },
            .keyword_undef => {
                self.advance();
                left = try self.createNode(.undef, start_tok.loc);
            },
            .ident => left = try self.parseIdentifierOrCall(),
            .l_paren => left = try self.parseGroupedExpression(),
            .l_bracket => left = try self.parseArrayOrRangeOrComprehension(),
            .plus, .minus, .bang => left = try self.parseUnary(),
            .keyword_let => left = try self.parseLetExpression(),
            .keyword_if => left = try self.parseIfExpression(),
            .keyword_assert, .keyword_echo => left = try self.parseAssertOrEchoExpr(),
            else => return ParseError.InvalidExpression,
        }

        while (@intFromEnum(precedence) < @intFromEnum(getInfixPrecedence(self.current.tag))) {
            const op_tok = self.current;
            left = switch (op_tok.tag) {
                .plus, .minus, .star, .slash, .percent, .caret, .equal_equal, .bang_equal, .less, .less_equal, .greater, .greater_equal, .and_and, .or_or => try self.parseBinary(left),
                .question => try self.parseTernary(left),
                .l_bracket => try self.parseIndexAccess(left),
                else => break,
            };
        }
        return left;
    }

    fn parseLetExpression(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_let);
        _ = try self.expect(.l_paren);

        var assignments: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer assignments.deinit(self.allocator);

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const val_expr = try self.parseExpression(.none);
            const assign_node = try self.createNode(.{ .assignment = .{ .name = var_tok.lexeme, .op = null, .value = val_expr } }, var_tok.loc);
            try assignments.append(self.allocator, assign_node);
            if (self.current.tag == .comma) self.advance() else break;
        }
        _ = try self.expect(.r_paren);

        const yield_expr = try self.parseExpression(.none);
        return self.createNode(.{ .let_expr = .{
            .assignments = try assignments.toOwnedSlice(self.allocator),
            .yield_expr = yield_expr,
        } }, start_tok.loc);
    }

    fn parseIfExpression(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_if);
        _ = try self.expect(.l_paren);
        const cond = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);

        const then_branch = try self.parseExpression(.none);
        var else_branch: ?*Node = null;

        if (self.current.tag == .keyword_else) {
            self.advance();
            else_branch = try self.parseExpression(.none);
        }

        return self.createNode(.{ .if_stmt = .{
            .condition = cond,
            .then_branch = then_branch,
            .else_branch = else_branch,
            .is_unless = false,
        } }, start_tok.loc);
    }

    fn parseAssertOrEchoExpr(self: *Parser) ParseError!*Node {
        const start_tok = self.current;
        const is_assert = (start_tok.tag == .keyword_assert);
        self.advance();
        _ = try self.expect(.l_paren);

        var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
        errdefer args.deinit(self.allocator);

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            var arg_name: []const u8 = "";
            if (self.current.tag == .ident and self.peekNextTag() == .equal) {
                arg_name = self.current.lexeme;
                self.advance();
                self.advance();
            }
            const arg_val = try self.parseExpression(.none);
            try args.append(self.allocator, .{ .name = arg_name, .value = arg_val, .modifier = null });
            if (self.current.tag == .comma) {
                self.advance();
            } else {
                break;
            }
        }
        _ = try self.expect(.r_paren);

        const yield_expr = try self.parseExpression(.none);

        if (is_assert) {
            return self.createNode(.{ .assert_expr = .{ .args = try args.toOwnedSlice(self.allocator), .yield_expr = yield_expr } }, start_tok.loc);
        } else {
            return self.createNode(.{ .echo_expr = .{ .args = try args.toOwnedSlice(self.allocator), .yield_expr = yield_expr } }, start_tok.loc);
        }
    }

    fn parseIdentifierOrCall(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.ident);
        if (self.current.tag == .l_paren) {
            self.advance();
            var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
            errdefer args.deinit(self.allocator);

            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                var arg_name: []const u8 = "";
                if (self.current.tag == .ident and self.peekNextTag() == .equal) {
                    arg_name = self.current.lexeme;
                    self.advance();
                    self.advance();
                }
                const arg_val = try self.parseExpression(.none);
                try args.append(self.allocator, .{ .name = arg_name, .value = arg_val });
                if (self.current.tag == .comma) {
                    self.advance();
                } else {
                    break;
                }
            }
            _ = try self.expect(.r_paren);

            const args_slice = try args.toOwnedSlice(self.allocator);
            return self.createNode(.{
                .method_call = .{
                    .receiver = null,
                    .method_name = tok.lexeme,
                    .args = args_slice,
                },
            }, tok.loc);
        }
        return self.createNode(.{ .identifier = tok.lexeme }, tok.loc);
    }

    fn parseGroupedExpression(self: *Parser) ParseError!*Node {
        _ = try self.expect(.l_paren);
        const expr = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);
        return expr;
    }

    fn parseArrayOrRangeOrComprehension(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.l_bracket);
        while (self.current.tag == .comment or self.current.tag == .block_comment) {
            self.advance();
        }

        if (self.current.tag == .keyword_for or self.current.tag == .keyword_let or self.current.tag == .keyword_intersection_for) {
            var clauses: std.ArrayListUnmanaged(*Node) = .empty;
            errdefer clauses.deinit(self.allocator);

            while (self.current.tag == .keyword_for or self.current.tag == .keyword_let or self.current.tag == .keyword_if or self.current.tag == .keyword_intersection_for) {
                if (self.current.tag == .keyword_for or self.current.tag == .keyword_intersection_for) {
                    const clause = try self.parseForClause();
                    try clauses.append(self.allocator, clause);
                } else if (self.current.tag == .keyword_let) {
                    const clause = try self.parseLetClause();
                    try clauses.append(self.allocator, clause);
                } else if (self.current.tag == .keyword_if) {
                    const clause = try self.parseIfClause();
                    try clauses.append(self.allocator, clause);
                }
                while (self.current.tag == .comment or self.current.tag == .block_comment) {
                    self.advance();
                }
            }

            const yield_expr = if (self.current.tag == .keyword_each) blk: {
                const each_tok = self.current;
                self.advance();
                const inner = try self.parseExpression(.none);
                break :blk try self.createNode(.{ .each_expr = inner }, each_tok.loc);
            } else try self.parseExpression(.none);

            while (self.current.tag == .comment or self.current.tag == .block_comment) {
                self.advance();
            }
            _ = try self.expect(.r_bracket);

            return self.createNode(.{
                .comprehension = .{
                    .clauses = try clauses.toOwnedSlice(self.allocator),
                    .yield_expr = yield_expr,
                },
            }, start_tok.loc);
        }

        var elements: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer elements.deinit(self.allocator);

        if (self.current.tag == .r_bracket) {
            self.advance();
            return self.createNode(.{ .array_literal = &.{} }, start_tok.loc);
        }

        const first = try self.parseExpression(.none);
        if (self.current.tag == .colon) {
            self.advance();
            const second = try self.parseExpression(.none);
            if (self.current.tag == .colon) {
                self.advance();
                const third = try self.parseExpression(.none);
                _ = try self.expect(.r_bracket);
                return self.createNode(.{
                    .range = .{
                        .start = first,
                        .step = second,
                        .end = third,
                    },
                }, start_tok.loc);
            }
            _ = try self.expect(.r_bracket);
            return self.createNode(.{
                .range = .{
                    .start = first,
                    .end = second,
                },
            }, start_tok.loc);
        }

        try elements.append(self.allocator, first);
        if (self.current.tag == .comma) {
            self.advance();
        }

        while (self.current.tag != .r_bracket and self.current.tag != .eof) {
            while (self.current.tag == .comment or self.current.tag == .block_comment) {
                self.advance();
            }
            if (self.current.tag == .r_bracket) break;
            const elem = try self.parseExpression(.none);
            try elements.append(self.allocator, elem);
            if (self.current.tag == .comma) {
                self.advance();
            } else {
                break;
            }
        }
        _ = try self.expect(.r_bracket);

        const elements_slice = try elements.toOwnedSlice(self.allocator);
        return self.createNode(.{ .array_literal = elements_slice }, start_tok.loc);
    }

    fn parseUnary(self: *Parser) ParseError!*Node {
        const tok = self.current;
        self.advance();
        const op: ast.UnaryOp = switch (tok.tag) {
            .minus => .negate,
            .plus => .positive,
            else => .not,
        };
        const operand = try self.parseExpression(.unary);
        return self.createNode(.{
            .unary_op = .{
                .op = op,
                .operand = operand,
            },
        }, tok.loc);
    }

    fn parseBinary(self: *Parser, left: *Node) ParseError!*Node {
        const tok = self.current;
        self.advance();
        const op = tagToBinaryOp(tok.tag) orelse return ParseError.InvalidExpression;
        const right = try self.parseExpression(getInfixPrecedence(tok.tag));
        return self.createNode(.{
            .binary_op = .{
                .op = op,
                .left = left,
                .right = right,
            },
        }, tok.loc);
    }

    fn parseTernary(self: *Parser, condition: *Node) ParseError!*Node {
        const q_tok = try self.expect(.question);
        const then_branch = try self.parseExpression(.none);
        _ = try self.expect(.colon);
        const else_branch = try self.parseExpression(.none);
        return self.createNode(.{
            .ternary_op = .{
                .condition = condition,
                .then_branch = then_branch,
                .else_branch = else_branch,
            },
        }, q_tok.loc);
    }

    fn parseIndexAccess(self: *Parser, target: *Node) ParseError!*Node {
        const bracket_tok = try self.expect(.l_bracket);
        const index = try self.parseExpression(.none);
        _ = try self.expect(.r_bracket);
        return self.createNode(.{
            .index_access = .{
                .target = target,
                .index = index,
            },
        }, bracket_tok.loc);
    }

    inline fn peekNextTag(self: *Parser) Tag {
        var copy = self.lexer.*;
        return copy.next().tag;
    }

    fn createNode(self: *Parser, kind: Node.Kind, loc: ast.Location) ParseError!*Node {
        return self.b.create(kind, loc) catch ParseError.OutOfMemory;
    }

    fn getInfixPrecedence(tag: Tag) Precedence {
        return switch (tag) {
            .question => .ternary,
            .or_or => .logical_or,
            .and_and => .logical_and,
            .equal_equal, .bang_equal => .equality,
            .less, .less_equal, .greater, .greater_equal => .comparison,
            .plus, .minus => .term,
            .star, .slash, .percent => .factor,
            .caret => .exponent,
            .l_bracket => .call,
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
            .caret => .exponent,
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
