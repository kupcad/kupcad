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
    tokens: common_token.TokenList(Tag),
    source: []const u8,
    tok_idx: u24,
    allocator: std.mem.Allocator,
    b: ast.Builder,
    diagnostics: Diagnostics,

    pub fn init(tokens: common_token.TokenList(Tag), source: []const u8, allocator: std.mem.Allocator) Parser {
        return Parser{
            .tokens = tokens,
            .source = source,
            .tok_idx = 0,
            .allocator = allocator,
            .b = ast.Builder.init(allocator),
            .diagnostics = Diagnostics.init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.b.deinit();
        self.diagnostics.deinit();
    }

    // --- O(1) Lookahead Helpers ---

    inline fn advance(self: *Parser) void {
        if (self.tok_idx < self.tokens.tags.len - 1) {
            self.tok_idx += 1;
        }
    }

    inline fn tag(self: *const Parser, lookahead: u24) Tag {
        const idx = self.tok_idx + lookahead;
        if (idx >= self.tokens.tags.len) return .eof;
        return self.tokens.tags[idx];
    }

    inline fn lexeme(self: *const Parser, lookahead: u24) []const u8 {
        const idx = self.tok_idx + lookahead;
        return self.tokens.lexeme(self.source, idx);
    }

    fn getLoc(self: *const Parser, idx: u24) ast.Location {
        if (idx >= self.tokens.starts.len) return .{ .line = 0, .col = 0, .offset = 0, .length = 0, .file_id = 0 };
        return .{
            .line = 0,
            .col = 0,
            .offset = self.tokens.starts[idx],
            .length = self.tokens.lengths[idx],
            .file_id = 0,
        };
    }

    pub fn reportError(self: *Parser, loc: ast.Location, comptime fmt: []const u8, args: anytype) void {
        self.diagnostics.add(loc, fmt, args);
    }

    pub fn synchronize(self: *Parser) void {
        self.advance();
        while (self.tag(0) != .eof) {
            if (self.tok_idx > 0 and self.tokens.tags[self.tok_idx - 1] == .semicolon) return;
            switch (self.tag(0)) {
                .keyword_module, .keyword_function, .keyword_include, .keyword_use, .keyword_if, .keyword_for, .keyword_intersection_for, .keyword_let, .keyword_assert, .keyword_echo => return,
                else => self.advance(),
            }
        }
    }

    fn expect(self: *Parser, expected: Tag) ParseError!u24 {
        if (self.tag(0) == expected) {
            const captured_idx = self.tok_idx;
            self.advance();
            return captured_idx;
        }
        self.reportError(self.getLoc(self.tok_idx), "Expected '{s}', but found '{s}'", .{ @tagName(expected), self.lexeme(0) });
        return ParseError.UnexpectedToken;
    }

    fn skipIgnored(self: *Parser) void {
        while (self.tag(0) == .comment or self.tag(0) == .block_comment) {
            self.advance();
        }
    }

    pub fn parseProgram(self: *Parser) ParseError!ast.NodeIndex {
        return self.parseBlock();
    }

    pub fn parseStatement(self: *Parser) ParseError!ast.NodeIndex {
        self.skipIgnored();
        return switch (self.tag(0)) {
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
        while (self.tag(0) != end_tag and self.tag(0) != .eof) {
            self.skipIgnored();
            if (self.tag(0) == end_tag) break;
            try items.append(self.allocator, try parseItemFn(self));
            self.skipIgnored();
            if (self.tag(0) == .comma) {
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
        const start_tok = self.tok_idx;
        var stmts: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer stmts.deinit(self.allocator);
        while (self.tag(0) != .eof and self.tag(0) != .r_brace) {
            self.skipIgnored();
            if (self.tag(0) == .semicolon) {
                self.advance();
                continue;
            }
            if (self.tag(0) == .r_brace) break;
            if (self.parseStatement()) |parsed_stmt| {
                try stmts.append(self.allocator, parsed_stmt);
            } else |err| {
                if (err == ParseError.OutOfMemory) return err;
                self.synchronize();
            }
        }
        return try self.b.block(&.{}, stmts.items, start_tok);
    }

    fn parseIncludeOrUse(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = self.tok_idx;
        self.advance();
        var path_str: ast.StringId = .none;
        if (self.tag(0) == .less) {
            self.advance();
            var path_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer path_buf.deinit(self.allocator);
            while (self.tag(0) != .greater and self.tag(0) != .eof) {
                try path_buf.appendSlice(self.allocator, self.lexeme(0));
                self.advance();
            }
            _ = try self.expect(.greater);
            path_str = try self.b.intern(path_buf.items);
        } else if (self.tag(0) == .string) {
            path_str = try self.b.intern(self.lexeme(0));
            self.advance();
        } else {
            return ParseError.UnexpectedToken;
        }
        return self.b.importStmt(try self.b.addStringLists(&.{}), path_str, .none, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseLetStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_let);
        _ = try self.expect(.l_paren);
        var assignments: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer assignments.deinit(self.allocator);
        while (self.tag(0) != .r_paren and self.tag(0) != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const val_expr = try self.parseExpression(.none);
            const assign_node = try self.b.assignment(try self.b.intern(self.tokens.lexeme(self.source, var_tok)), null, val_expr, var_tok);
            try assignments.append(self.allocator, assign_node);
            if (self.tag(0) == .comma) {
                self.advance();
            } else {
                break;
            }
        }
        _ = try self.expect(.r_paren);
        const body = if (self.tag(0) == .l_brace) blk: {
            self.advance();
            const b = try self.parseBlock();
            _ = try self.expect(.r_brace);
            break :blk b;
        } else try self.parseStatement();
        var stmts_list: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        try stmts_list.appendSlice(self.allocator, assignments.items);
        try stmts_list.append(self.allocator, body);
        return try self.b.block(&.{}, stmts_list.items, start_tok);
    }

    fn parseModifierCall(self: *Parser) ParseError!ast.NodeIndex {
        const mod_tok = self.tok_idx;
        const mod_lexeme = self.lexeme(0);
        self.advance();
        const child = try self.parseStatement();
        const mod_name = switch (mod_lexeme[0]) {
            '!' => "root",
            '#' => "debug",
            '%' => "background",
            '*' => "disable",
            else => "modifier",
        };
        const interned_name = try self.b.intern(mod_name);
        const stmts_arr = [_]ast.NodeIndex{child};

        const child_loc = self.b.tree.getNode(child).?.main_token;
        const child_block = try self.b.block(&.{}, &stmts_arr, child_loc);
        return self.b.methodCall(.none, interned_name, try self.b.addNamedArgs(&.{}), child_block, false, mod_tok) catch ParseError.OutOfMemory;
    }

    fn parseForLoop(self: *Parser) ParseError!ast.NodeIndex {
        const is_intersection = (self.tag(0) == .keyword_intersection_for);
        const start_tok = self.tok_idx;
        self.advance();
        _ = try self.expect(.l_paren);
        var init_assignments: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer init_assignments.deinit(self.allocator);
        var standard_bindings: std.ArrayListUnmanaged(ast.ForBinding) = .empty;
        errdefer standard_bindings.deinit(self.allocator);
        while (self.tag(0) != .r_paren and self.tag(0) != .semicolon and self.tag(0) != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const val_expr = try self.parseExpression(.none);
            const interned_name = try self.b.intern(self.tokens.lexeme(self.source, var_tok));
            const assign_node = try self.b.assignment(interned_name, null, val_expr, var_tok);
            try init_assignments.append(self.allocator, assign_node);
            try standard_bindings.append(self.allocator, .{ .name = interned_name, .range = val_expr });
            if (self.tag(0) == .comma) self.advance() else break;
        }
        if (self.tag(0) == .semicolon) {
            self.advance();
            var condition: ast.NodeIndex = .none;
            if (self.tag(0) != .semicolon) condition = try self.parseExpression(.none);
            _ = try self.expect(.semicolon);
            var updates: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
            errdefer updates.deinit(self.allocator);
            while (self.tag(0) != .r_paren and self.tag(0) != .eof) {
                const target_tok = try self.expect(.ident);
                _ = try self.expect(.equal);
                const val = try self.parseExpression(.none);
                const interned_name = try self.b.intern(self.tokens.lexeme(self.source, target_tok));
                try updates.append(self.allocator, try self.b.assignment(interned_name, null, val, target_tok));
                if (self.tag(0) == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
            const body = if (self.tag(0) == .l_brace) blk: {
                self.advance();
                const b = try self.parseBlock();
                _ = try self.expect(.r_brace);
                break :blk b;
            } else try self.parseStatement();
            var while_stmts = std.ArrayListUnmanaged(ast.NodeIndex).empty;
            try while_stmts.append(self.allocator, body);
            try while_stmts.appendSlice(self.allocator, updates.items);
            const body_loc = self.b.tree.getNode(body).?.main_token;
            const while_body = try self.b.block(&.{}, while_stmts.items, body_loc);
            const true_cond = try self.b.booleanNode(true, start_tok);
            const while_node = try self.b.whileStmt(if (condition == .none) true_cond else condition, while_body, false, start_tok);
            var outer_stmts = std.ArrayListUnmanaged(ast.NodeIndex).empty;
            try outer_stmts.appendSlice(self.allocator, init_assignments.items);
            try outer_stmts.append(self.allocator, while_node);
            return try self.b.block(&.{}, outer_stmts.items, start_tok);
        } else {
            _ = try self.expect(.r_paren);
            const body = if (self.tag(0) == .l_brace) blk: {
                self.advance();
                const b = try self.parseBlock();
                _ = try self.expect(.r_brace);
                break :blk b;
            } else try self.parseStatement();
            return self.b.forStmt(try self.b.addForBindings(standard_bindings.items), body, is_intersection, start_tok) catch ParseError.OutOfMemory;
        }
    }

    fn parseComprehensionElement(self: *Parser) ParseError!ast.NodeIndex {
        if (self.tag(0) == .keyword_for or self.tag(0) == .keyword_intersection_for) {
            const start_tok = self.tok_idx;
            const start_tag = self.tag(0);
            self.advance();
            _ = try self.expect(.l_paren);
            var bindings: std.ArrayListUnmanaged(ast.ForBinding) = .empty;
            errdefer bindings.deinit(self.allocator);
            while (self.tag(0) != .r_paren and self.tag(0) != .eof) {
                const var_tok = try self.expect(.ident);
                _ = try self.expect(.equal);
                const range_node = try self.parseExpression(.none);
                try bindings.append(self.allocator, .{ .name = try self.b.intern(self.tokens.lexeme(self.source, var_tok)), .range = range_node });
                if (self.tag(0) == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
            const body = try self.parseComprehensionElement();
            return self.b.forStmt(try self.b.addForBindings(bindings.items), body, (start_tag == .keyword_intersection_for), start_tok) catch ParseError.OutOfMemory;
        } else if (self.tag(0) == .keyword_let) {
            const start_tok = try self.expect(.keyword_let);
            _ = try self.expect(.l_paren);
            var assignments: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
            errdefer assignments.deinit(self.allocator);
            while (self.tag(0) != .r_paren and self.tag(0) != .eof) {
                const var_tok = try self.expect(.ident);
                _ = try self.expect(.equal);
                const val_expr = try self.parseExpression(.none);
                const assign_node = try self.b.assignment(try self.b.intern(self.tokens.lexeme(self.source, var_tok)), null, val_expr, var_tok);
                try assignments.append(self.allocator, assign_node);
                if (self.tag(0) == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
            const yield_expr = try self.parseComprehensionElement();
            var stmts_list = std.ArrayListUnmanaged(ast.NodeIndex).empty;
            try stmts_list.appendSlice(self.allocator, assignments.items);
            try stmts_list.append(self.allocator, yield_expr);
            return try self.b.block(&.{}, stmts_list.items, start_tok);
        } else if (self.tag(0) == .keyword_if) {
            const start_tok = try self.expect(.keyword_if);
            _ = try self.expect(.l_paren);
            const cond = try self.parseExpression(.none);
            _ = try self.expect(.r_paren);
            const then_branch = try self.parseComprehensionElement();
            var else_branch: ast.NodeIndex = .none;
            if (self.tag(0) == .keyword_else) {
                self.advance();
                else_branch = try self.parseComprehensionElement();
            }
            return self.b.ifStmt(cond, then_branch, else_branch, false, start_tok) catch ParseError.OutOfMemory;
        } else {
            var is_each = false;
            if (self.tag(0) == .keyword_each) {
                is_each = true;
                self.advance();
            }
            var expr = try self.parseExpression(.none);
            if (is_each) {
                const loc = self.b.tree.getNode(expr).?.main_token;
                expr = self.b.eachExpr(expr, loc) catch return ParseError.OutOfMemory;
            }
            return expr;
        }
    }

    fn parseInstantiationOrAssignment(self: *Parser) ParseError!ast.NodeIndex {
        const target_tok = self.tok_idx;
        const target_tag = self.tag(0);
        if (target_tag == .ident and self.tag(1) == .equal) {
            self.advance();
            self.advance();
            const val = try self.parseExpression(.none);
            if (self.tag(0) == .semicolon) {
                self.advance();
            }
            return self.b.assignment(try self.b.intern(self.tokens.lexeme(self.source, target_tok)), null, val, target_tok);
        }
        const expr = try self.parseExpression(.none);

        const expr_node = self.b.tree.getNode(expr) orelse return ParseError.InvalidExpression;
        if (expr_node.tag == .method_call) {
            if (self.tag(0) == .l_brace) {
                self.advance();
                const children_block = try self.parseBlock();
                _ = try self.expect(.r_brace);

                const expr_data = self.b.tree.getNode(expr).?.data;
                self.b.tree.method_calls.items[expr_data].block = children_block;
            } else if (self.tag(0) != .semicolon and self.tag(0) != .r_brace and self.tag(0) != .eof) {
                const child_stmt = try self.parseStatement();
                const stmts_arr = [_]ast.NodeIndex{child_stmt};
                const child_loc = self.b.tree.getNode(child_stmt).?.main_token;
                const child_block = try self.b.block(&.{}, &stmts_arr, child_loc);

                const expr_data = self.b.tree.getNode(expr).?.data;
                self.b.tree.method_calls.items[expr_data].block = child_block;
            }
        }
        if (self.tag(0) == .semicolon) {
            self.advance();
        }
        return expr;
    }

    pub fn parseExpression(self: *Parser, precedence: Precedence) ParseError!ast.NodeIndex {
        const start_tok = self.tok_idx;
        var left: ast.NodeIndex = undefined;
        self.skipIgnored();

        switch (self.tag(0)) {
            .number => {
                self.advance();
                left = try self.b.number(self.tokens.lexeme(self.source, start_tok), start_tok);
            },
            .string => {
                self.advance();
                self.skipIgnored();
                if (self.tag(0) == .string) {
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer buf.deinit(self.allocator);
                    try buf.appendSlice(self.allocator, self.tokens.lexeme(self.source, start_tok));
                    while (self.tag(0) == .string) {
                        try buf.appendSlice(self.allocator, self.lexeme(0));
                        self.advance();
                        self.skipIgnored();
                    }
                    left = try self.b.stringNode(buf.items, start_tok);
                } else {
                    left = try self.b.stringNode(self.tokens.lexeme(self.source, start_tok), start_tok);
                }
            },
            .keyword_true => {
                self.advance();
                left = try self.b.booleanNode(true, start_tok);
            },
            .keyword_false => {
                self.advance();
                left = try self.b.booleanNode(false, start_tok);
            },
            .keyword_undef => {
                self.advance();
                left = try self.b.undefNode(start_tok);
            },
            .ident => left = try self.parseIdentifierOrCall(),
            .l_paren => left = try self.parseGroupedExpression(),
            .l_bracket => left = try self.parseArrayOrRangeOrComprehension(),
            .plus, .minus, .bang => left = try self.parseUnary(),
            .keyword_let => left = try self.parseLetExpression(),
            .keyword_if => left = try self.parseIfExpression(),
            .keyword_assert, .keyword_echo => left = try self.parseAssertOrEchoExpr(),
            .keyword_function => {
                self.advance();
                const params = try self.parseParenParams();
                const body = try self.parseExpression(.none);
                left = try self.b.lambdaExpr(try self.b.addParams(params), body, start_tok);
            },
            else => {
                self.reportError(self.getLoc(start_tok), "Invalid expression starting with '{s}'", .{self.lexeme(0)});
                return ParseError.InvalidExpression;
            },
        }

        while (true) {
            self.skipIgnored();
            if (@intFromEnum(precedence) >= @intFromEnum(getInfixPrecedence(self.tag(0)))) break;

            left = switch (self.tag(0)) {
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
        while (self.tag(0) != .r_paren and self.tag(0) != .eof) {
            const var_tok = try self.expect(.ident);
            _ = try self.expect(.equal);
            const val_expr = try self.parseExpression(.none);
            const assign_node = try self.b.assignment(try self.b.intern(self.tokens.lexeme(self.source, var_tok)), null, val_expr, var_tok);
            try assignments.append(self.allocator, assign_node);
            if (self.tag(0) == .comma) self.advance() else break;
        }
        _ = try self.expect(.r_paren);
        const yield_expr = try self.parseExpression(.none);
        var stmts = std.ArrayListUnmanaged(ast.NodeIndex).empty;
        try stmts.appendSlice(self.allocator, assignments.items);
        try stmts.append(self.allocator, yield_expr);
        return try self.b.block(&.{}, stmts.items, start_tok);
    }

    fn parseAssertOrEchoExpr(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = self.tok_idx;
        self.advance();
        const args = try self.parseParenArgs();
        const yield_expr = try self.parseExpression(.none);
        const call_node = self.b.methodCall(.none, try self.b.intern(self.tokens.lexeme(self.source, start_tok)), try self.b.addNamedArgs(args), .none, false, start_tok) catch return ParseError.OutOfMemory;
        var stmts = try self.allocator.alloc(ast.NodeIndex, 2);
        stmts[0] = call_node;
        stmts[1] = yield_expr;
        return try self.b.block(&.{}, stmts, start_tok);
    }

    fn parseArrayOrRangeOrComprehension(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.l_bracket);
        while (self.tag(0) == .comment or self.tag(0) == .block_comment) self.advance();

        if (self.tag(0) == .keyword_for or self.tag(0) == .keyword_let or self.tag(0) == .keyword_if or self.tag(0) == .keyword_intersection_for) {
            const root = try self.parseComprehensionElement();
            while (self.tag(0) == .comment or self.tag(0) == .block_comment) self.advance();
            _ = try self.expect(.r_bracket);
            var arr = try self.allocator.alloc(ast.NodeIndex, 1);
            arr[0] = root;
            return self.b.arrayLiteral(try self.b.addNodes(arr), start_tok) catch ParseError.OutOfMemory;
        }

        var elements: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer elements.deinit(self.allocator);

        if (self.tag(0) == .r_bracket) {
            self.advance();
            return self.b.arrayLiteral(try self.b.addNodes(&.{}), start_tok) catch ParseError.OutOfMemory;
        }

        var is_each = false;
        if (self.tag(0) == .keyword_each) {
            is_each = true;
            self.advance();
        }

        var first: ast.NodeIndex = undefined;
        if (self.tag(0) == .comma or self.tag(0) == .r_bracket) {
            first = try self.b.undefNode(self.tok_idx);
        } else {
            first = try self.parseExpression(.none);
        }

        if (is_each) {
            first = self.b.eachExpr(first, start_tok) catch return ParseError.OutOfMemory;
        }

        if (self.tag(0) == .colon) {
            if (is_each) return ParseError.InvalidExpression;
            self.advance();
            const second = try self.parseExpression(.none);
            if (self.tag(0) == .colon) {
                self.advance();
                const third = try self.parseExpression(.none);
                _ = try self.expect(.r_bracket);
                return self.b.range(first, third, second, false, start_tok) catch ParseError.OutOfMemory;
            }
            _ = try self.expect(.r_bracket);
            return self.b.range(first, second, .none, false, start_tok) catch ParseError.OutOfMemory;
        }

        try elements.append(self.allocator, first);
        if (self.tag(0) == .comma) self.advance();

        while (self.tag(0) != .r_bracket and self.tag(0) != .eof) {
            while (self.tag(0) == .comment or self.tag(0) == .block_comment) self.advance();
            if (self.tag(0) == .r_bracket) break;

            is_each = false;
            if (self.tag(0) == .keyword_each) {
                is_each = true;
                self.advance();
            }

            var elem: ast.NodeIndex = undefined;
            if (self.tag(0) == .comma or self.tag(0) == .r_bracket) {
                elem = try self.b.undefNode(self.tok_idx);
            } else {
                elem = try self.parseExpression(.none);
            }

            if (is_each) {
                elem = self.b.eachExpr(elem, start_tok) catch return ParseError.OutOfMemory;
            }
            try elements.append(self.allocator, elem);
            if (self.tag(0) == .comma) self.advance() else break;
        }

        _ = try self.expect(.r_bracket);
        return self.b.arrayLiteral(try self.b.addNodes(elements.items), start_tok) catch ParseError.OutOfMemory;
    }

    fn parseNamedArg(self: *Parser) ParseError!ast.NamedArg {
        if (self.tag(0) == .comma or self.tag(0) == .r_paren) {
            const val = try self.b.undefNode(self.tok_idx);
            return .{ .name = .none, .value = val, .modifier = null };
        }
        var arg_name: ast.StringId = .none;
        if (self.tag(0) == .ident and self.tag(1) == .equal) {
            arg_name = try self.b.intern(self.lexeme(0));
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
        if (self.tag(0) != .ident) return ParseError.UnexpectedToken;
        const param_name = try self.b.intern(self.lexeme(0));
        self.advance();
        var default_val: ast.NodeIndex = .none;
        if (self.tag(0) == .equal) {
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
        if (self.tag(0) == .keyword_else) {
            self.advance();
            else_branch = try self.parseExpression(.none);
        }
        return self.b.ifStmt(cond, then_branch, else_branch, false, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseModuleDecl(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_module);
        const name_tok = try self.expect(.ident);
        var params: []const ast.Param = &.{};
        if (self.tag(0) == .l_paren) {
            params = try self.parseParenParams();
        }
        const body = if (self.tag(0) == .l_brace) blk: {
            self.advance();
            const b = try self.parseBlock();
            _ = try self.expect(.r_brace);
            break :blk b;
        } else try self.parseStatement();
        return self.b.defStmt(try self.b.intern(self.tokens.lexeme(self.source, name_tok)), try self.b.addParams(params), body, false, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseFunctionDecl(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_function);
        const name_tok = try self.expect(.ident);
        var params: []const ast.Param = &.{};
        if (self.tag(0) == .l_paren) {
            params = try self.parseParenParams();
        }
        _ = try self.expect(.equal);
        const body_expr = try self.parseExpression(.none);
        if (self.tag(0) == .semicolon) {
            self.advance();
        }
        return self.b.defStmt(try self.b.intern(self.tokens.lexeme(self.source, name_tok)), try self.b.addParams(params), body_expr, false, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseIfStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_if);
        _ = try self.expect(.l_paren);
        const cond = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);
        const then_branch = if (self.tag(0) == .l_brace) blk: {
            self.advance();
            const b = try self.parseBlock();
            _ = try self.expect(.r_brace);
            break :blk b;
        } else try self.parseStatement();
        var else_branch: ast.NodeIndex = .none;
        if (self.tag(0) == .keyword_else) {
            self.advance();
            else_branch = if (self.tag(0) == .l_brace) blk: {
                self.advance();
                const b = try self.parseBlock();
                _ = try self.expect(.r_brace);
                break :blk b;
            } else try self.parseStatement();
        }
        return self.b.ifStmt(cond, then_branch, else_branch, false, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseAssertOrEcho(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = self.tok_idx;
        self.advance();
        const args = try self.parseParenArgs();
        const call_node = self.b.methodCall(.none, try self.b.intern(self.tokens.lexeme(self.source, start_tok)), try self.b.addNamedArgs(args), .none, false, start_tok) catch return ParseError.OutOfMemory;

        if (self.tag(0) == .semicolon) {
            self.advance();
            return call_node;
        } else if (self.tag(0) == .l_brace) {
            self.advance();
            const child_block = try self.parseBlock();
            _ = try self.expect(.r_brace);
            const call_data = self.b.tree.getNode(call_node).?.data;
            self.b.tree.method_calls.items[call_data].block = child_block;
            return call_node;
        } else if (self.tag(0) != .r_brace and self.tag(0) != .eof) {
            const child_stmt = try self.parseStatement();
            const stmts_arr = [_]ast.NodeIndex{child_stmt};
            const block = try self.b.block(&.{}, &stmts_arr, self.b.tree.getNode(child_stmt).?.main_token);
            const call_data = self.b.tree.getNode(call_node).?.data;
            self.b.tree.method_calls.items[call_data].block = block;
            return call_node;
        }
        return call_node;
    }

    fn parseIdentifierOrCall(self: *Parser) ParseError!ast.NodeIndex {
        const tok_idx = try self.expect(.ident);
        if (self.tag(0) == .l_paren) {
            const args = try self.parseParenArgs();
            return self.b.methodCall(.none, try self.b.intern(self.tokens.lexeme(self.source, tok_idx)), try self.b.addNamedArgs(args), .none, false, tok_idx) catch ParseError.OutOfMemory;
        }
        return self.b.identifierNode(self.tokens.lexeme(self.source, tok_idx), tok_idx) catch ParseError.OutOfMemory;
    }

    fn parseGroupedExpression(self: *Parser) ParseError!ast.NodeIndex {
        _ = try self.expect(.l_paren);
        const expr = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);
        return expr;
    }

    fn parseUnary(self: *Parser) ParseError!ast.NodeIndex {
        const tok_idx = self.tok_idx;
        const t = self.tag(0);
        self.advance();
        const op: ast.UnaryOp = switch (t) {
            .minus => .negate,
            .plus => .positive,
            else => .not,
        };
        const operand = try self.parseExpression(.unary);
        return self.b.unary(op, operand, tok_idx) catch ParseError.OutOfMemory;
    }

    fn parseBinary(self: *Parser, left: ast.NodeIndex) ParseError!ast.NodeIndex {
        const tok_tag = self.tag(0);
        self.advance();
        const op = tagToBinaryOp(tok_tag) orelse return ParseError.InvalidExpression;
        const right = try self.parseExpression(getInfixPrecedence(tok_tag));
        const left_node = self.b.tree.getNode(left) orelse return ParseError.InvalidExpression;
        return self.b.binary(op, left, right, left_node.main_token) catch ParseError.OutOfMemory;
    }

    fn parseTernary(self: *Parser, condition: ast.NodeIndex) ParseError!ast.NodeIndex {
        _ = try self.expect(.question);
        const then_branch = try self.parseExpression(.none);
        _ = try self.expect(.colon);
        const else_branch = try self.parseExpression(.none);
        const cond_node = self.b.tree.getNode(condition) orelse return ParseError.InvalidExpression;
        return self.b.ternary(condition, then_branch, else_branch, cond_node.main_token) catch ParseError.OutOfMemory;
    }

    fn parseIndexAccess(self: *Parser, target: ast.NodeIndex) ParseError!ast.NodeIndex {
        _ = try self.expect(.l_bracket);
        const index = try self.parseExpression(.none);
        _ = try self.expect(.r_bracket);
        const target_node = self.b.tree.getNode(target).?;
        return self.b.indexAccess(target, index, target_node.main_token) catch ParseError.OutOfMemory;
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
