const std = @import("std");
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const Tag = lexer_mod.Tag;
const Token = lexer_mod.Token;
const ast = @import("../../core/ast.zig");
const common_token = @import("../../core/token.zig");
const Node = ast.Node;
const common_errors = @import("../../core/errors.zig");
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

    pub fn deinit(self: *Parser) void {
        self.b.deinit();
        self.diagnostics.deinit();
    }

    inline fn advance(self: *Parser) void {
        self.tokens.advance();
    }

    pub fn reportError(self: *Parser, loc: ast.Location, comptime fmt: []const u8, args: anytype) void {
        self.diagnostics.add(loc, fmt, args);
    }

    pub fn synchronize(self: *Parser) void {
        self.advance();
        while (self.tokens.current.tag != .eof) {
            if (self.tokens.previous.tag == .semicolon) return;
            switch (self.tokens.current.tag) {
                .keyword_module, .keyword_function, .keyword_include, .keyword_use, .keyword_if, .keyword_for, .keyword_intersection_for, .keyword_let, .keyword_assert, .keyword_echo => return,
                else => self.advance(),
            }
        }
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

    pub fn parseProgram(self: *Parser) ParseError!ast.NodeIndex {
        return self.parseBlock();
    }

    pub fn parseStatement(self: *Parser) ParseError!ast.NodeIndex {
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

    fn parseScopedBlock(self: *Parser) ParseError!ast.NodeIndex {
        _ = try self.expect(.l_brace);
        const block_node = try self.parseBlock();
        _ = try self.expect(.r_brace);
        return block_node;
    }

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
            self.skipIgnored();
            if (self.tokens.current.tag == .comma) {
                self.advance();
                self.skipIgnored();
            } else {
                break;
            }
        }
        self.skipIgnored();
        return items.toOwnedSlice(self.allocator);
    }

    pub fn parseBlock(self: *Parser) ParseError!ast.NodeIndex {
        const start_loc = self.tokens.current.loc;
        var stmts: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer stmts.deinit(self.allocator);

        while (self.tokens.current.tag != .eof and self.tokens.current.tag != .r_brace) {
            self.skipIgnored();
            if (self.tokens.current.tag == .semicolon) {
                self.advance();
                continue;
            }
            if (self.tokens.current.tag == .r_brace) break;
            if (self.parseStatement()) |parsed_stmt| {
                try stmts.append(self.allocator, parsed_stmt);
            } else |err| {
                if (err == ParseError.OutOfMemory) return err;
                self.synchronize();
            }
        }

        return try self.b.block(&.{}, stmts.items, start_loc);
    }

    fn parseIncludeOrUse(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = self.tokens.current;
        self.advance();

        var path_str: ast.StringId = .none;

        if (self.tokens.current.tag == .less) {
            self.advance();
            var path_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer path_buf.deinit(self.allocator);

            while (self.tokens.current.tag != .greater and self.tokens.current.tag != .eof) {
                try path_buf.appendSlice(self.allocator, self.tokens.current.lexeme);
                self.advance();
            }
            _ = try self.expect(.greater);
            path_str = try self.b.intern(path_buf.items);
        } else if (self.tokens.current.tag == .string) {
            path_str = try self.b.intern(self.tokens.current.lexeme);
            self.advance();
        } else {
            return ParseError.UnexpectedToken;
        }

        return self.createNode(.{
            .import_stmt = .{ .path = path_str, .symbols = try self.b.addStringLists(&.{}), .attributes = .none },
        }, start_tok.loc);
    }

    fn parseLetStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_let);
        _ = try self.expect(.l_paren);

        var assignments: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer assignments.deinit(self.allocator);

        while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const val_expr = try self.parseExpression(.none);
            const assign_node = try self.b.assignment(try self.b.intern(var_tok.lexeme), null, val_expr, var_tok.loc);
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

        var stmts_list: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        try stmts_list.appendSlice(self.allocator, assignments.items);
        try stmts_list.append(self.allocator, body);

        return try self.b.block(&.{}, stmts_list.items, start_tok.loc);
    }

    fn parseModifierCall(self: *Parser) ParseError!ast.NodeIndex {
        const mod_tok = self.tokens.current;
        self.advance();
        const child = try self.parseStatement();

        const mod_name = switch (mod_tok.lexeme[0]) {
            '!' => "root",
            '#' => "debug",
            '%' => "background",
            '*' => "disable",
            else => "modifier",
        };
        const interned_name = try self.b.intern(mod_name);

        const stmts_arr = [_]ast.NodeIndex{child};
        const child_block = try self.b.block(&.{}, &stmts_arr, self.b.tree.nodes.items[@intFromEnum(child)].loc);

        return self.createNode(.{
            .method_call = .{
                .receiver = .none,
                .method_name = interned_name,
                .args = try self.b.addNamedArgs(&.{}),
                .block = child_block,
                .is_safe = false,
            },
        }, mod_tok.loc);
    }

    fn parseForLoop(self: *Parser) ParseError!ast.NodeIndex {
        const is_intersection = (self.tokens.current.tag == .keyword_intersection_for);
        const start_tok = self.tokens.current;
        self.advance();
        _ = try self.expect(.l_paren);

        var init_assignments: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer init_assignments.deinit(self.allocator);
        var standard_bindings: std.ArrayListUnmanaged(ast.ForBinding) = .empty;
        errdefer standard_bindings.deinit(self.allocator);

        while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .semicolon and self.tokens.current.tag != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const val_expr = try self.parseExpression(.none);
            const interned_name = try self.b.intern(var_tok.lexeme);

            const assign_node = try self.b.assignment(interned_name, null, val_expr, var_tok.loc);
            try init_assignments.append(self.allocator, assign_node);
            try standard_bindings.append(self.allocator, .{ .name = interned_name, .range = val_expr });

            if (self.tokens.current.tag == .comma) self.advance() else break;
        }

        if (self.tokens.current.tag == .semicolon) {
            self.advance();
            var condition: ast.NodeIndex = .none;
            if (self.tokens.current.tag != .semicolon) condition = try self.parseExpression(.none);
            _ = try self.expect(.semicolon);

            var updates: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
            errdefer updates.deinit(self.allocator);

            while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .eof) {
                const target_tok = try self.expect(.ident);
                _ = try self.expect(.equal);
                const val = try self.parseExpression(.none);
                const interned_name = try self.b.intern(target_tok.lexeme);
                try updates.append(self.allocator, try self.b.assignment(interned_name, null, val, target_tok.loc));
                if (self.tokens.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);

            const body = if (self.tokens.current.tag == .l_brace) blk: {
                self.advance();
                const b = try self.parseBlock();
                _ = try self.expect(.r_brace);
                break :blk b;
            } else try self.parseStatement();

            var while_stmts = std.ArrayListUnmanaged(ast.NodeIndex).empty;
            try while_stmts.append(self.allocator, body);
            try while_stmts.appendSlice(self.allocator, updates.items);
            const while_body = try self.b.block(&.{}, while_stmts.items, self.b.tree.nodes.items[@intFromEnum(body)].loc);

            const true_cond = try self.b.booleanNode(true, start_tok.loc);
            const while_node = try self.b.whileStmt(if (condition == .none) true_cond else condition, while_body, false, start_tok.loc);

            var outer_stmts = std.ArrayListUnmanaged(ast.NodeIndex).empty;
            try outer_stmts.appendSlice(self.allocator, init_assignments.items);
            try outer_stmts.append(self.allocator, while_node);

            return try self.b.block(&.{}, outer_stmts.items, start_tok.loc);
        } else {
            _ = try self.expect(.r_paren);

            const body = if (self.tokens.current.tag == .l_brace) blk: {
                self.advance();
                const b = try self.parseBlock();
                _ = try self.expect(.r_brace);
                break :blk b;
            } else try self.parseStatement();

            return self.createNode(.{
                .for_stmt = .{
                    .bindings = try self.b.addForBindings(standard_bindings.items),
                    .body = body,
                    .is_intersection = is_intersection,
                },
            }, start_tok.loc);
        }
    }

    fn parseComprehensionElement(self: *Parser) ParseError!ast.NodeIndex {
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
                try bindings.append(self.allocator, .{ .name = try self.b.intern(var_tok.lexeme), .range = range_node });
                if (self.tokens.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);

            const body = try self.parseComprehensionElement();

            return self.createNode(.{ .for_stmt = .{ .bindings = try self.b.addForBindings(bindings.items), .body = body, .is_intersection = (start_tok.tag == .keyword_intersection_for) } }, start_tok.loc);
        } else if (self.tokens.current.tag == .keyword_let) {
            const start_tok = try self.expect(.keyword_let);
            _ = try self.expect(.l_paren);

            var assignments: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
            errdefer assignments.deinit(self.allocator);

            while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .eof) {
                const var_tok = try self.expect(.ident);
                _ = try self.expect(.equal);
                const val_expr = try self.parseExpression(.none);
                const assign_node = try self.b.assignment(try self.b.intern(var_tok.lexeme), null, val_expr, var_tok.loc);
                try assignments.append(self.allocator, assign_node);
                if (self.tokens.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);

            const yield_expr = try self.parseComprehensionElement();

            var stmts_list = std.ArrayListUnmanaged(ast.NodeIndex).empty;
            try stmts_list.appendSlice(self.allocator, assignments.items);
            try stmts_list.append(self.allocator, yield_expr);

            return try self.b.block(&.{}, stmts_list.items, start_tok.loc);
        } else if (self.tokens.current.tag == .keyword_if) {
            const start_tok = try self.expect(.keyword_if);
            _ = try self.expect(.l_paren);
            const cond = try self.parseExpression(.none);
            _ = try self.expect(.r_paren);

            const then_branch = try self.parseComprehensionElement();
            var else_branch: ast.NodeIndex = .none;
            if (self.tokens.current.tag == .keyword_else) {
                self.advance();
                else_branch = try self.parseComprehensionElement();
            }

            return self.b.ifStmt(cond, then_branch, else_branch, false, start_tok.loc);
        } else {
            var is_each = false;
            if (self.tokens.current.tag == .keyword_each) {
                is_each = true;
                self.advance();
            }
            var expr = try self.parseExpression(.none);
            if (is_each) {
                expr = try self.createNode(.{ .each_expr = expr }, self.b.tree.nodes.items[@intFromEnum(expr)].loc);
            }
            return expr;
        }
    }

    fn parseInstantiationOrAssignment(self: *Parser) ParseError!ast.NodeIndex {
        const target_tok = self.tokens.current;
        if (target_tok.tag == .ident and self.tokens.peekTag() == .equal) {
            self.advance();
            self.advance();
            const val = try self.parseExpression(.none);
            if (self.tokens.current.tag == .semicolon) {
                self.advance();
            }
            return self.b.assignment(try self.b.intern(target_tok.lexeme), null, val, target_tok.loc);
        }

        const expr = try self.parseExpression(.none);
        
        if (self.b.tree.nodes.items[@intFromEnum(expr)].kind == .method_call) {
            if (self.tokens.current.tag == .l_brace) {
                self.advance();
                const children_block = try self.parseBlock();
                _ = try self.expect(.r_brace);
                self.b.tree.nodes.items[@intFromEnum(expr)].kind.method_call.block = children_block;
            } else if (self.tokens.current.tag != .semicolon and self.tokens.current.tag != .r_brace and self.tokens.current.tag != .eof) {
                const child_stmt = try self.parseStatement();
                const stmts_arr = [_]ast.NodeIndex{child_stmt};
                const child_block = try self.b.block(&.{}, &stmts_arr, self.b.tree.nodes.items[@intFromEnum(child_stmt)].loc);
                self.b.tree.nodes.items[@intFromEnum(expr)].kind.method_call.block = child_block;
            }
        }
        if (self.tokens.current.tag == .semicolon) {
            self.advance();
        }
        return expr;
    }

    pub fn parseExpression(self: *Parser, precedence: Precedence) ParseError!ast.NodeIndex {
        const start_tok = self.tokens.current;
        var left: ast.NodeIndex = undefined;
        self.skipIgnored();

        switch (start_tok.tag) {
            .number => {
                self.advance();
                left = try self.b.number(start_tok.lexeme, start_tok.loc);
            },
            .string => {
                self.advance();
                self.skipIgnored();

                if (self.tokens.current.tag == .string) {
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer buf.deinit(self.allocator);

                    try buf.appendSlice(self.allocator, start_tok.lexeme);
                    while (self.tokens.current.tag == .string) {
                        try buf.appendSlice(self.allocator, self.tokens.current.lexeme);
                        self.advance();
                        self.skipIgnored();
                    }
                    left = try self.b.stringNode(buf.items, start_tok.loc);
                } else {
                    left = try self.b.stringNode(start_tok.lexeme, start_tok.loc);
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
                left = try self.createNode(.{ .lambda_expr = .{ .params = try self.b.addParams(params), .body = body } }, func_tok.loc);
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

    fn parseLetExpression(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_let);
        _ = try self.expect(.l_paren);

        var assignments: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer assignments.deinit(self.allocator);

        while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const val_expr = try self.parseExpression(.none);
            const assign_node = try self.b.assignment(try self.b.intern(var_tok.lexeme), null, val_expr, var_tok.loc);
            try assignments.append(self.allocator, assign_node);
            if (self.tokens.current.tag == .comma) self.advance() else break;
        }
        _ = try self.expect(.r_paren);

        const yield_expr = try self.parseExpression(.none);

        var stmts = std.ArrayListUnmanaged(ast.NodeIndex).empty;
        try stmts.appendSlice(self.allocator, assignments.items);
        try stmts.append(self.allocator, yield_expr);

        return try self.b.block(&.{}, stmts.items, start_tok.loc);
    }

    fn parseAssertOrEchoExpr(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = self.tokens.current;
        self.advance();
        const args = try self.parseParenArgs();
        const yield_expr = try self.parseExpression(.none);

        const call_node = try self.createNode(.{
            .method_call = .{
                .receiver = .none,
                .method_name = try self.b.intern(start_tok.lexeme),
                .args = try self.b.addNamedArgs(args),
                .block = .none,
                .is_safe = false,
            },
        }, start_tok.loc);

        var stmts = try self.allocator.alloc(ast.NodeIndex, 2);
        stmts[0] = call_node;
        stmts[1] = yield_expr;

        return try self.b.block(&.{}, stmts, start_tok.loc);
    }

    fn parseArrayOrRangeOrComprehension(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.l_bracket);

        while (self.tokens.current.tag == .comment or self.tokens.current.tag == .block_comment) self.advance();

        if (self.tokens.current.tag == .keyword_for or self.tokens.current.tag == .keyword_let or self.tokens.current.tag == .keyword_if or self.tokens.current.tag == .keyword_intersection_for) {
            const root = try self.parseComprehensionElement();
            while (self.tokens.current.tag == .comment or self.tokens.current.tag == .block_comment) self.advance();
            _ = try self.expect(.r_bracket);

            var arr = try self.allocator.alloc(ast.NodeIndex, 1);
            arr[0] = root;
            return self.createNode(.{ .array_literal = try self.b.addNodes(arr) }, start_tok.loc);
        }

        var elements: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer elements.deinit(self.allocator);

        if (self.tokens.current.tag == .r_bracket) {
            self.advance();
            return self.createNode(.{ .array_literal = try self.b.addNodes(&.{}) }, start_tok.loc);
        }

        var is_each = false;
        if (self.tokens.current.tag == .keyword_each) {
            is_each = true;
            self.advance();
        }

        var first: ast.NodeIndex = undefined;
        if (self.tokens.current.tag == .comma or self.tokens.current.tag == .r_bracket) {
            first = try self.b.undefNode(self.tokens.current.loc);
        } else {
            first = try self.parseExpression(.none);
        }

        if (is_each) {
            first = try self.createNode(.{ .each_expr = first }, start_tok.loc);
        }

        if (self.tokens.current.tag == .colon) {
            if (is_each) return ParseError.InvalidExpression;
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
                        .is_exclusive = false,
                    },
                }, start_tok.loc);
            }
            _ = try self.expect(.r_bracket);
            return self.createNode(.{
                .range = .{
                    .start = first,
                    .step = .none,
                    .end = second,
                    .is_exclusive = false,
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

            var elem: ast.NodeIndex = undefined;
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
        return self.createNode(.{ .array_literal = try self.b.addNodes(elements.items) }, start_tok.loc);
    }

    fn parseNamedArg(self: *Parser) ParseError!ast.NamedArg {
        if (self.tokens.current.tag == .comma or self.tokens.current.tag == .r_paren) {
            const val = try self.b.undefNode(self.tokens.current.loc);
            return .{ .name = .none, .value = val, .modifier = null };
        }

        var arg_name: ast.StringId = .none;
        if (self.tokens.current.tag == .ident and self.tokens.peekTag() == .equal) {
            arg_name = try self.b.intern(self.tokens.current.lexeme);
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
        const param_name = try self.b.intern(self.tokens.current.lexeme);
        self.advance();

        var default_val: ast.NodeIndex = .none;
        if (self.tokens.current.tag == .equal) {
            self.advance();
            default_val = try self.parseExpression(.none);
        }

        return .{ .name = param_name, .default_value = default_val, .modifier = null, .is_keyword = false };
    }

    fn parseParenParams(self: *Parser) ParseError![]const ast.Param {
        _ = try self.expect(.l_paren);
        const params = try self.parseCommaSeparated(ast.Param, parseParam, .r_paren);
        _ = try self.expect(.r_paren);
        return params;
    }

    fn parseIfExpression(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_if);
        _ = try self.expect(.l_paren);
        const cond = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);
        const then_branch = try self.parseExpression(.none);

        var else_branch: ast.NodeIndex = .none;
        if (self.tokens.current.tag == .keyword_else) {
            self.advance();
            else_branch = try self.parseExpression(.none);
        }

        return self.b.ifStmt(cond, then_branch, else_branch, false, start_tok.loc);
    }

    fn parseModuleDecl(self: *Parser) ParseError!ast.NodeIndex {
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
            .def_stmt = .{
                .name = try self.b.intern(name_tok.lexeme),
                .params = try self.b.addParams(params),
                .body = body,
                .is_class_method = false,
            },
        }, start_tok.loc);
    }

    fn parseFunctionDecl(self: *Parser) ParseError!ast.NodeIndex {
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
                .name = try self.b.intern(name_tok.lexeme),
                .params = try self.b.addParams(params),
                .body = body_expr,
                .is_class_method = false,
            },
        }, start_tok.loc);
    }

    fn parseIfStatement(self: *Parser) ParseError!ast.NodeIndex {
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

        var else_branch: ast.NodeIndex = .none;
        if (self.tokens.current.tag == .keyword_else) {
            self.advance();
            else_branch = if (self.tokens.current.tag == .l_brace) blk: {
                self.advance();
                const b = try self.parseBlock();
                _ = try self.expect(.r_brace);
                break :blk b;
            } else try self.parseStatement();
        }

        return self.b.ifStmt(cond, then_branch, else_branch, false, start_tok.loc);
    }

    fn parseAssertOrEcho(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = self.tokens.current;
        self.advance();
        const args = try self.parseParenArgs();

        const call_node = try self.createNode(.{
            .method_call = .{
                .receiver = .none,
                .method_name = try self.b.intern(start_tok.lexeme),
                .args = try self.b.addNamedArgs(args),
                .block = .none,
                .is_safe = false,
            },
        }, start_tok.loc);

        if (self.tokens.current.tag == .semicolon) {
            self.advance();
            return call_node;
        } else if (self.tokens.current.tag == .l_brace) {
            self.advance();
            const child_block = try self.parseBlock();
            _ = try self.expect(.r_brace);
            self.b.tree.nodes.items[@intFromEnum(call_node)].kind.method_call.block = child_block;
            return call_node;
        } else if (self.tokens.current.tag != .r_brace and self.tokens.current.tag != .eof) {
            const child_stmt = try self.parseStatement();
            const stmts_arr = [_]ast.NodeIndex{child_stmt};
            const block = try self.b.block(&.{}, &stmts_arr, self.b.tree.nodes.items[@intFromEnum(child_stmt)].loc);
            self.b.tree.nodes.items[@intFromEnum(call_node)].kind.method_call.block = block;
            return call_node;
        }
        return call_node;
    }

    fn parseIdentifierOrCall(self: *Parser) ParseError!ast.NodeIndex {
        const tok = try self.expect(.ident);
        if (self.tokens.current.tag == .l_paren) {
            const args = try self.parseParenArgs();
            return self.createNode(.{
                .method_call = .{
                    .receiver = .none,
                    .method_name = try self.b.intern(tok.lexeme),
                    .args = try self.b.addNamedArgs(args),
                    .block = .none,
                    .is_safe = false,
                },
            }, tok.loc);
        }
        return self.b.identifierNode(tok.lexeme, tok.loc);
    }

    fn parseGroupedExpression(self: *Parser) ParseError!ast.NodeIndex {
        _ = try self.expect(.l_paren);
        const expr = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);
        return expr;
    }

    fn parseUnary(self: *Parser) ParseError!ast.NodeIndex {
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

    fn parseBinary(self: *Parser, left: ast.NodeIndex) ParseError!ast.NodeIndex {
        const tok = self.tokens.current;
        self.advance();
        const op = tagToBinaryOp(tok.tag) orelse return ParseError.InvalidExpression;
        const right = try self.parseExpression(getInfixPrecedence(tok.tag));
        return self.b.binary(op, left, right, self.b.tree.nodes.items[@intFromEnum(left)].loc);
    }

    fn parseTernary(self: *Parser, condition: ast.NodeIndex) ParseError!ast.NodeIndex {
        _ = try self.expect(.question);
        const then_branch = try self.parseExpression(.none);
        _ = try self.expect(.colon);
        const else_branch = try self.parseExpression(.none);
        return self.createNode(.{
            .ternary_op = .{
                .condition = condition,
                .then_branch = then_branch,
                .else_branch = else_branch,
            },
        }, self.b.tree.nodes.items[@intFromEnum(condition)].loc);
    }

    fn parseIndexAccess(self: *Parser, target: ast.NodeIndex) ParseError!ast.NodeIndex {
        _ = try self.expect(.l_bracket);
        const index = try self.parseExpression(.none);
        _ = try self.expect(.r_bracket);
        return self.createNode(.{
            .index_access = .{
                .target = target,
                .index = index,
            },
        }, self.b.tree.nodes.items[@intFromEnum(target)].loc);
    }

    fn createNode(self: *Parser, kind: ast.NodeKind, loc: ast.Location) ParseError!ast.NodeIndex {
        return try self.b.createNode(kind, loc);
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
