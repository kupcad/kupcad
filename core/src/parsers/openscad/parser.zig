const std = @import("std");
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const Tag = lexer_mod.Tag;
const Token = lexer_mod.Token;
const ast = @import("../common/ast.zig");
const common_token = @import("../common/token.zig");
const Node = ast.Node;
const common_errors = @import("../common/errors.zig");
const Diagnostics = common_errors.Diagnostics;
pub const ParseError = common_errors.ParseError;

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
    tokens: common_token.BufferedLexer(Lexer, Token, Tag),
    allocator: std.mem.Allocator,
    b: ast.Builder,
    diagnostics: Diagnostics,

    pub fn init(lexer: *Lexer, allocator: std.mem.Allocator) Parser {
        return Parser{
            .tokens = common_token.BufferedLexer(Lexer, Token, Tag).init(lexer),
            .allocator = allocator,
            .b = ast.Builder.init(allocator),
            .diagnostics = Diagnostics.init(allocator),
        };
    }

    inline fn advance(self: *Parser) void {
        self.tokens.advance();
    }

    pub fn reportError(self: *Parser, loc: ast.Location, comptime fmt: []const u8, args: anytype) void {
        self.diagnostics.add(loc, fmt, args);
    }

    fn expect(self: *Parser, tag: Tag) ParseError!Token {
        if (self.tokens.current.tag == tag) {
            const tok = self.tokens.current;
            self.advance();
            return tok;
        }
        self.reportError(self.tokens.current.loc, "Expected '{s}', but found '{s}'", .{ @tagName(tag), self.tokens.current.lexeme });
        return ParseError.UnexpectedToken;
    }

    fn skipIgnored(self: *Parser) void {
        while (self.tokens.current.tag == .comment or self.tokens.current.tag == .block_comment) {
            self.advance();
        }
    }

    pub fn parseProgram(self: *Parser) ParseError!*Node {
        return self.parseBlock();
    }

    pub fn parseBlock(self: *Parser) ParseError!*Node {
        const start_loc = self.tokens.current.loc;
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer stmts.deinit(self.allocator);

        while (self.tokens.current.tag != .eof and self.tokens.current.tag != .r_brace) {
            self.skipIgnored();
            if (self.tokens.current.tag == .semicolon) {
                self.advance();
                continue;
            }
            if (self.tokens.current.tag == .r_brace) break;

            const stmt = try self.parseStatement();
            try stmts.append(self.allocator, stmt);
        }

        return self.createNode(.{
            .block = .{ .stmts = try stmts.toOwnedSlice(self.allocator) },
        }, start_loc);
    }

    pub fn parseStatement(self: *Parser) ParseError!*Node {
        self.skipIgnored();
        return switch (self.tokens.current.tag) {
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
        const is_use = (self.tokens.current.tag == .keyword_use);
        const start_tok = self.tokens.current;
        self.advance();

        var path_str: []const u8 = "";
        if (self.tokens.current.tag == .less) {
            self.advance();
            var path_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer path_buf.deinit(self.allocator);

            while (self.tokens.current.tag != .greater and self.tokens.current.tag != .eof) {
                try path_buf.appendSlice(self.allocator, self.tokens.current.lexeme);
                self.advance();
            }
            _ = try self.expect(.greater);
            path_str = try self.allocator.dupe(u8, path_buf.items);
        } else if (self.tokens.current.tag == .string) {
            path_str = try self.allocator.dupe(u8, self.tokens.current.lexeme);
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
        var params: []const ast.Param = &.{};
        if (self.tokens.current.tag == .l_paren) {
            params = try self.parseParenParams();
        }

        const body = if (self.tokens.current.tag == .l_brace) blk: {
            self.advance();
            const b = try self.parseBlock();
            _ = try self.expect(.r_brace);
            break :blk b;
        } else try self.parseStatement();

        return self.createNode(.{
            .module_stmt = .{
                .name = name_tok.lexeme,
                .params = params,
                .body = body,
            },
        }, start_tok.loc);
    }

    fn parseFunctionDecl(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_function);
        const name_tok = try self.expect(.ident);
        var params: []const ast.Param = &.{};
        if (self.tokens.current.tag == .l_paren) {
            params = try self.parseParenParams();
        }
        _ = try self.expect(.equal);

        const body_expr = try self.parseExpression(.none);
        if (self.tokens.current.tag == .semicolon) {
            self.advance();
        }

        return self.createNode(.{
            .def_stmt = .{
                .name = name_tok.lexeme,
                .params = params,
                .body = body_expr,
            },
        }, start_tok.loc);
    }

    fn parseIfStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_if);
        _ = try self.expect(.l_paren);
        const cond = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);

        const then_branch = if (self.tokens.current.tag == .l_brace) blk: {
            self.advance();
            const b = try self.parseBlock();
            _ = try self.expect(.r_brace);
            break :blk b;
        } else try self.parseStatement();

        var else_branch: ?*Node = null;
        if (self.tokens.current.tag == .keyword_else) {
            self.advance();
            else_branch = if (self.tokens.current.tag == .l_brace) blk: {
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
                .is_unless = false,
            },
        }, start_tok.loc);
    }

    fn parseForLoop(self: *Parser) ParseError!*Node {
        const is_intersection = (self.tokens.current.tag == .keyword_intersection_for);
        const start_tok = self.tokens.current;
        self.advance();
        _ = try self.expect(.l_paren);

        var init_assignments: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer init_assignments.deinit(self.allocator);

        var standard_bindings: std.ArrayListUnmanaged(ast.ForBinding) = .empty;
        errdefer standard_bindings.deinit(self.allocator);

        while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .semicolon and self.tokens.current.tag != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const val_expr = try self.parseExpression(.none);

            const assign_node = try self.createNode(.{ .assignment = .{ .name = var_tok.lexeme, .op = null, .value = val_expr } }, var_tok.loc);
            try init_assignments.append(self.allocator, assign_node);
            try standard_bindings.append(self.allocator, .{ .name = var_tok.lexeme, .range = val_expr });

            if (self.tokens.current.tag == .comma) self.advance() else break;
        }

        if (self.tokens.current.tag == .semicolon) {
            // --- C-STYLE FOR LOOP ---
            self.advance(); // consume ';'
            var condition: ?*Node = null;
            if (self.tokens.current.tag != .semicolon) condition = try self.parseExpression(.none);
            _ = try self.expect(.semicolon);

            var updates: std.ArrayListUnmanaged(*Node) = .empty;
            errdefer updates.deinit(self.allocator);
            while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .eof) {
                const target_tok = try self.expect(.ident);
                _ = try self.expect(.equal);
                const val = try self.parseExpression(.none);
                try updates.append(self.allocator, try self.createNode(.{ .assignment = .{ .name = target_tok.lexeme, .op = null, .value = val } }, target_tok.loc));
                if (self.tokens.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);

            const body = if (self.tokens.current.tag == .l_brace) blk: {
                self.advance();
                const b = try self.parseBlock();
                _ = try self.expect(.r_brace);
                break :blk b;
            } else try self.parseStatement();

            return self.createNode(.{
                .c_for_stmt = .{
                    .init = try init_assignments.toOwnedSlice(self.allocator),
                    .condition = condition,
                    .update = try updates.toOwnedSlice(self.allocator),
                    .body = body,
                    .is_intersection = is_intersection,
                },
            }, start_tok.loc);
        } else {
            // --- STANDARD FOR LOOP ---
            _ = try self.expect(.r_paren);
            const body = if (self.tokens.current.tag == .l_brace) blk: {
                self.advance();
                const b = try self.parseBlock();
                _ = try self.expect(.r_brace);
                break :blk b;
            } else try self.parseStatement();

            return self.createNode(.{
                .for_stmt = .{
                    .bindings = try standard_bindings.toOwnedSlice(self.allocator),
                    .body = body,
                    .is_intersection = is_intersection,
                },
            }, start_tok.loc);
        }
    }

    fn parseComprehensionElement(self: *Parser) ParseError!*Node {
        if (self.tokens.current.tag == .keyword_for or self.tokens.current.tag == .keyword_intersection_for) {
            const start_tok = self.tokens.current;
            self.advance();
            _ = try self.expect(.l_paren);

            var bindings: std.ArrayListUnmanaged(ast.ForBinding) = .empty;
            errdefer bindings.deinit(self.allocator);

            while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .eof) {
                const var_tok = try self.expect(.ident);
                _ = try self.expect(.equal);
                const range_node = try self.parseExpression(.none);
                try bindings.append(self.allocator, .{ .name = var_tok.lexeme, .range = range_node });
                if (self.tokens.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);

            const body = try self.parseComprehensionElement();
            return self.createNode(.{ .for_stmt = .{ .bindings = try bindings.toOwnedSlice(self.allocator), .body = body, .is_intersection = (start_tok.tag == .keyword_intersection_for) } }, start_tok.loc);
        } else if (self.tokens.current.tag == .keyword_let) {
            const start_tok = try self.expect(.keyword_let);
            _ = try self.expect(.l_paren);

            var assignments: std.ArrayListUnmanaged(*Node) = .empty;
            errdefer assignments.deinit(self.allocator);

            while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .eof) {
                const var_tok = try self.expect(.ident);
                _ = try self.expect(.equal);
                const val_expr = try self.parseExpression(.none);
                const assign_node = try self.createNode(.{ .assignment = .{ .name = var_tok.lexeme, .op = null, .value = val_expr } }, var_tok.loc);
                try assignments.append(self.allocator, assign_node);
                if (self.tokens.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);

            const yield_expr = try self.parseComprehensionElement();
            return self.createNode(.{ .let_expr = .{ .assignments = try assignments.toOwnedSlice(self.allocator), .yield_expr = yield_expr } }, start_tok.loc);
        } else if (self.tokens.current.tag == .keyword_if) {
            const start_tok = try self.expect(.keyword_if);
            _ = try self.expect(.l_paren);
            const cond = try self.parseExpression(.none);
            _ = try self.expect(.r_paren);

            const then_branch = try self.parseComprehensionElement();
            var else_branch: ?*Node = null;
            if (self.tokens.current.tag == .keyword_else) {
                self.advance();
                else_branch = try self.parseComprehensionElement();
            }

            return self.createNode(.{ .if_stmt = .{ .condition = cond, .then_branch = then_branch, .else_branch = else_branch, .is_unless = false } }, start_tok.loc);
        } else {
            var is_each = false;
            if (self.tokens.current.tag == .keyword_each) {
                is_each = true;
                self.advance();
            }

            var expr = try self.parseExpression(.none);
            if (is_each) {
                expr = try self.createNode(.{ .each_expr = expr }, expr.loc);
            }
            return expr;
        }
    }

    fn parseLetStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_let);
        _ = try self.expect(.l_paren);

        var assignments: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer assignments.deinit(self.allocator);

        while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .eof) {
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
            if (self.tokens.current.tag == .comma) {
                self.advance();
            } else {
                break;
            }
        }
        _ = try self.expect(.r_paren);

        const body = if (self.tokens.current.tag == .l_brace) blk: {
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
        const start_tok = self.tokens.current;
        self.advance();
        const args = try self.parseParenArgs();

        const call_node = try self.createNode(.{
            .method_call = .{
                .receiver = null,
                .method_name = start_tok.lexeme,
                .args = args,
            },
        }, start_tok.loc);

        if (self.tokens.current.tag == .semicolon) {
            self.advance();
            return call_node;
        } else if (self.tokens.current.tag == .l_brace) {
            self.advance();
            const child_block = try self.parseBlock();
            _ = try self.expect(.r_brace);
            var copy = call_node.kind.method_call;
            copy.block = child_block;
            call_node.kind = .{ .method_call = copy };
            return call_node;
        } else if (self.tokens.current.tag != .r_brace and self.tokens.current.tag != .eof) {
            const child_stmt = try self.parseStatement();
            var copy = call_node.kind.method_call;
            copy.block = child_stmt;
            call_node.kind = .{ .method_call = copy };
            return call_node;
        }

        return call_node;
    }

    fn parseModifierCall(self: *Parser) ParseError!*Node {
        const mod_tok = self.tokens.current;
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
        const target_tok = self.tokens.current;
        if (target_tok.tag == .ident and self.tokens.peekTag() == .equal) {
            self.advance();
            self.advance();
            const val = try self.parseExpression(.none);
            if (self.tokens.current.tag == .semicolon) {
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
            if (self.tokens.current.tag == .l_brace) {
                self.advance();
                const children_block = try self.parseBlock();
                _ = try self.expect(.r_brace);
                call_copy.block = children_block;
                expr.kind = .{ .method_call = call_copy };
            } else if (self.tokens.current.tag != .semicolon and self.tokens.current.tag != .r_brace and self.tokens.current.tag != .eof) {
                const child_stmt = try self.parseStatement();
                call_copy.block = child_stmt;
                expr.kind = .{ .method_call = call_copy };
            }
        }

        if (self.tokens.current.tag == .semicolon) {
            self.advance();
        }

        return expr;
    }

    // --- SHARED LIST PARSER COMBINATOR ---
    inline fn parseCommaSeparated(
        self: *Parser,
        comptime ItemType: type,
        comptime parseItemFn: fn (*Parser) ParseError!ItemType,
        end_tag: Tag,
    ) ParseError![]const ItemType {
        var items: std.ArrayListUnmanaged(ItemType) = .empty;
        errdefer items.deinit(self.allocator);

        while (self.tokens.current.tag != end_tag and self.tokens.current.tag != .eof) {
            self.skipIgnored();
            if (self.tokens.current.tag == end_tag) break;

            try items.append(self.allocator, try parseItemFn(self));

            if (self.tokens.current.tag == .comma) {
                self.advance();
            } else {
                break;
            }
        }
        return items.toOwnedSlice(self.allocator);
    }

    // --- SHARED DRY ARGUMENT & PARAMETER LOGIC ---
    fn parseNamedArg(self: *Parser) ParseError!ast.NamedArg {
        if (self.tokens.current.tag == .comma or self.tokens.current.tag == .r_paren) {
            const val = try self.b.undefNode(self.tokens.current.loc);
            return .{ .name = "", .value = val, .modifier = null };
        }

        var arg_name: []const u8 = "";
        if (self.tokens.current.tag == .ident and self.tokens.peekTag() == .equal) {
            arg_name = self.tokens.current.lexeme;
            self.advance();
            self.advance(); // consume equal
        }

        const val = try self.parseExpression(.none);
        return .{ .name = arg_name, .value = val, .modifier = null };
    }

    fn parseParenArgs(self: *Parser) ParseError![]const ast.NamedArg {
        _ = try self.expect(.l_paren);
        const args = try self.parseCommaSeparated(ast.NamedArg, parseNamedArg, .r_paren);
        _ = try self.expect(.r_paren);
        return args;
    }

    fn parseParam(self: *Parser) ParseError!ast.Param {
        if (self.tokens.current.tag != .ident) return ParseError.UnexpectedToken;
        const param_name = self.tokens.current.lexeme;
        self.advance();

        var default_val: ?*Node = null;
        if (self.tokens.current.tag == .equal) {
            self.advance();
            default_val = try self.parseExpression(.none);
        }

        return .{ .name = param_name, .default_value = default_val, .modifier = null };
    }

    fn parseParenParams(self: *Parser) ParseError![]const ast.Param {
        _ = try self.expect(.l_paren);
        const params = try self.parseCommaSeparated(ast.Param, parseParam, .r_paren);
        _ = try self.expect(.r_paren);
        return params;
    }

    // --- EXPRESSION PARSERS ---
    pub fn parseExpression(self: *Parser, precedence: Precedence) ParseError!*Node {
        const start_tok = self.tokens.current;
        var left: *Node = undefined;
        self.skipIgnored();

        switch (start_tok.tag) {
            .number => {
                self.advance();
                left = try self.b.number(start_tok.lexeme, start_tok.loc);
            },
            .string => {
                self.advance();
                if (self.tokens.current.tag == .string) {
                    var concat_str: std.ArrayListUnmanaged(u8) = .empty;
                    errdefer concat_str.deinit(self.allocator);
                    try concat_str.appendSlice(self.allocator, start_tok.lexeme);

                    while (self.tokens.current.tag == .string) {
                        try concat_str.appendSlice(self.allocator, self.tokens.current.lexeme);
                        self.advance();
                    }
                    left = try self.createNode(.{ .string = try concat_str.toOwnedSlice(self.allocator) }, start_tok.loc);
                } else {
                    left = try self.createNode(.{ .string = start_tok.lexeme }, start_tok.loc);
                }
            },
            .keyword_true => {
                self.advance();
                left = try self.b.booleanNode(true, start_tok.loc);
            },
            .keyword_false => {
                self.advance();
                left = try self.b.booleanNode(false, start_tok.loc);
            },
            .keyword_undef => {
                self.advance();
                left = try self.b.undefNode(start_tok.loc);
            },
            .ident => left = try self.parseIdentifierOrCall(),
            .l_paren => left = try self.parseGroupedExpression(),
            .l_bracket => left = try self.parseArrayOrRangeOrComprehension(),
            .plus, .minus, .bang => left = try self.parseUnary(),
            .keyword_let => left = try self.parseLetExpression(),
            .keyword_if => left = try self.parseIfExpression(),
            .keyword_assert, .keyword_echo => left = try self.parseAssertOrEchoExpr(),
            .keyword_function => {
                const func_tok = self.tokens.current;
                self.advance();
                const params = try self.parseParenParams();
                const body = try self.parseExpression(.none);
                left = try self.createNode(.{ .lambda_expr = .{ .params = params, .body = body } }, func_tok.loc);
            },
            else => {
                self.reportError(start_tok.loc, "Invalid expression starting with '{s}'", .{start_tok.lexeme});
                return ParseError.InvalidExpression;
            },
        }

        while (true) {
            self.skipIgnored();
            if (@intFromEnum(precedence) >= @intFromEnum(getInfixPrecedence(self.tokens.current.tag))) break;

            const op_tok = self.tokens.current;
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

        while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const val_expr = try self.parseExpression(.none);
            const assign_node = try self.createNode(.{ .assignment = .{ .name = var_tok.lexeme, .op = null, .value = val_expr } }, var_tok.loc);
            try assignments.append(self.allocator, assign_node);
            if (self.tokens.current.tag == .comma) self.advance() else break;
        }
        _ = try self.expect(.r_paren);

        const yield_expr = try self.parseExpression(.none);
        return self.createNode(.{ .let_expr = .{ .assignments = try assignments.toOwnedSlice(self.allocator), .yield_expr = yield_expr } }, start_tok.loc);
    }

    fn parseIfExpression(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_if);
        _ = try self.expect(.l_paren);
        const cond = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);

        const then_branch = try self.parseExpression(.none);
        var else_branch: ?*Node = null;
        if (self.tokens.current.tag == .keyword_else) {
            self.advance();
            else_branch = try self.parseExpression(.none);
        }

        return self.createNode(.{ .if_stmt = .{ .condition = cond, .then_branch = then_branch, .else_branch = else_branch, .is_unless = false } }, start_tok.loc);
    }

    fn parseAssertOrEchoExpr(self: *Parser) ParseError!*Node {
        const start_tok = self.tokens.current;
        const is_assert = (start_tok.tag == .keyword_assert);
        self.advance();

        const args = try self.parseParenArgs();
        const yield_expr = try self.parseExpression(.none);

        if (is_assert) {
            return self.createNode(.{ .assert_expr = .{ .args = args, .yield_expr = yield_expr } }, start_tok.loc);
        } else {
            return self.createNode(.{ .echo_expr = .{ .args = args, .yield_expr = yield_expr } }, start_tok.loc);
        }
    }

    fn parseIdentifierOrCall(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.ident);
        if (self.tokens.current.tag == .l_paren) {
            const args = try self.parseParenArgs();
            return self.createNode(.{
                .method_call = .{
                    .receiver = null,
                    .method_name = tok.lexeme,
                    .args = args,
                    .block = null,
                    .is_safe = false,
                },
            }, tok.loc);
        }
        return self.b.identifierNode(tok.lexeme, tok.loc);
    }

    fn parseGroupedExpression(self: *Parser) ParseError!*Node {
        _ = try self.expect(.l_paren);
        const expr = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);
        return expr;
    }

    fn parseArrayOrRangeOrComprehension(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.l_bracket);
        while (self.tokens.current.tag == .comment or self.tokens.current.tag == .block_comment) self.advance();

        if (self.tokens.current.tag == .keyword_for or self.tokens.current.tag == .keyword_let or self.tokens.current.tag == .keyword_if or self.tokens.current.tag == .keyword_intersection_for) {
            const root = try self.parseComprehensionElement();
            while (self.tokens.current.tag == .comment or self.tokens.current.tag == .block_comment) self.advance();
            _ = try self.expect(.r_bracket);
            return self.createNode(.{
                .comprehension = .{
                    .clauses = &.{}, // Flat clauses are no longer needed
                    .yield_expr = root,
                },
            }, start_tok.loc);
        }

        var elements: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer elements.deinit(self.allocator);

        if (self.tokens.current.tag == .r_bracket) {
            self.advance();
            return self.createNode(.{ .array_literal = &.{} }, start_tok.loc);
        }

        var is_each = false;
        if (self.tokens.current.tag == .keyword_each) {
            is_each = true;
            self.advance();
        }

        var first: *Node = undefined;
        if (self.tokens.current.tag == .comma or self.tokens.current.tag == .r_bracket) {
            first = try self.b.undefNode(self.tokens.current.loc);
        } else {
            first = try self.parseExpression(.none);
        }

        if (is_each) {
            first = try self.createNode(.{ .each_expr = first }, start_tok.loc);
        }

        if (self.tokens.current.tag == .colon) {
            if (is_each) return ParseError.InvalidExpression; // Range cannot start with `each`
            self.advance();
            const second = try self.parseExpression(.none);

            if (self.tokens.current.tag == .colon) {
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
        if (self.tokens.current.tag == .comma) self.advance();

        while (self.tokens.current.tag != .r_bracket and self.tokens.current.tag != .eof) {
            while (self.tokens.current.tag == .comment or self.tokens.current.tag == .block_comment) self.advance();
            if (self.tokens.current.tag == .r_bracket) break;

            is_each = false;
            if (self.tokens.current.tag == .keyword_each) {
                is_each = true;
                self.advance();
            }

            var elem: *Node = undefined;
            if (self.tokens.current.tag == .comma or self.tokens.current.tag == .r_bracket) {
                elem = try self.b.undefNode(self.tokens.current.loc);
            } else {
                elem = try self.parseExpression(.none);
            }

            if (is_each) {
                elem = try self.createNode(.{ .each_expr = elem }, start_tok.loc);
            }
            try elements.append(self.allocator, elem);
            if (self.tokens.current.tag == .comma) self.advance() else break;
        }

        _ = try self.expect(.r_bracket);
        const elements_slice = try elements.toOwnedSlice(self.allocator);
        return self.createNode(.{ .array_literal = elements_slice }, start_tok.loc);
    }

    fn parseUnary(self: *Parser) ParseError!*Node {
        const tok = self.tokens.current;
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
        const tok = self.tokens.current;
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
