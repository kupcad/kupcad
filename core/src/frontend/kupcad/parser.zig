const std = @import("std");
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const Tag = lexer_mod.Tag;
const Token = lexer_mod.Token;
const ast = @import("../../core/ast.zig");
const common_token = @import("../../core/token.zig");
const Node = ast.Node;
const common_errors = @import("../../core/errors.zig");
const docstring = @import("docstring.zig");

const Diagnostics = common_errors.Diagnostics;

const RescueEnsurePayload = struct {
    rescues: ast.Span,
    ensure_body: ast.NodeIndex,
};

pub const ParseError = common_errors.ParseError;

pub const Precedence = enum(u8) {
    none = 0,
    assignment = 1, // = += -= etc
    rescue_mod = 2, // rescue
    ternary = 3, // ? :
    logical_or = 4, // ||
    logical_and = 5, // &&
    equality = 6, // == !=
    comparison = 7, // < <= > >=
    bitwise_or = 8, // | ^
    bitwise_and = 9, // & (CSG Intersection)
    shift = 10, // << >>
    range = 11, // .. ...
    term = 12, // + -
    factor = 13, // * / %
    unary = 14, // ! -
    exponent = 15, // **
    call = 16, // . &. () [] ::
};

pub const Parser = struct {
    tokens: common_token.BufferedLexer(Lexer, Token, Tag),
    allocator: std.mem.Allocator,
    b: ast.Builder,
    diagnostics: Diagnostics,
    comments: std.ArrayListUnmanaged(common_token.Comment) = .empty,

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
            if (self.tokens.previous.tag == .newline) return;
            switch (self.tokens.current.tag) {
                .keyword_class, .keyword_def, .keyword_module, .keyword_if, .keyword_unless, .keyword_case, .keyword_while, .keyword_until, .keyword_return, .keyword_begin, .keyword_import, .keyword_export => return,
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
        while (self.tokens.current.tag == .newline or self.tokens.current.tag == .comment) {
            if (self.tokens.current.tag == .comment) {
                self.comments.append(self.allocator, .{
                    .lexeme = self.tokens.current.lexeme,
                    .loc = self.tokens.current.loc,
                }) catch {};
            }
            self.advance();
        }
    }

    fn skipComments(self: *Parser) void {
        while (self.tokens.current.tag == .comment or self.tokens.current.tag == .param_doc) {
            if (self.tokens.current.tag == .comment) {
                self.comments.append(self.allocator, .{
                    .lexeme = self.tokens.current.lexeme,
                    .loc = self.tokens.current.loc,
                }) catch {};
            }
            self.advance();
        }
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

    pub fn parseBlock(self: *Parser, end_tags: []const Tag) ParseError!ast.NodeIndex {
        const start_loc = self.tokens.current.loc;
        var stmts: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer stmts.deinit(self.allocator);

        while (self.tokens.current.tag != .eof) {
            self.skipIgnored();
            var is_end = false;
            for (end_tags) |end_tag| {
                if (self.tokens.current.tag == end_tag) {
                    is_end = true;
                    break;
                }
            }
            if (is_end) break;
            if (self.tokens.current.tag == .eof) break;

            if (self.parseStatement()) |parsed_stmt| {
                try stmts.append(self.allocator, parsed_stmt);
            } else |err| {
                if (err == ParseError.OutOfMemory) return err;
                self.synchronize();
            }
        }
        return self.b.block(&.{}, stmts.items, self.getSpan(start_loc)) catch ParseError.OutOfMemory;
    }

    pub fn parseStatement(self: *Parser) ParseError!ast.NodeIndex {
        self.skipIgnored();

        var stmt = switch (self.tokens.current.tag) {
            .keyword_import => try self.parseImportOrExportStatement(false),
            .keyword_export => try self.parseImportOrExportStatement(true),
            .keyword_if => try self.parseIfOrUnless(false),
            .keyword_unless => try self.parseIfOrUnless(true),
            .keyword_case => try self.parseCaseStatement(),
            .keyword_while, .keyword_until => try self.parseWhileStatement(),
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

        if (self.tokens.current.tag == .keyword_if or self.tokens.current.tag == .keyword_unless or self.tokens.current.tag == .keyword_while or self.tokens.current.tag == .keyword_until) {
            const mod_tag = self.tokens.current.tag;
            const mod_loc = self.tokens.current.loc;
            self.advance();
            const cond = try self.parseExpression(.none);

            var block_arr = try self.allocator.alloc(ast.NodeIndex, 1);
            block_arr[0] = stmt;
            const then_block = self.b.block(&.{}, block_arr, self.getSpan(self.b.tree.getNode(stmt).?.loc)) catch return ParseError.OutOfMemory;

            if (mod_tag == .keyword_if or mod_tag == .keyword_unless) {
                stmt = self.b.ifStmt(cond, then_block, .none, mod_tag == .keyword_unless, self.getSpan(mod_loc)) catch return ParseError.OutOfMemory;
            } else {
                stmt = self.b.whileStmt(cond, then_block, mod_tag == .keyword_until, self.getSpan(mod_loc)) catch return ParseError.OutOfMemory;
            }
        }

        return stmt;
    }

    fn parseExprOrMultiAssign(self: *Parser) ParseError!ast.NodeIndex {
        const is_multi = if ((self.tokens.current.tag == .ident or self.tokens.current.tag == .constant or self.tokens.current.tag == .star) and (self.tokens.peekTag() == .comma or self.tokens.peekTag() == .ident)) self.isMultipleAssignmentStatement() else false;

        if (is_multi) {
            const start_loc = self.tokens.current.loc;
            var lhs_list: std.ArrayListUnmanaged(ast.LhsExpr) = .empty;
            errdefer lhs_list.deinit(self.allocator);

            while (self.tokens.current.tag != .newline and self.tokens.current.tag != .eof and self.tokens.current.tag != .keyword_then) {
                if (isAssignmentOp(self.tokens.current.tag)) break;

                var mod: ?ast.ArgModifier = null;
                if (self.tokens.current.tag == .star) {
                    mod = .splat;
                    self.advance();
                }

                if (self.tokens.current.tag == .ident or self.tokens.current.tag == .constant) {
                    try lhs_list.append(self.allocator, .{ .name = try self.b.intern(self.tokens.current.lexeme), .modifier = mod });
                    self.advance();
                } else return ParseError.UnexpectedToken;

                if (self.tokens.current.tag == .comma) {
                    self.advance();
                } else break;
            }

            if (isAssignmentOp(self.tokens.current.tag)) {
                const op_tag = self.tokens.current.tag;
                self.advance();
                const val_node = try self.parseExpressionList();

                return self.b.multipleAssignment(try self.b.addLhsExprs(lhs_list.items), tagToAssignmentOp(op_tag), val_node, self.getSpan(start_loc)) catch ParseError.OutOfMemory;
            } else return ParseError.UnexpectedToken;
        }

        return try self.parseExpression(.none);
    }

    fn parseLambda(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.minus_greater);
        const params = try self.parseParenParams();
        self.skipIgnored();

        var body: ast.NodeIndex = .none;
        if (self.tokens.current.tag == .l_brace) {
            self.advance();
            body = try self.parseBlock(&.{.r_brace});
            _ = try self.expect(.r_brace);
        } else if (self.tokens.current.tag == .keyword_do) {
            self.advance();
            body = try self.parseBlock(&.{.keyword_end});
            _ = try self.expect(.keyword_end);
        } else {
            return ParseError.UnexpectedToken;
        }

        return self.b.lambdaExpr(try self.b.addParams(params), body, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseAssignmentExpr(self: *Parser, left: ast.NodeIndex) ParseError!ast.NodeIndex {
        const op_tok = self.tokens.current;
        const op_tag = op_tok.tag;
        self.advance();

        const value = try self.parseExpressionList();

        const left_node = self.b.tree.getNode(left) orelse return ParseError.InvalidExpression;

        switch (left_node.tag) {
            .identifier => {
                return self.b.assignment(@as(ast.StringId, @enumFromInt(left_node.data)), tagToAssignmentOp(op_tag), value, self.getSpan(left_node.loc)) catch ParseError.OutOfMemory;
            },
            .method_call => {
                const mc = self.b.tree.methodCall(left_node);
                if (mc.args.start == mc.args.end and mc.block == .none) {
                    return self.b.propertyAssignment(mc.receiver, mc.method_name, tagToAssignmentOp(op_tag), value, self.getSpan(left_node.loc)) catch ParseError.OutOfMemory;
                }
            },
            .index_access => {
                const ia = self.b.tree.index_accesses.items[left_node.data];
                return self.b.indexAssignment(ia.target, ia.index, tagToAssignmentOp(op_tag), value, self.getSpan(left_node.loc)) catch ParseError.OutOfMemory;
            },
            else => {},
        }

        self.reportError(op_tok.loc, "Invalid expression starting with '{s}'", .{op_tok.lexeme});
        return ParseError.InvalidExpression;
    }

    fn parseBinary(self: *Parser, left: ast.NodeIndex) ParseError!ast.NodeIndex {
        const tok = self.tokens.current;
        self.advance();

        if (tok.tag == .dot_dot or tok.tag == .dot_dot_dot) {
            return self.b.range(left, try self.parseExpression(.range), .none, (tok.tag == .dot_dot_dot), self.getSpan(tok.loc)) catch ParseError.OutOfMemory;
        }

        const op = tagToBinaryOp(tok.tag) orelse return ParseError.InvalidExpression;
        const next_prec = if (tok.tag == .star_star)
            @as(Precedence, @enumFromInt(@intFromEnum(getInfixPrecedence(tok.tag)) - 1))
        else
            getInfixPrecedence(tok.tag);

        const left_node = self.b.tree.getNode(left) orelse return ParseError.InvalidExpression;
        return self.b.binary(op, left, try self.parseExpression(next_prec), self.getSpan(left_node.loc)) catch ParseError.OutOfMemory;
    }

    fn parseTernary(self: *Parser, condition: ast.NodeIndex) ParseError!ast.NodeIndex {
        _ = try self.expect(.question);
        const then_branch = try self.parseExpression(.none);
        _ = try self.expect(.colon);
        const else_branch = try self.parseExpression(.none);

        const cond_node = self.b.tree.getNode(condition) orelse return ParseError.InvalidExpression;
        return self.b.ternary(condition, then_branch, else_branch, self.getSpan(cond_node.loc)) catch ParseError.OutOfMemory;
    }

    fn parseIndexAccessOrAssignment(self: *Parser, target: ast.NodeIndex) ParseError!ast.NodeIndex {
        _ = try self.expect(.l_bracket);
        const index = try self.parseExpressionList();
        _ = try self.expect(.r_bracket);

        const target_node = self.b.tree.getNode(target) orelse return ParseError.InvalidExpression;

        if (isAssignmentOp(self.tokens.current.tag)) {
            const op_tag = self.tokens.current.tag;
            self.advance();
            return self.b.indexAssignment(target, index, tagToAssignmentOp(op_tag), try self.parseExpressionList(), self.getSpan(target_node.loc)) catch ParseError.OutOfMemory;
        }

        return self.b.indexAccess(target, index, self.getSpan(target_node.loc)) catch ParseError.OutOfMemory;
    }

    fn parseBlockClosure(self: *Parser) ParseError!ast.NodeIndex {
        const is_brace = (self.tokens.current.tag == .l_brace);
        const start_tok = if (is_brace) try self.expect(.l_brace) else try self.expect(.keyword_do);

        var params: []const ast.NodeIndex = &.{};
        if (self.tokens.current.tag == .pipe) {
            self.advance();
            params = try self.parseCommaSeparated(ast.NodeIndex, parseBlockParam, .pipe);
            _ = try self.expect(.pipe);
        }

        const end_tags: []const Tag = if (is_brace) &.{.r_brace} else &.{.keyword_end};
        const block_node_idx = try self.parseBlock(end_tags);

        if (is_brace) {
            _ = try self.expect(.r_brace);
        } else {
            _ = try self.expect(.keyword_end);
        }

        const block_node = self.b.tree.getNode(block_node_idx) orelse return ParseError.InvalidExpression;
        return self.b.block(params, self.b.tree.getNodes(block_node.data), self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseBeginStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_begin);
        self.skipIgnored();

        const body = try self.parseBlock(&.{ .keyword_rescue, .keyword_ensure, .keyword_end });
        const payload = try self.parseRescueAndEnsure();
        _ = try self.expect(.keyword_end);

        return self.b.beginStmt(body, payload.rescues, payload.ensure_body, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseImportOrExportStatement(self: *Parser, is_export: bool) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(if (is_export) .keyword_export else .keyword_import);

        var symbols: std.ArrayListUnmanaged(ast.StringId) = .empty;
        errdefer symbols.deinit(self.allocator);

        if (self.tokens.current.tag == .l_brace) {
            self.advance();
            while (self.tokens.current.tag != .r_brace and self.tokens.current.tag != .eof) {
                self.skipIgnored();
                if (self.tokens.current.tag == .ident or self.tokens.current.tag == .constant) {
                    try symbols.append(self.allocator, try self.b.intern(self.tokens.current.lexeme));
                    self.advance();
                } else return ParseError.UnexpectedToken;

                if (self.tokens.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_brace);
            _ = try self.expect(.keyword_from);
        } else if (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) {
            try symbols.append(self.allocator, try self.b.intern(self.tokens.current.lexeme));
            self.advance();
            _ = try self.expect(.keyword_from);
        } else if (self.tokens.current.tag != .string) {
            return ParseError.UnexpectedToken;
        }

        const path_tok = try self.expect(.string);
        const interned_path = try self.b.intern(path_tok.lexeme);

        var attributes: ast.NodeIndex = .none;
        self.skipIgnored();
        if (self.tokens.current.tag == .keyword_with) {
            self.advance();
            attributes = try self.parseHashLiteral();
        }

        if (is_export) {
            return self.b.exportStmt(try self.b.addStringLists(symbols.items), interned_path, attributes, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
        } else {
            return self.b.importStmt(try self.b.addStringLists(symbols.items), interned_path, attributes, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
        }
    }

    fn parseIfOrUnless(self: *Parser, is_unless: bool) ParseError!ast.NodeIndex {
        const start_tok = self.tokens.current;
        self.advance();

        const condition = try self.parseExpression(.none);
        if (self.tokens.current.tag == .keyword_then) self.advance();

        self.skipIgnored();
        const then_branch = try self.parseBlock(&.{ .keyword_elsif, .keyword_else, .keyword_end });

        var else_branch: ast.NodeIndex = .none;
        if (self.tokens.current.tag == .keyword_elsif) {
            else_branch = try self.parseIfOrUnless(false);
        } else if (self.tokens.current.tag == .keyword_else) {
            self.advance();
            self.skipIgnored();
            else_branch = try self.parseBlock(&.{.keyword_end});
            _ = try self.expect(.keyword_end);
        } else if (self.tokens.current.tag == .keyword_end) {
            self.advance();
        }

        return self.b.ifStmt(condition, then_branch, else_branch, is_unless, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseCaseStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_case);

        var condition: ast.NodeIndex = .none;
        if (self.tokens.current.tag != .newline and self.tokens.current.tag != .keyword_when) {
            condition = try self.parseExpression(.none);
        }

        if (self.tokens.current.tag == .keyword_then) self.advance();
        self.skipIgnored();

        var when_branches: std.ArrayListUnmanaged(ast.WhenBranch) = .empty;
        errdefer when_branches.deinit(self.allocator);

        while (self.tokens.current.tag == .keyword_when) {
            self.advance();
            var conditions: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
            errdefer conditions.deinit(self.allocator);

            while (self.tokens.current.tag != .newline and self.tokens.current.tag != .eof and self.tokens.current.tag != .keyword_then) {
                try conditions.append(self.allocator, try self.parseExpression(.none));
                if (self.tokens.current.tag == .comma) self.advance() else break;
            }

            if (self.tokens.current.tag == .keyword_then) self.advance();
            self.skipIgnored();

            const body = try self.parseBlock(&.{ .keyword_when, .keyword_else, .keyword_end });
            try when_branches.append(self.allocator, .{
                .conditions = try self.b.addNodes(conditions.items),
                .body = body,
            });
        }

        var else_branch: ast.NodeIndex = .none;
        if (self.tokens.current.tag == .keyword_else) {
            self.advance();
            self.skipIgnored();
            else_branch = try self.parseBlock(&.{.keyword_end});
        }
        _ = try self.expect(.keyword_end);

        return self.b.caseStmt(condition, try self.b.addWhenBranches(when_branches.items), else_branch, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseWhileStatement(self: *Parser) ParseError!ast.NodeIndex {
        const is_until = (self.tokens.current.tag == .keyword_until);
        const start_tok = self.tokens.current;
        self.advance();

        const condition = try self.parseExpression(.none);
        self.skipIgnored();

        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.b.whileStmt(condition, body, is_until, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseDefStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_def);
        var is_class_method = false;
        var name_tok: Token = undefined;

        if (self.tokens.current.tag == .keyword_self and self.tokens.peekTag() == .dot) {
            is_class_method = true;
            self.advance();
            self.advance();
            if (self.tokens.current.tag != .ident and self.tokens.current.tag != .constant) return ParseError.UnexpectedToken;
            name_tok = self.tokens.current;
            self.advance();
        } else {
            if (self.tokens.current.tag != .ident and self.tokens.current.tag != .constant) return ParseError.UnexpectedToken;
            name_tok = self.tokens.current;
            self.advance();
        }

        var params: []const ast.Param = &.{};
        if (self.tokens.current.tag == .l_paren) {
            params = try self.parseParenParams();
        } else {
            var param_list: std.ArrayListUnmanaged(ast.Param) = .empty;
            errdefer param_list.deinit(self.allocator);
            while (self.tokens.current.tag != .newline and self.tokens.current.tag != .eof and self.tokens.current.tag != .comment) {
                try param_list.append(self.allocator, try self.parseParam());
                if (self.tokens.current.tag == .comma) {
                    self.advance();
                } else break;
            }
            params = try param_list.toOwnedSlice(self.allocator);
        }

        self.skipIgnored();
        const body_node = try self.parseBlock(&.{ .keyword_rescue, .keyword_ensure, .keyword_end });
        const payload = try self.parseRescueAndEnsure();
        _ = try self.expect(.keyword_end);

        var final_body = body_node;
        if (payload.rescues.start != payload.rescues.end or payload.ensure_body != .none) {
            final_body = self.b.beginStmt(body_node, payload.rescues, payload.ensure_body, self.getSpan(start_tok.loc)) catch return ParseError.OutOfMemory;
        }

        return self.b.defStmt(try self.b.intern(name_tok.lexeme), try self.b.addParams(params), final_body, is_class_method, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseModuleStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_module);
        const name_tok = if (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) self.tokens.current else return ParseError.UnexpectedToken;
        self.advance();

        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.b.moduleStmt(try self.b.intern(name_tok.lexeme), try self.b.addParams(&.{}), body, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseSuper(self: *Parser) ParseError!ast.NodeIndex {
        const tok = try self.expect(.keyword_super);

        if (self.tokens.current.tag == .l_paren) {
            const args = try self.parseParenArgs();
            var block_node: ast.NodeIndex = .none;
            if (self.tokens.current.tag == .keyword_do or self.tokens.current.tag == .l_brace) block_node = try self.parseBlockClosure();

            return self.b.superCall(try self.b.addNamedArgs(args), block_node, self.getSpan(tok.loc)) catch ParseError.OutOfMemory;
        }

        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            return self.b.superCall(try self.b.addNamedArgs(cmd.args), cmd.block orelse .none, self.getSpan(tok.loc)) catch ParseError.OutOfMemory;
        }

        return self.b.superCall(try self.b.addNamedArgs(&.{}), .none, self.getSpan(tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseCallOnExpr(self: *Parser, receiver_expr: ast.NodeIndex) ParseError!ast.NodeIndex {
        const args = try self.parseParenArgs();
        var block_node: ast.NodeIndex = .none;
        if (self.tokens.current.tag == .keyword_do or self.tokens.current.tag == .l_brace) block_node = try self.parseBlockClosure();

        const rec_node = self.b.tree.getNode(receiver_expr) orelse return ParseError.InvalidExpression;

        if (rec_node.tag == .identifier) {
            return self.b.methodCall(.none, @as(ast.StringId, @enumFromInt(rec_node.data)), try self.b.addNamedArgs(args), block_node, false, self.getSpan(rec_node.loc)) catch ParseError.OutOfMemory;
        } else {
            return self.b.methodCall(receiver_expr, try self.b.intern(""), try self.b.addNamedArgs(args), block_node, false, self.getSpan(rec_node.loc)) catch ParseError.OutOfMemory;
        }
    }

    fn parseMethodCall(self: *Parser, receiver: ast.NodeIndex, is_safe: bool) ParseError!ast.NodeIndex {
        if (self.tokens.current.tag == .dot or self.tokens.current.tag == .ampersand_dot) self.advance();
        const method_tok = try self.expect(.ident);

        const rec_node = self.b.tree.getNode(receiver) orelse return ParseError.InvalidExpression;

        if (self.tokens.current.tag == .l_paren) {
            const args = try self.parseParenArgs();
            var block_node: ast.NodeIndex = .none;
            if (self.tokens.current.tag == .keyword_do or self.tokens.current.tag == .l_brace) block_node = try self.parseBlockClosure();

            return self.b.methodCall(receiver, try self.b.intern(method_tok.lexeme), try self.b.addNamedArgs(args), block_node, is_safe, self.getSpan(rec_node.loc)) catch ParseError.OutOfMemory;
        }

        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            return self.b.methodCall(receiver, try self.b.intern(method_tok.lexeme), try self.b.addNamedArgs(cmd.args), cmd.block orelse .none, is_safe, self.getSpan(rec_node.loc)) catch ParseError.OutOfMemory;
        }

        return self.b.methodCall(receiver, try self.b.intern(method_tok.lexeme), try self.b.addNamedArgs(&.{}), .none, is_safe, self.getSpan(rec_node.loc)) catch ParseError.OutOfMemory;
    }

    fn parseIdentifierOrCall(self: *Parser) ParseError!ast.NodeIndex {
        const tok = self.tokens.current;
        if (tok.tag != .ident and tok.tag != .constant) {
            self.reportError(tok.loc, "Expected identifier or constant", .{});
            return ParseError.UnexpectedToken;
        }
        self.advance();

        if (self.tokens.current.tag == .l_paren) {
            const args = try self.parseParenArgs();
            var block_node: ast.NodeIndex = .none;
            if (self.tokens.current.tag == .keyword_do or self.tokens.current.tag == .l_brace) {
                block_node = try self.parseBlockClosure();
            }
            return self.b.methodCall(.none, try self.b.intern(tok.lexeme), try self.b.addNamedArgs(args), block_node, false, self.getSpan(tok.loc)) catch ParseError.OutOfMemory;
        }

        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            return self.b.methodCall(.none, try self.b.intern(tok.lexeme), try self.b.addNamedArgs(cmd.args), cmd.block orelse .none, false, self.getSpan(tok.loc)) catch ParseError.OutOfMemory;
        }

        return self.b.identifierNode(tok.lexeme, self.getSpan(tok.loc)) catch ParseError.OutOfMemory;
    }

    pub fn parseProgram(self: *Parser) ParseError!ast.NodeIndex {
        return self.parseBlock(&.{});
    }

    fn isMultipleAssignmentStatement(self: *Parser) bool {
        var temp_lexer = self.tokens.lexer.*;
        var temp_tokens = self.tokens;
        temp_tokens.lexer = &temp_lexer;

        var curr = temp_tokens.current;
        var has_comma = false;

        while (curr.tag != .newline and curr.tag != .eof) {
            if (isAssignmentOp(curr.tag)) return has_comma;
            if (curr.tag == .comma) {
                has_comma = true;
            } else if (curr.tag != .ident and curr.tag != .constant and curr.tag != .star) {
                return false;
            }
            temp_tokens.advance();
            curr = temp_tokens.current;
        }
        return false;
    }

    fn parseNextStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_next);
        var val: ast.NodeIndex = .none;
        if (!self.isExprListEnd()) {
            val = try self.parseExpressionList();
        }
        return self.b.nextStmt(val, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseReturnStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_return);
        var val: ast.NodeIndex = .none;
        if (!self.isExprListEnd()) {
            val = try self.parseExpressionList();
        }
        return self.b.returnStmt(val, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseBreakStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_break);
        var val: ast.NodeIndex = .none;
        if (!self.isExprListEnd()) {
            val = try self.parseExpressionList();
        }
        return self.b.breakStmt(val, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseClassPath(self: *Parser) ParseError!ast.NodeIndex {
        const start_loc = self.tokens.current.loc;
        if (self.tokens.current.tag != .constant and self.tokens.current.tag != .ident) {
            self.reportError(start_loc, "Expected 'constant', but found '{s}'", .{self.tokens.current.lexeme});
            return ParseError.UnexpectedToken;
        }

        var path_list: std.ArrayListUnmanaged(ast.StringId) = .empty;
        errdefer path_list.deinit(self.allocator);

        while (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) {
            try path_list.append(self.allocator, try self.b.intern(self.tokens.current.lexeme));
            self.advance();
            if (self.tokens.current.tag == .colon_colon) {
                self.advance();
            } else break;
        }

        if (path_list.items.len == 1) {
            return self.b.createNode(.identifier, self.getSpan(start_loc), @intFromEnum(path_list.items[0])) catch ParseError.OutOfMemory;
        } else {
            return self.b.namespaceAccess(try self.b.addStringLists(path_list.items), self.getSpan(start_loc)) catch ParseError.OutOfMemory;
        }
    }

    fn parseClassStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_class);
        const name_node = try self.parseClassPath();

        var super_class: ast.NodeIndex = .none;
        if (self.tokens.current.tag == .less) {
            self.advance();
            super_class = try self.parseClassPath();
        }

        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.b.classStmt(name_node, super_class, body, self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseYieldStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_yield);
        var args: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer args.deinit(self.allocator);

        if (self.tokens.current.tag == .l_paren) {
            self.advance();
            while (self.tokens.current.tag != .r_paren and self.tokens.current.tag != .eof) {
                try args.append(self.allocator, try self.parseExpression(.none));
                if (self.tokens.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
        } else {
            while (!self.isExprListEnd()) {
                try args.append(self.allocator, try self.parseExpression(.none));
                if (self.tokens.current.tag == .comma) self.advance() else break;
            }
        }
        return self.b.yieldStmt(try self.b.addNodes(args.items), self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseParamDoc(self: *Parser) ParseError!ast.NodeIndex {
        const tok = try self.expect(.param_doc);
        var doc_parser = docstring.DocstringParser{ .allocator = self.allocator, .b = &self.b };
        return doc_parser.parse(tok.lexeme, tok.loc) catch return ParseError.OutOfMemory;
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

    fn parseArgModifier(self: *Parser) ?ast.ArgModifier {
        switch (self.tokens.current.tag) {
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
        if (self.tokens.current.tag == .comma or self.tokens.current.tag == .r_paren) {
            const val = try self.b.undefNode(self.tokens.current.loc);
            return .{ .name = .none, .value = val, .modifier = null };
        }

        const mod = self.parseArgModifier();

        var arg_name: ast.StringId = .none;
        if (self.tokens.current.tag == .ident and self.tokens.peekTag() == .colon) {
            arg_name = try self.b.intern(self.tokens.current.lexeme);
            self.advance();
            self.advance();
        }

        const val = try self.parseExpression(.none);
        return .{ .name = arg_name, .value = val, .modifier = mod };
    }

    fn parseParenArgs(self: *Parser) ParseError![]const ast.NamedArg {
        if (self.tokens.current.tag == .l_paren) {
            self.advance();
            const args = try self.parseCommaSeparated(ast.NamedArg, parseNamedArg, .r_paren);
            _ = try self.expect(.r_paren);
            return args;
        }
        return &.{};
    }

    fn parseParam(self: *Parser) ParseError!ast.Param {
        const mod = self.parseArgModifier();

        if (self.tokens.current.tag != .ident) return ParseError.UnexpectedToken;

        const param_name = try self.b.intern(self.tokens.current.lexeme);
        self.advance();

        var is_keyword = false;
        var default_val: ast.NodeIndex = .none;

        if (self.tokens.current.tag == .colon) {
            is_keyword = true;
            self.advance();
            if (self.tokens.current.tag != .comma and self.tokens.current.tag != .r_paren) {
                default_val = try self.parseExpression(.none);
            }
        } else if (self.tokens.current.tag == .equal) {
            self.advance();
            default_val = try self.parseExpression(.none);
        }

        return .{ .name = param_name, .default_value = default_val, .modifier = mod, .is_keyword = is_keyword };
    }

    fn parseParenParams(self: *Parser) ParseError![]const ast.Param {
        if (self.tokens.current.tag == .l_paren) {
            self.advance();
            const params = try self.parseCommaSeparated(ast.Param, parseParam, .r_paren);
            _ = try self.expect(.r_paren);
            return params;
        }
        return &.{};
    }

    fn parseArrayElement(self: *Parser) ParseError!ast.NodeIndex {
        if (self.tokens.current.tag == .star) {
            const star_loc = self.tokens.current.loc;
            self.advance();
            const inner = try self.parseExpression(.none);
            return self.b.splatExpr(inner, self.getSpan(star_loc)) catch ParseError.OutOfMemory;
        } else {
            return self.parseExpression(.none);
        }
    }

    fn parseHashEntry(self: *Parser) ParseError!ast.HashEntry {
        if (self.tokens.current.tag == .star_star) {
            const star_loc = self.tokens.current.loc;
            self.advance();
            const inner = try self.parseExpression(.none);
            const double_splat = self.b.doubleSplatExpr(inner, self.getSpan(star_loc)) catch return ParseError.OutOfMemory;
            return .{ .key = double_splat, .value = double_splat };
        } else {
            var key: ast.NodeIndex = undefined;
            if (self.tokens.current.tag == .ident and self.tokens.peekTag() == .colon) {
                const key_tok = self.tokens.current;
                self.advance();
                self.advance();
                key = try self.b.symbolNode(key_tok.lexeme, key_tok.loc);

                if (self.tokens.current.tag == .comma or self.tokens.current.tag == .r_brace) {
                    const val = try self.b.identifierNode(key_tok.lexeme, key_tok.loc);
                    return .{ .key = key, .value = val };
                }
            } else {
                key = try self.parseExpression(.none);
                if (self.tokens.current.tag == .colon or self.tokens.current.tag == .arrow) {
                    self.advance();
                } else return ParseError.UnexpectedToken;
            }
            return .{ .key = key, .value = try self.parseExpression(.none) };
        }
    }

    fn isExprListEnd(self: *Parser) bool {
        switch (self.tokens.current.tag) {
            .newline, .eof, .keyword_end, .keyword_unless, .keyword_if, .keyword_while, .keyword_until, .r_brace, .r_bracket, .r_paren => return true,
            else => return false,
        }
    }

    pub fn parseExpression(self: *Parser, precedence: Precedence) ParseError!ast.NodeIndex {
        self.skipIgnored();
        const start_tok = self.tokens.current;
        var left: ast.NodeIndex = .none;

        switch (start_tok.tag) {
            .number => {
                self.advance();
                left = try self.b.number(start_tok.lexeme, start_tok.loc);
            },
            .string => {
                self.advance();
                left = try self.b.stringNode(start_tok.lexeme, start_tok.loc);
            },
            .symbol => {
                self.advance();
                left = try self.b.symbolNode(start_tok.lexeme, start_tok.loc);
            },
            .string_start => left = try self.parseInterpolatedString(),
            .keyword_true => {
                self.advance();
                left = try self.b.booleanNode(true, start_tok.loc);
            },
            .keyword_false => {
                self.advance();
                left = try self.b.booleanNode(false, start_tok.loc);
            },
            .keyword_nil => {
                self.advance();
                left = self.b.nilNode(self.getSpan(start_tok.loc)) catch return ParseError.OutOfMemory;
            },
            .keyword_self => {
                self.advance();
                left = self.b.selfExprNode(self.getSpan(start_tok.loc)) catch return ParseError.OutOfMemory;
            },
            .keyword_super => left = try self.parseSuper(),
            .minus_greater => left = try self.parseLambda(),
            .colon_colon => left = try self.parseTopLevelScopeResolution(),
            .ident, .constant => left = try self.parseIdentifierOrCall(),
            .l_paren => left = try self.parseGroupedExpression(),
            .l_bracket => left = try self.parseArrayLiteral(),
            .l_brace => left = try self.parseHashLiteral(),
            .plus, .minus, .bang, .keyword_not, .tilde => left = try self.parseUnary(),
            .keyword_if => left = try self.parseIfOrUnless(false),
            .keyword_unless => left = try self.parseIfOrUnless(true),
            .keyword_while, .keyword_until => left = try self.parseWhileStatement(),
            .keyword_begin => left = try self.parseBeginStatement(),
            .keyword_case => left = try self.parseCaseStatement(),
            .percent_w, .percent_i => left = try self.parsePercentArray(start_tok.tag),
            else => {
                self.reportError(start_tok.loc, "Invalid expression starting with '{s}'", .{start_tok.lexeme});
                return ParseError.InvalidExpression;
            },
        }

        while (true) {
            if (self.tokens.current.tag == .newline) {
                const next_tag = self.tokens.peekTag();
                if (next_tag == .dot or next_tag == .ampersand_dot) {
                    self.advance();
                } else {
                    break;
                }
            }
            self.skipComments();
            if (@intFromEnum(precedence) >= @intFromEnum(getInfixPrecedence(self.tokens.current.tag))) break;

            const op_tok = self.tokens.current;
            left = switch (op_tok.tag) {
                .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal, .percent_equal, .star_star_equal, .or_or_equal, .and_and_equal, .ampersand_equal, .pipe_equal, .caret_equal, .less_less_equal, .greater_greater_equal => try self.parseAssignmentExpr(left),
                .plus, .minus, .star, .slash, .percent, .star_star, .equal_equal, .bang_equal, .less, .less_equal, .greater, .greater_equal, .and_and, .or_or, .dot_dot, .dot_dot_dot, .less_less, .greater_greater, .keyword_and, .keyword_or, .ampersand, .pipe, .caret => try self.parseBinary(left),
                .question => try self.parseTernary(left),
                .dot => try self.parseMethodCall(left, false),
                .ampersand_dot => try self.parseMethodCall(left, true),
                .colon_colon => try self.parseScopeResolution(left),
                .l_bracket => try self.parseIndexAccessOrAssignment(left),
                .l_paren => try self.parseCallOnExpr(left),
                .keyword_rescue => try self.parseRescueModifierExpr(left),
                else => break,
            };
        }

        return left;
    }

    fn parseExpressionList(self: *Parser) ParseError!ast.NodeIndex {
        const first = try self.parseExpression(.none);

        if (self.tokens.current.tag == .comma) {
            var elements: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
            errdefer elements.deinit(self.allocator);

            try elements.append(self.allocator, first);

            while (self.tokens.current.tag == .comma) {
                self.advance();
                try elements.append(self.allocator, try self.parseExpression(.none));
            }
            const first_node = self.b.tree.getNode(first).?;
            return self.b.arrayLiteral(try self.b.addNodes(elements.items), self.getSpan(first_node.loc)) catch ParseError.OutOfMemory;
        }

        return first;
    }

    fn parseInterpolatedString(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = self.tokens.current;
        var parts: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer parts.deinit(self.allocator);

        try parts.append(self.allocator, try self.b.stringNode(start_tok.lexeme, self.getSpan(start_tok.loc)));
        self.advance();

        while (true) {
            self.skipIgnored();
            if (self.tokens.current.tag != .string_mid and self.tokens.current.tag != .string_end) {
                const expr = try self.parseExpression(.none);
                try parts.append(self.allocator, expr);
            }
            self.skipIgnored();

            if (self.tokens.current.tag == .string_end) {
                try parts.append(self.allocator, try self.b.stringNode(self.tokens.current.lexeme, self.getSpan(self.tokens.current.loc)));
                self.advance();
                break;
            } else if (self.tokens.current.tag == .string_mid) {
                try parts.append(self.allocator, try self.b.stringNode(self.tokens.current.lexeme, self.getSpan(self.tokens.current.loc)));
                self.advance();
            } else {
                return ParseError.UnexpectedToken;
            }
        }

        return self.b.interpolatedString(try self.b.addNodes(parts.items), self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parsePercentArray(self: *Parser, tag: Tag) ParseError!ast.NodeIndex {
        const tok = self.tokens.current;
        self.advance();

        const inner = tok.lexeme[3 .. tok.lexeme.len - 1];
        var iter = std.mem.tokenizeAny(u8, inner, " \t\r\n");
        var elements: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        errdefer elements.deinit(self.allocator);

        while (iter.next()) |word| {
            const interned = try self.b.intern(word);
            if (tag == .percent_w) {
                elements.append(self.allocator, try self.b.createNode(.string, self.getSpan(tok.loc), @intFromEnum(interned))) catch return ParseError.OutOfMemory;
            } else {
                elements.append(self.allocator, try self.b.createNode(.symbol, self.getSpan(tok.loc), @intFromEnum(interned))) catch return ParseError.OutOfMemory;
            }
        }

        return self.b.arrayLiteral(try self.b.addNodes(elements.items), self.getSpan(tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseRescueAndEnsure(self: *Parser) ParseError!RescueEnsurePayload {
        var rescues: std.ArrayListUnmanaged(ast.RescueClause) = .empty;
        errdefer rescues.deinit(self.allocator);

        while (self.tokens.current.tag == .keyword_rescue) {
            self.advance();
            var errors: std.ArrayListUnmanaged(ast.StringId) = .empty;
            errdefer errors.deinit(self.allocator);

            var variable: ast.StringId = .none;

            if (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) {
                while (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) {
                    try errors.append(self.allocator, try self.b.intern(self.tokens.current.lexeme));
                    self.advance();
                    if (self.tokens.current.tag == .comma) self.advance() else break;
                }
            }

            if (self.tokens.current.tag == .arrow) { // => e
                self.advance();
                if (self.tokens.current.tag == .ident) {
                    variable = try self.b.intern(self.tokens.current.lexeme);
                    self.advance();
                }
            }

            self.skipIgnored();
            const rescue_body = try self.parseBlock(&.{ .keyword_rescue, .keyword_ensure, .keyword_end });

            try rescues.append(self.allocator, .{
                .errors = try self.b.addStringLists(errors.items),
                .variable = variable,
                .body = rescue_body,
            });
        }

        var ensure_body: ast.NodeIndex = .none;
        if (self.tokens.current.tag == .keyword_ensure) {
            self.advance();
            self.skipIgnored();
            ensure_body = try self.parseBlock(&.{.keyword_end});
        }

        return .{
            .rescues = try self.b.addRescueClauses(rescues.items),
            .ensure_body = ensure_body,
        };
    }

    fn parseRescueModifierExpr(self: *Parser, left: ast.NodeIndex) ParseError!ast.NodeIndex {
        self.advance();
        const rescue_expr = try self.parseExpression(getInfixPrecedence(.keyword_rescue));
        const left_node = self.b.tree.getNode(left).?;
        return self.b.rescueModifier(left, rescue_expr, self.getSpan(left_node.loc)) catch ParseError.OutOfMemory;
    }

    fn parseTopLevelScopeResolution(self: *Parser) ParseError!ast.NodeIndex {
        const tok = try self.expect(.colon_colon);
        const right_tok = if (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) self.tokens.current else return ParseError.UnexpectedToken;
        self.advance();

        var path_list: std.ArrayListUnmanaged(ast.StringId) = .empty;
        errdefer path_list.deinit(self.allocator);
        try path_list.append(self.allocator, try self.b.intern(right_tok.lexeme));

        return self.b.namespaceAccess(try self.b.addStringLists(path_list.items), self.getSpan(tok.loc)) catch ParseError.OutOfMemory;
    }

    fn isCommandCallStart(self: *Parser) bool {
        const tag = self.tokens.current.tag;
        switch (tag) {
            .newline, .eof, .comment, .param_doc, .r_paren, .r_brace, .r_bracket, .comma, .colon, .string_mid, .string_end, .keyword_rescue, .keyword_else, .keyword_elsif, .keyword_when, .keyword_ensure, .keyword_end, .keyword_if, .keyword_unless, .keyword_while, .keyword_until => return false,
            .keyword_do, .l_brace => return true,
            else => {
                if (isAssignmentOp(tag)) return false;

                const prev_tok = self.tokens.previous;
                const has_space = (prev_tok.loc.line != self.tokens.current.loc.line) or
                    (prev_tok.loc.col + prev_tok.lexeme.len < self.tokens.current.loc.col);

                if (has_space and tag == .l_bracket) return true;
                if (@intFromEnum(getInfixPrecedence(tag)) == 0) return true;

                return false;
            },
        }
    }

    fn parseCommandArgsAndBlock(self: *Parser) ParseError!struct { args: []const ast.NamedArg, block: ?ast.NodeIndex } {
        var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
        errdefer args.deinit(self.allocator);

        while (self.tokens.current.tag != .newline and self.tokens.current.tag != .eof and self.tokens.current.tag != .keyword_do and self.tokens.current.tag != .l_brace and self.tokens.current.tag != .r_paren and self.tokens.current.tag != .r_bracket and self.tokens.current.tag != .r_brace and self.tokens.current.tag != .keyword_if and self.tokens.current.tag != .keyword_unless and self.tokens.current.tag != .keyword_while and self.tokens.current.tag != .keyword_until) {
            try args.append(self.allocator, try self.parseNamedArg());
            if (self.tokens.current.tag == .comma) {
                self.advance();
                self.skipIgnored();
            } else break;
        }

        var block_node: ?ast.NodeIndex = null;
        if (self.tokens.current.tag == .keyword_do or self.tokens.current.tag == .l_brace) {
            block_node = try self.parseBlockClosure();
        }

        return .{ .args = try args.toOwnedSlice(self.allocator), .block = block_node };
    }

    fn parseGroupedExpression(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.l_paren);
        if (self.tokens.current.tag == .r_paren) {
            self.advance();
            return self.b.nilNode(self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
        }
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
            .tilde => .bitwise_not,
            else => .not,
        };

        return self.b.unary(op, try self.parseExpression(.unary), self.getSpan(tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseScopeResolution(self: *Parser, left: ast.NodeIndex) ParseError!ast.NodeIndex {
        _ = try self.expect(.colon_colon);
        const right_tok = if (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) self.tokens.current else return ParseError.UnexpectedToken;
        self.advance();

        const left_node = self.b.tree.getNode(left) orelse return ParseError.InvalidExpression;

        if (left_node.tag == .namespace_access) {
            var path_list: std.ArrayListUnmanaged(ast.StringId) = .empty;
            errdefer path_list.deinit(self.allocator);

            const span = self.b.tree.getSpan(left_node.data);
            try path_list.appendSlice(self.allocator, self.b.tree.getStringLists(span));
            try path_list.append(self.allocator, try self.b.intern(right_tok.lexeme));

            return self.b.namespaceAccess(try self.b.addStringLists(path_list.items), self.getSpan(left_node.loc)) catch ParseError.OutOfMemory;
        } else if (left_node.tag == .identifier) {
            var path_list: std.ArrayListUnmanaged(ast.StringId) = .empty;
            errdefer path_list.deinit(self.allocator);

            try path_list.append(self.allocator, @as(ast.StringId, @enumFromInt(left_node.data)));
            try path_list.append(self.allocator, try self.b.intern(right_tok.lexeme));

            return self.b.namespaceAccess(try self.b.addStringLists(path_list.items), self.getSpan(left_node.loc)) catch ParseError.OutOfMemory;
        } else {
            return ParseError.InvalidExpression;
        }
    }

    fn parseArrayLiteral(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.l_bracket);
        const elements = try self.parseCommaSeparated(ast.NodeIndex, parseArrayElement, .r_bracket);
        _ = try self.expect(.r_bracket);
        return self.b.arrayLiteral(try self.b.addNodes(elements), self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseHashLiteral(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.l_brace);
        const entries = try self.parseCommaSeparated(ast.HashEntry, parseHashEntry, .r_brace);
        _ = try self.expect(.r_brace);
        return self.b.hashLiteral(try self.b.addHashEntries(entries), self.getSpan(start_tok.loc)) catch ParseError.OutOfMemory;
    }

    fn parseBlockParam(self: *Parser) ParseError!ast.NodeIndex {
        if (self.tokens.current.tag == .ident) {
            const tok = self.tokens.current;
            self.advance();
            return self.b.identifierNode(tok.lexeme, self.getSpan(tok.loc)) catch ParseError.OutOfMemory;
        } else if (self.tokens.current.tag == .l_paren) {
            const start_loc = self.tokens.current.loc;
            self.advance();
            const tuple_params = try self.parseCommaSeparated(ast.NodeIndex, parseBlockParam, .r_paren);
            _ = try self.expect(.r_paren);
            return self.b.arrayLiteral(try self.b.addNodes(tuple_params), self.getSpan(start_loc)) catch ParseError.OutOfMemory;
        }
        return ParseError.UnexpectedToken;
    }

    fn getSpan(self: *Parser, start_loc: ast.Location) ast.Location {
        var final_loc = start_loc;
        if (self.tokens.current.loc.offset > start_loc.offset) {
            var raw_len = self.tokens.current.loc.offset - start_loc.offset;
            while (raw_len > 0) {
                const c = self.tokens.lexer.buffer[start_loc.offset + raw_len - 1];
                if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                    raw_len -= 1;
                } else {
                    break;
                }
            }
            final_loc.length = raw_len;
        }
        return final_loc;
    }

    fn getInfixPrecedence(tag: Tag) Precedence {
        return switch (tag) {
            .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal, .percent_equal, .star_star_equal, .or_or_equal, .and_and_equal, .ampersand_equal, .pipe_equal, .caret_equal, .less_less_equal, .greater_greater_equal => .assignment,
            .keyword_rescue => .rescue_mod,
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
