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
    tokens: common_token.TokenList(Tag),
    source: []const u8,
    tok_idx: u24,
    allocator: std.mem.Allocator,
    b: ast.Builder,
    diagnostics: Diagnostics,
    comments: std.ArrayListUnmanaged(common_token.Comment) = .empty,

    // --- Phase 3: Zero-Waste Scratch Buffers ---
    scratch_nodes: std.ArrayListUnmanaged(ast.NodeIndex) = .empty,
    scratch_named_args: std.ArrayListUnmanaged(ast.NamedArg) = .empty,
    scratch_params: std.ArrayListUnmanaged(ast.Param) = .empty,
    scratch_lhs_exprs: std.ArrayListUnmanaged(ast.LhsExpr) = .empty,
    scratch_when_branches: std.ArrayListUnmanaged(ast.WhenBranch) = .empty,
    scratch_rescue_clauses: std.ArrayListUnmanaged(ast.RescueClause) = .empty,
    scratch_strings: std.ArrayListUnmanaged(ast.StringId) = .empty,
    scratch_hash_entries: std.ArrayListUnmanaged(ast.HashEntry) = .empty,

    pub fn init(tokens: common_token.TokenList(Tag), source: []const u8, allocator: std.mem.Allocator) !Parser {
        var parser = Parser{
            .tokens = tokens,
            .source = source,
            .tok_idx = 0,
            .allocator = allocator,
            .b = ast.Builder.init(allocator),
            .diagnostics = Diagnostics.init(allocator),
        };

        // Pre-allocation heuristic: ~1 AST node per 2 tokens
        const estimated_nodes = tokens.tags.len / 2;

        // Pre-allocate AST arrays
        try parser.b.ensureTotalCapacity(allocator, estimated_nodes);

        // Pre-allocate Parser scratch buffers
        try parser.scratch_nodes.ensureTotalCapacity(allocator, estimated_nodes);
        try parser.scratch_named_args.ensureTotalCapacity(allocator, estimated_nodes / 4);
        try parser.scratch_params.ensureTotalCapacity(allocator, estimated_nodes / 8);
        try parser.scratch_lhs_exprs.ensureTotalCapacity(allocator, estimated_nodes / 8);
        try parser.scratch_when_branches.ensureTotalCapacity(allocator, estimated_nodes / 8);
        try parser.scratch_rescue_clauses.ensureTotalCapacity(allocator, estimated_nodes / 8);
        try parser.scratch_strings.ensureTotalCapacity(allocator, estimated_nodes / 4);
        try parser.scratch_hash_entries.ensureTotalCapacity(allocator, estimated_nodes / 4);

        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.b.deinit();
        self.diagnostics.deinit();
        self.comments.deinit(self.allocator);
        self.scratch_nodes.deinit(self.allocator);
        self.scratch_named_args.deinit(self.allocator);
        self.scratch_params.deinit(self.allocator);
        self.scratch_lhs_exprs.deinit(self.allocator);
        self.scratch_when_branches.deinit(self.allocator);
        self.scratch_rescue_clauses.deinit(self.allocator);
        self.scratch_strings.deinit(self.allocator);
        self.scratch_hash_entries.deinit(self.allocator);
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
        if (idx >= self.tokens.starts.len) return .{ .offset = 0, .length = 0, .file_id = 0 };
        return .{
            .offset = self.tokens.starts[idx],
            .length = self.tokens.lengths[idx],
            .file_id = 0,
        };
    }

    pub fn reportError(self: *Parser, loc: ast.Location, comptime fmt: []const u8, args: anytype) void {
        // Prevent duplicate errors at the exact same token offset
        if (self.diagnostics.list.items.len > 0) {
            const last = self.diagnostics.list.items[self.diagnostics.list.items.len - 1];
            if (last.loc.offset == loc.offset) return;
        }
        self.diagnostics.add(loc, fmt, args);
    }

    pub fn synchronize(self: *Parser) void {
        self.advance();
        while (self.tag(0) != .eof) {
            if (self.tag(0) == .newline) return;
            switch (self.tag(0)) {
                .keyword_class, .keyword_def, .keyword_module, .keyword_if, .keyword_unless, .keyword_case, .keyword_while, .keyword_until, .keyword_return, .keyword_begin, .keyword_import, .keyword_export => return,
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
        while (self.tag(0) == .newline or self.tag(0) == .comment) {
            if (self.tag(0) == .comment) {
                self.comments.append(self.allocator, .{
                    .lexeme = self.lexeme(0),
                    .loc = self.getLoc(self.tok_idx),
                }) catch {};
            }
            self.advance();
        }
    }

    fn skipComments(self: *Parser) void {
        while (self.tag(0) == .comment or self.tag(0) == .docstring) {
            if (self.tag(0) == .comment) {
                self.comments.append(self.allocator, .{
                    .lexeme = self.lexeme(0),
                    .loc = self.getLoc(self.tok_idx),
                }) catch {};
            }
            self.advance();
        }
    }

    fn isAssignmentOp(t: Tag) bool {
        return switch (t) {
            .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal, .percent_equal, .star_star_equal, .or_or_equal, .and_and_equal, .ampersand_equal, .pipe_equal, .caret_equal, .less_less_equal, .greater_greater_equal => true,
            else => false,
        };
    }

    fn tagToAssignmentOp(t: Tag) ?ast.BinaryOp {
        return switch (t) {
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

    // Generic zero-waste list parser mapping directly to scratch buffers
    inline fn parseCommaSeparated(
        self: *Parser,
        comptime ItemType: type,
        scratch_list: *std.ArrayListUnmanaged(ItemType),
        comptime parseItemFn: fn (*Parser) ParseError!ItemType,
        end_tag: Tag,
    ) ParseError![]const ItemType {
        const start_idx = scratch_list.items.len;
        while (self.tag(0) != end_tag and self.tag(0) != .eof) {
            self.skipIgnored();
            if (self.tag(0) == end_tag) break;
            try scratch_list.append(self.allocator, try parseItemFn(self));
            self.skipIgnored();
            if (self.tag(0) == .comma) {
                self.advance();
                self.skipIgnored();
            } else {
                break;
            }
        }
        self.skipIgnored();
        return scratch_list.items[start_idx..];
    }

    pub fn parseBlock(self: *Parser, end_tags: []const Tag) ParseError!ast.NodeIndex {
        const start_tok = self.tok_idx;
        const s_len = self.scratch_nodes.items.len;
        defer self.scratch_nodes.shrinkRetainingCapacity(s_len);
        while (self.tag(0) != .eof) {
            self.skipIgnored();
            var is_end = false;
            for (end_tags) |end_tag| {
                if (self.tag(0) == end_tag) {
                    is_end = true;
                    break;
                }
            }
            if (is_end) break;
            if (self.tag(0) == .eof) break;
            if (self.parseStatement()) |parsed_stmt| {
                try self.scratch_nodes.append(self.allocator, parsed_stmt);
            } else |err| {
                if (err == ParseError.OutOfMemory) return err;
                self.synchronize();
            }
        }
        const end_tok = self.tok_idx;
        return self.b.block(&.{}, self.scratch_nodes.items[s_len..], end_tok, start_tok) catch ParseError.OutOfMemory;
    }

    pub fn parseStatement(self: *Parser) ParseError!ast.NodeIndex {
        self.skipIgnored();
        const start_idx = self.tok_idx;

        var stmt = switch (self.tag(0)) {
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
            .docstring => try self.parseDocString(),
            else => try self.parseExprOrMultiAssign(),
        };

        if (self.tag(0) == .keyword_if or self.tag(0) == .keyword_unless or self.tag(0) == .keyword_while or self.tag(0) == .keyword_until) {
            const mod_tag = self.tag(0);
            const mod_tok = self.tok_idx;
            self.advance();
            const cond = try self.parseExpression(.none);
            const stmt_main_token = self.b.tree.getNode(stmt).?.main_token;
            const s_len = self.scratch_nodes.items.len;
            defer self.scratch_nodes.shrinkRetainingCapacity(s_len);
            try self.scratch_nodes.append(self.allocator, stmt);
            const end_tok = self.tok_idx;
            const then_block = self.b.block(&.{}, self.scratch_nodes.items[s_len..], end_tok, stmt_main_token) catch return ParseError.OutOfMemory;

            if (mod_tag == .keyword_if or mod_tag == .keyword_unless) {
                stmt = self.b.ifStmt(cond, then_block, .none, mod_tag == .keyword_unless, end_tok, mod_tok) catch return ParseError.OutOfMemory;
            } else {
                stmt = self.b.whileStmt(cond, then_block, mod_tag == .keyword_until, mod_tok) catch return ParseError.OutOfMemory;
            }
        }

        // Infinite Loop Prevention: Trigger sync if parsing failed to consume any tokens
        if (self.tok_idx == start_idx) {
            return ParseError.InvalidExpression;
        }

        return stmt;
    }

    fn parseExprOrMultiAssign(self: *Parser) ParseError!ast.NodeIndex {
        const t0 = self.tag(0);
        const t1 = self.tag(1);
        const is_multi = if ((t0 == .ident or t0 == .constant or t0 == .star) and (t1 == .comma or t1 == .ident)) self.isMultipleAssignmentStatement() else false;
        if (is_multi) {
            const start_tok = self.tok_idx;
            const s_len = self.scratch_lhs_exprs.items.len;
            defer self.scratch_lhs_exprs.shrinkRetainingCapacity(s_len);
            while (self.tag(0) != .newline and self.tag(0) != .eof and self.tag(0) != .keyword_then) {
                if (isAssignmentOp(self.tag(0))) break;
                var mod: ?ast.ArgModifier = null;
                if (self.tag(0) == .star) {
                    mod = .splat;
                    self.advance();
                }
                if (self.tag(0) == .ident or self.tag(0) == .constant) {
                    try self.scratch_lhs_exprs.append(self.allocator, .{ .name = try self.b.intern(self.lexeme(0)), .modifier = mod });
                    self.advance();
                } else return ParseError.UnexpectedToken;
                if (self.tag(0) == .comma) {
                    self.advance();
                } else break;
            }
            if (isAssignmentOp(self.tag(0))) {
                const op_tag = self.tag(0);
                self.advance();
                const val_node = try self.parseExpressionList();
                const span = try self.b.addLhsExprs(self.scratch_lhs_exprs.items[s_len..]);
                return self.b.multipleAssignment(span, tagToAssignmentOp(op_tag), val_node, start_tok) catch ParseError.OutOfMemory;
            } else return ParseError.UnexpectedToken;
        }
        return try self.parseExpression(.none);
    }

    fn parseLambda(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.minus_greater);
        const params = try self.parseParenParams();
        self.skipIgnored();
        var body: ast.NodeIndex = .none;
        if (self.tag(0) == .l_brace) {
            self.advance();
            body = try self.parseBlock(&.{.r_brace});
            _ = try self.expect(.r_brace);
        } else if (self.tag(0) == .keyword_do) {
            self.advance();
            body = try self.parseBlock(&.{.keyword_end});
            _ = try self.expect(.keyword_end);
        } else {
            return ParseError.UnexpectedToken;
        }
        return self.b.lambdaExpr(params, body, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseAssignmentExpr(self: *Parser, left: ast.NodeIndex) ParseError!ast.NodeIndex {
        const op_tag = self.tag(0);
        const op_tok = self.tok_idx;
        self.advance();
        const value = try self.parseExpressionList();
        const left_node = self.b.tree.getNode(left) orelse return ParseError.InvalidExpression;
        switch (left_node.tag) {
            .identifier => {
                return self.b.assignment(@as(ast.StringId, @enumFromInt(left_node.data)), tagToAssignmentOp(op_tag), value, left_node.main_token) catch ParseError.OutOfMemory;
            },
            .method_call => {
                const mc = self.b.tree.methodCall(left_node);
                if (mc.args.start == mc.args.end and mc.block == .none) {
                    return self.b.propertyAssignment(mc.receiver, mc.method_name, tagToAssignmentOp(op_tag), value, left_node.main_token) catch ParseError.OutOfMemory;
                }
            },
            .index_access => {
                const ia = self.b.tree.indexAccess(left_node);
                return self.b.indexAssignment(ia.target, ia.index, tagToAssignmentOp(op_tag), value, left_node.main_token) catch ParseError.OutOfMemory;
            },
            else => {},
        }
        self.reportError(self.getLoc(op_tok), "Invalid expression starting with '{s}'", .{self.tokens.lexeme(self.source, op_tok)});
        return ParseError.InvalidExpression;
    }

    fn parseBinary(self: *Parser, left: ast.NodeIndex) ParseError!ast.NodeIndex {
        const tok_idx = self.tok_idx;
        const tok_tag = self.tag(0);
        self.advance();
        if (tok_tag == .dot_dot or tok_tag == .dot_dot_dot) {
            return self.b.range(left, try self.parseExpression(.range), .none, (tok_tag == .dot_dot_dot), tok_idx) catch ParseError.OutOfMemory;
        }
        const op = tagToBinaryOp(tok_tag) orelse return ParseError.InvalidExpression;
        const next_prec = if (tok_tag == .star_star)
            @as(Precedence, @enumFromInt(@intFromEnum(getInfixPrecedence(tok_tag)) - 1))
        else
            getInfixPrecedence(tok_tag);
        const left_main_token = self.b.tree.getNode(left).?.main_token;
        return self.b.binary(op, left, try self.parseExpression(next_prec), left_main_token) catch ParseError.OutOfMemory;
    }

    fn parseTernary(self: *Parser, condition: ast.NodeIndex) ParseError!ast.NodeIndex {
        _ = try self.expect(.question);
        const then_branch = try self.parseExpression(.none);
        _ = try self.expect(.colon);
        const else_branch = try self.parseExpression(.none);
        const cond_main_token = self.b.tree.getNode(condition).?.main_token;
        return self.b.ternary(condition, then_branch, else_branch, cond_main_token) catch ParseError.OutOfMemory;
    }

    fn parseIndexAccessOrAssignment(self: *Parser, target: ast.NodeIndex) ParseError!ast.NodeIndex {
        _ = try self.expect(.l_bracket);
        const target_main_token = self.b.tree.getNode(target).?.main_token;
        const index = try self.parseExpressionList();
        _ = try self.expect(.r_bracket);
        if (isAssignmentOp(self.tag(0))) {
            const op_tag = self.tag(0);
            self.advance();
            const value = try self.parseExpressionList();
            return self.b.indexAssignment(target, index, tagToAssignmentOp(op_tag), value, target_main_token) catch ParseError.OutOfMemory;
        }
        return self.b.indexAccess(target, index, target_main_token) catch ParseError.OutOfMemory;
    }

    fn parseBlockClosure(self: *Parser) ParseError!ast.NodeIndex {
        const is_brace = (self.tag(0) == .l_brace);
        const start_tok = if (is_brace) try self.expect(.l_brace) else try self.expect(.keyword_do);
        const params_start = self.scratch_nodes.items.len;
        defer self.scratch_nodes.shrinkRetainingCapacity(params_start);
        var params_len: usize = 0;
        if (self.tag(0) == .pipe) {
            self.advance();
            const elements = try self.parseCommaSeparated(ast.NodeIndex, &self.scratch_nodes, parseBlockParam, .pipe);
            params_len = elements.len;
            _ = try self.expect(.pipe);
        }
        const end_tags: []const Tag = if (is_brace) &.{.r_brace} else &.{.keyword_end};
        const block_node_idx = try self.parseBlock(end_tags);
        const end_tok = self.tok_idx;
        if (is_brace) {
            _ = try self.expect(.r_brace);
        } else {
            _ = try self.expect(.keyword_end);
        }
        const block_node = self.b.tree.getNode(block_node_idx).?;
        const block_payload = self.b.tree.block(block_node);
        const stmts_start = self.scratch_nodes.items.len;
        try self.scratch_nodes.appendSlice(self.allocator, self.b.tree.getNodes(block_payload.stmts));
        const safe_params = self.scratch_nodes.items[params_start .. params_start + params_len];
        const safe_stmts = self.scratch_nodes.items[stmts_start..self.scratch_nodes.items.len];
        return self.b.block(safe_params, safe_stmts, end_tok, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseBeginStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_begin);
        self.skipIgnored();
        const body = try self.parseBlock(&.{ .keyword_rescue, .keyword_ensure, .keyword_end });
        const payload = try self.parseRescueAndEnsure();
        _ = try self.expect(.keyword_end);
        return self.b.beginStmt(body, payload.rescues, payload.ensure_body, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseImportOrExportStatement(self: *Parser, is_export: bool) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(if (is_export) .keyword_export else .keyword_import);
        const s_len = self.scratch_strings.items.len;
        defer self.scratch_strings.shrinkRetainingCapacity(s_len);
        if (self.tag(0) == .l_brace) {
            self.advance();
            while (self.tag(0) != .r_brace and self.tag(0) != .eof) {
                self.skipIgnored();
                if (self.tag(0) == .ident or self.tag(0) == .constant) {
                    try self.scratch_strings.append(self.allocator, try self.b.intern(self.lexeme(0)));
                    self.advance();
                } else return ParseError.UnexpectedToken;
                if (self.tag(0) == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_brace);
            _ = try self.expect(.keyword_from);
        } else if (self.tag(0) == .constant or self.tag(0) == .ident) {
            try self.scratch_strings.append(self.allocator, try self.b.intern(self.lexeme(0)));
            self.advance();
            _ = try self.expect(.keyword_from);
        } else if (self.tag(0) != .string) {
            return ParseError.UnexpectedToken;
        }
        const path_idx = try self.expect(.string);
        const interned_path = try self.b.intern(self.tokens.lexeme(self.source, path_idx));
        var attributes: ast.NodeIndex = .none;
        self.skipIgnored();
        if (self.tag(0) == .keyword_with) {
            self.advance();
            attributes = try self.parseHashLiteral();
        }
        const span = try self.b.addStringLists(self.scratch_strings.items[s_len..]);
        if (is_export) {
            return self.b.exportStmt(span, interned_path, attributes, start_tok) catch ParseError.OutOfMemory;
        } else {
            return self.b.importStmt(span, interned_path, attributes, start_tok) catch ParseError.OutOfMemory;
        }
    }

    fn parseIfOrUnless(self: *Parser, is_unless: bool) ParseError!ast.NodeIndex {
        const start_tok = self.tok_idx;
        self.advance();
        const condition = try self.parseExpression(.none);
        if (self.tag(0) == .keyword_then) self.advance();
        self.skipIgnored();
        const then_branch = try self.parseBlock(&.{ .keyword_elsif, .keyword_else, .keyword_end });
        var else_branch: ast.NodeIndex = .none;
        if (self.tag(0) == .keyword_elsif) {
            else_branch = try self.parseIfOrUnless(false);
        } else if (self.tag(0) == .keyword_else) {
            self.advance();
            self.skipIgnored();
            else_branch = try self.parseBlock(&.{.keyword_end});
            _ = try self.expect(.keyword_end);
        } else if (self.tag(0) == .keyword_end) {
            self.advance();
        }
        const end_tok = self.tok_idx;
        return self.b.ifStmt(condition, then_branch, else_branch, is_unless, end_tok, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseCaseStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_case);
        var condition: ast.NodeIndex = .none;
        if (self.tag(0) != .newline and self.tag(0) != .keyword_when) {
            condition = try self.parseExpression(.none);
        }
        if (self.tag(0) == .keyword_then) self.advance();
        self.skipIgnored();
        const s_len = self.scratch_when_branches.items.len;
        defer self.scratch_when_branches.shrinkRetainingCapacity(s_len);
        while (self.tag(0) == .keyword_when) {
            self.advance();
            var cond_span: ast.Span = undefined;
            {
                const cond_s_len = self.scratch_nodes.items.len;
                defer self.scratch_nodes.shrinkRetainingCapacity(cond_s_len);
                while (self.tag(0) != .newline and self.tag(0) != .eof and self.tag(0) != .keyword_then) {
                    try self.scratch_nodes.append(self.allocator, try self.parseExpression(.none));
                    if (self.tag(0) == .comma) self.advance() else break;
                }
                cond_span = try self.b.addNodes(self.scratch_nodes.items[cond_s_len..]);
            }
            if (self.tag(0) == .keyword_then) self.advance();
            self.skipIgnored();
            const body = try self.parseBlock(&.{ .keyword_when, .keyword_else, .keyword_end });
            try self.scratch_when_branches.append(self.allocator, .{
                .conditions = cond_span,
                .body = body,
            });
        }
        var else_branch: ast.NodeIndex = .none;
        if (self.tag(0) == .keyword_else) {
            self.advance();
            self.skipIgnored();
            else_branch = try self.parseBlock(&.{.keyword_end});
        }
        _ = try self.expect(.keyword_end);
        const branches_span = try self.b.addWhenBranches(self.scratch_when_branches.items[s_len..]);
        return self.b.caseStmt(condition, branches_span, else_branch, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseWhileStatement(self: *Parser) ParseError!ast.NodeIndex {
        const is_until = (self.tag(0) == .keyword_until);
        const start_tok = self.tok_idx;
        self.advance();
        const condition = try self.parseExpression(.none);
        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);
        return self.b.whileStmt(condition, body, is_until, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseDefStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_def);
        var is_class_method = false;
        var name_idx: u24 = undefined;
        if (self.tag(0) == .keyword_self and self.tag(1) == .dot) {
            is_class_method = true;
            self.advance();
            self.advance();
            if (self.tag(0) != .ident and self.tag(0) != .constant) return ParseError.UnexpectedToken;
            name_idx = self.tok_idx;
            self.advance();
        } else {
            if (self.tag(0) != .ident and self.tag(0) != .constant) return ParseError.UnexpectedToken;
            name_idx = self.tok_idx;
            self.advance();
        }
        var params_span: ast.Span = .{ .start = 0, .end = 0 };
        if (self.tag(0) == .l_paren) {
            params_span = try self.parseParenParams();
        } else {
            const s_len = self.scratch_params.items.len;
            defer self.scratch_params.shrinkRetainingCapacity(s_len);
            while (self.tag(0) != .newline and self.tag(0) != .eof and self.tag(0) != .comment) {
                try self.scratch_params.append(self.allocator, try self.parseParam());
                if (self.tag(0) == .comma) {
                    self.advance();
                } else break;
            }
            params_span = try self.b.addParams(self.scratch_params.items[s_len..]);
        }
        self.skipIgnored();
        const body_node = try self.parseBlock(&.{ .keyword_rescue, .keyword_ensure, .keyword_end });
        const payload = try self.parseRescueAndEnsure();
        const end_tok = self.tok_idx;
        _ = try self.expect(.keyword_end);
        var final_body = body_node;
        if (payload.rescues.start != payload.rescues.end or payload.ensure_body != .none) {
            final_body = self.b.beginStmt(body_node, payload.rescues, payload.ensure_body, start_tok) catch return ParseError.OutOfMemory;
        }
        return self.b.defStmt(try self.b.intern(self.tokens.lexeme(self.source, name_idx)), params_span, final_body, is_class_method, end_tok, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseModuleStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_module);
        const name_idx = if (self.tag(0) == .constant or self.tag(0) == .ident) self.tok_idx else return ParseError.UnexpectedToken;
        self.advance();
        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        const end_tok = self.tok_idx;
        _ = try self.expect(.keyword_end);
        return self.b.moduleStmt(try self.b.intern(self.tokens.lexeme(self.source, name_idx)), try self.b.addParams(&.{}), body, end_tok, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseClassPath(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = self.tok_idx;
        if (self.tag(0) != .constant and self.tag(0) != .ident) {
            self.reportError(self.getLoc(start_tok), "Expected 'constant', but found '{s}'", .{self.lexeme(0)});
            return ParseError.UnexpectedToken;
        }
        const s_len = self.scratch_strings.items.len;
        defer self.scratch_strings.shrinkRetainingCapacity(s_len);
        while (self.tag(0) == .constant or self.tag(0) == .ident) {
            try self.scratch_strings.append(self.allocator, try self.b.intern(self.lexeme(0)));
            self.advance();
            if (self.tag(0) == .colon_colon) {
                self.advance();
            } else break;
        }
        if (self.scratch_strings.items.len - s_len == 1) {
            return self.b.createNode(.identifier, start_tok, @intFromEnum(self.scratch_strings.items[s_len])) catch ParseError.OutOfMemory;
        } else {
            const span = try self.b.addStringLists(self.scratch_strings.items[s_len..]);
            return self.b.namespaceAccess(span, start_tok) catch ParseError.OutOfMemory;
        }
    }

    fn parseClassStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_class);
        const name_node = try self.parseClassPath();
        var super_class: ast.NodeIndex = .none;
        if (self.tag(0) == .less) {
            self.advance();
            super_class = try self.parseClassPath();
        }
        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        const end_tok = self.tok_idx;
        _ = try self.expect(.keyword_end);
        return self.b.classStmt(name_node, super_class, body, end_tok, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseSuper(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_super);
        if (self.tag(0) == .l_paren) {
            const args = try self.parseParenArgs();
            var block_node: ast.NodeIndex = .none;
            if (self.tag(0) == .keyword_do or self.tag(0) == .l_brace) block_node = try self.parseBlockClosure();
            return self.b.superCall(args, block_node, start_tok) catch ParseError.OutOfMemory;
        }
        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            return self.b.superCall(cmd.args, cmd.block orelse .none, start_tok) catch ParseError.OutOfMemory;
        }
        return self.b.superCall(try self.b.addNamedArgs(&.{}), .none, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseCallOnExpr(self: *Parser, receiver_expr: ast.NodeIndex) ParseError!ast.NodeIndex {
        const args = try self.parseParenArgs();
        var block_node: ast.NodeIndex = .none;
        if (self.tag(0) == .keyword_do or self.tag(0) == .l_brace) block_node = try self.parseBlockClosure();
        const rec_node = self.b.tree.getNode(receiver_expr) orelse return ParseError.InvalidExpression;
        const rec_main_token = rec_node.main_token;
        const rec_tag = rec_node.tag;
        const rec_data = rec_node.data;
        const end_tok = self.tok_idx;
        if (rec_tag == .identifier) {
            return self.b.methodCall(.none, @as(ast.StringId, @enumFromInt(rec_data)), args, block_node, false, end_tok, rec_main_token) catch ParseError.OutOfMemory;
        } else {
            return self.b.methodCall(receiver_expr, try self.b.intern(""), args, block_node, false, end_tok, rec_main_token) catch ParseError.OutOfMemory;
        }
    }

    fn parseMethodCall(self: *Parser, receiver: ast.NodeIndex, is_safe: bool) ParseError!ast.NodeIndex {
        if (self.tag(0) == .dot or self.tag(0) == .ampersand_dot) self.advance();
        const method_idx = try self.expect(.ident);
        const rec_main_token = self.b.tree.getNode(receiver).?.main_token;
        if (self.tag(0) == .l_paren) {
            const args = try self.parseParenArgs();
            var block_node: ast.NodeIndex = .none;
            if (self.tag(0) == .keyword_do or self.tag(0) == .l_brace) block_node = try self.parseBlockClosure();
            const end_tok = self.tok_idx;
            return self.b.methodCall(receiver, try self.b.intern(self.tokens.lexeme(self.source, method_idx)), args, block_node, is_safe, end_tok, rec_main_token) catch ParseError.OutOfMemory;
        }
        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            const end_tok = self.tok_idx;
            return self.b.methodCall(receiver, try self.b.intern(self.tokens.lexeme(self.source, method_idx)), cmd.args, cmd.block orelse .none, is_safe, end_tok, rec_main_token) catch ParseError.OutOfMemory;
        }
        const end_tok = self.tok_idx;
        return self.b.methodCall(receiver, try self.b.intern(self.tokens.lexeme(self.source, method_idx)), try self.b.addNamedArgs(&.{}), .none, is_safe, end_tok, rec_main_token) catch ParseError.OutOfMemory;
    }

    fn parseIdentifierOrCall(self: *Parser) ParseError!ast.NodeIndex {
        const tok_idx = self.tok_idx;
        const tok_tag = self.tag(0);
        if (tok_tag != .ident and tok_tag != .constant) {
            self.reportError(self.getLoc(tok_idx), "Expected identifier or constant", .{});
            return ParseError.UnexpectedToken;
        }
        self.advance();
        if (self.tag(0) == .l_paren) {
            const args = try self.parseParenArgs();
            var block_node: ast.NodeIndex = .none;
            if (self.tag(0) == .keyword_do or self.tag(0) == .l_brace) {
                block_node = try self.parseBlockClosure();
            }
            const end_tok = self.tok_idx;
            return self.b.methodCall(.none, try self.b.intern(self.tokens.lexeme(self.source, tok_idx)), args, block_node, false, end_tok, tok_idx) catch ParseError.OutOfMemory;
        }
        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            const end_tok = self.tok_idx;
            return self.b.methodCall(.none, try self.b.intern(self.tokens.lexeme(self.source, tok_idx)), cmd.args, cmd.block orelse .none, false, end_tok, tok_idx) catch ParseError.OutOfMemory;
        }
        return self.b.identifierNode(self.tokens.lexeme(self.source, tok_idx), tok_idx) catch ParseError.OutOfMemory;
    }

    pub fn parseProgram(self: *Parser) ParseError!ast.NodeIndex {
        return self.parseBlock(&.{});
    }

    fn isMultipleAssignmentStatement(self: *Parser) bool {
        var temp_idx = self.tok_idx;
        var has_comma = false;
        while (true) {
            const curr = if (temp_idx < self.tokens.tags.len) self.tokens.tags[temp_idx] else .eof;
            if (curr == .newline or curr == .eof) break;
            if (isAssignmentOp(curr)) return has_comma;
            if (curr == .comma) {
                has_comma = true;
            } else if (curr != .ident and curr != .constant and curr != .star) {
                return false;
            }
            temp_idx += 1;
        }
        return false;
    }

    fn parseNextStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_next);
        var val: ast.NodeIndex = .none;
        if (!self.isExprListEnd()) {
            val = try self.parseExpressionList();
        }
        return self.b.nextStmt(val, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseReturnStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_return);
        var val: ast.NodeIndex = .none;
        if (!self.isExprListEnd()) {
            val = try self.parseExpressionList();
        }
        return self.b.returnStmt(val, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseBreakStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_break);
        var val: ast.NodeIndex = .none;
        if (!self.isExprListEnd()) {
            val = try self.parseExpressionList();
        }
        return self.b.breakStmt(val, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseYieldStatement(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.keyword_yield);
        const s_len = self.scratch_nodes.items.len;
        defer self.scratch_nodes.shrinkRetainingCapacity(s_len);
        if (self.tag(0) == .l_paren) {
            self.advance();
            while (self.tag(0) != .r_paren and self.tag(0) != .eof) {
                try self.scratch_nodes.append(self.allocator, try self.parseExpression(.none));
                if (self.tag(0) == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
        } else {
            while (!self.isExprListEnd()) {
                try self.scratch_nodes.append(self.allocator, try self.parseExpression(.none));
                if (self.tag(0) == .comma) self.advance() else break;
            }
        }
        const span = try self.b.addNodes(self.scratch_nodes.items[s_len..]);
        return self.b.yieldStmt(span, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseDocString(self: *Parser) ParseError!ast.NodeIndex {
        const tok_idx = try self.expect(.docstring);
        var doc_parser = docstring.DocstringParser{ .allocator = self.allocator, .b = &self.b };
        return doc_parser.parse(self.tokens.lexeme(self.source, tok_idx), tok_idx) catch return ParseError.OutOfMemory;
    }

    fn parseArgModifier(self: *Parser) ?ast.ArgModifier {
        switch (self.tag(0)) {
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
        if (self.tag(0) == .comma or self.tag(0) == .r_paren) {
            const val = try self.b.undefNode(self.tok_idx);
            return .{ .name = .none, .value = val, .modifier = null };
        }
        const mod = self.parseArgModifier();
        var arg_name: ast.StringId = .none;
        if (self.tag(0) == .ident and self.tag(1) == .colon) {
            arg_name = try self.b.intern(self.lexeme(0));
            self.advance();
            self.advance();
        }
        const val = try self.parseExpression(.none);
        return .{ .name = arg_name, .value = val, .modifier = mod };
    }

    fn parseParenArgs(self: *Parser) ParseError!ast.Span {
        if (self.tag(0) == .l_paren) {
            self.advance();
            const s_len = self.scratch_named_args.items.len;
            defer self.scratch_named_args.shrinkRetainingCapacity(s_len);
            const elements = try self.parseCommaSeparated(ast.NamedArg, &self.scratch_named_args, parseNamedArg, .r_paren);
            _ = try self.expect(.r_paren);
            return try self.b.addNamedArgs(elements);
        }
        return try self.b.addNamedArgs(&.{});
    }

    fn parseParam(self: *Parser) ParseError!ast.Param {
        const mod = self.parseArgModifier(); // Automatically handles *, **, and &

        const name_tok = try self.expect(.ident);
        const name_id = try self.b.intern(self.tokens.lexeme(self.source, name_tok));

        var default_val: ast.NodeIndex = .none;
        var is_keyword = false;

        if (self.tag(0) == .colon) {
            if (mod != null) return ParseError.InvalidExpression;
            is_keyword = true;
            self.advance();
            // In KupCAD, `x: 10` assigns 10 as the default.
            if (self.tag(0) != .comma and self.tag(0) != .r_paren) {
                default_val = try self.parseExpression(.none);
            }
        } else if (self.tag(0) == .equal) {
            if (mod != null) return ParseError.InvalidExpression;
            self.advance();
            default_val = try self.parseExpression(.none);
        }

        return .{
            .name = name_id,
            .default_value = default_val,
            .modifier = mod,
            .is_keyword = is_keyword,
        };
    }

    fn parseParenParams(self: *Parser) ParseError!ast.Span {
        if (self.tag(0) == .l_paren) {
            self.advance();
            const s_len = self.scratch_params.items.len;
            defer self.scratch_params.shrinkRetainingCapacity(s_len);
            const elements = try self.parseCommaSeparated(ast.Param, &self.scratch_params, parseParam, .r_paren);
            _ = try self.expect(.r_paren);
            return try self.b.addParams(elements);
        }
        return try self.b.addParams(&.{});
    }

    fn parseArrayElement(self: *Parser) ParseError!ast.NodeIndex {
        if (self.tag(0) == .star) {
            const star_tok = self.tok_idx;
            self.advance();
            const inner = try self.parseExpression(.none);
            return self.b.splatExpr(inner, star_tok) catch ParseError.OutOfMemory;
        } else {
            return self.parseExpression(.none);
        }
    }

    fn parseHashEntry(self: *Parser) ParseError!ast.HashEntry {
        if (self.tag(0) == .star_star) {
            const star_tok = self.tok_idx;
            self.advance();
            const inner = try self.parseExpression(.none);
            const double_splat = self.b.doubleSplatExpr(inner, star_tok) catch return ParseError.OutOfMemory;
            return .{ .key = double_splat, .value = double_splat };
        } else {
            var key: ast.NodeIndex = undefined;
            if (self.tag(0) == .ident and self.tag(1) == .colon) {
                const key_tok = self.tok_idx;
                self.advance();
                self.advance();
                key = try self.b.symbolNode(self.tokens.lexeme(self.source, key_tok), key_tok);
                if (self.tag(0) == .comma or self.tag(0) == .r_brace) {
                    const val = try self.b.identifierNode(self.tokens.lexeme(self.source, key_tok), key_tok);
                    return .{ .key = key, .value = val };
                }
            } else {
                key = try self.parseExpression(.none);
                if (self.tag(0) == .colon or self.tag(0) == .arrow) {
                    self.advance();
                } else return ParseError.UnexpectedToken;
            }
            return .{ .key = key, .value = try self.parseExpression(.none) };
        }
    }

    fn isExprListEnd(self: *Parser) bool {
        switch (self.tag(0)) {
            .newline, .eof, .keyword_end, .keyword_unless, .keyword_if, .keyword_while, .keyword_until, .r_brace, .r_bracket, .r_paren => return true,
            else => return false,
        }
    }

    pub fn parseExpression(self: *Parser, precedence: Precedence) ParseError!ast.NodeIndex {
        self.skipIgnored();
        const start_tok = self.tok_idx;
        const start_tag = self.tag(0);
        var left: ast.NodeIndex = .none;

        switch (start_tag) {
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
            .symbol => {
                self.advance();
                left = try self.b.symbolNode(self.tokens.lexeme(self.source, start_tok), start_tok);
            },
            .string_start => left = try self.parseInterpolatedString(),
            .keyword_true => {
                self.advance();
                left = try self.b.booleanNode(true, start_tok);
            },
            .keyword_false => {
                self.advance();
                left = try self.b.booleanNode(false, start_tok);
            },
            .keyword_nil => {
                self.advance();
                left = self.b.nilNode(start_tok) catch return ParseError.OutOfMemory;
            },
            .keyword_self => {
                self.advance();
                left = self.b.selfExprNode(start_tok) catch return ParseError.OutOfMemory;
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
            .percent_w, .percent_i => left = try self.parsePercentArray(start_tag),
            .invalid => {
                self.reportError(self.getLoc(start_tok), "Interpolation depth exceeded", .{});
                left = try self.b.invalidNode(start_tok);
            },
            else => {
                self.reportError(self.getLoc(start_tok), "Invalid expression starting with '{s}'", .{self.lexeme(0)});
                left = try self.b.invalidNode(start_tok);
            },
        }

        while (true) {
            if (self.tag(0) == .newline) {
                const next_tag = self.tag(1);
                if (next_tag == .dot or next_tag == .ampersand_dot) {
                    self.advance();
                } else {
                    break;
                }
            }

            self.skipComments();
            if (@intFromEnum(precedence) >= @intFromEnum(getInfixPrecedence(self.tag(0)))) break;

            const op_tag = self.tag(0);
            left = switch (op_tag) {
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
        if (self.tag(0) == .comma) {
            const first_node_main_token = self.b.tree.getNode(first).?.main_token;
            const s_len = self.scratch_nodes.items.len;
            defer self.scratch_nodes.shrinkRetainingCapacity(s_len);
            try self.scratch_nodes.append(self.allocator, first);
            while (self.tag(0) == .comma) {
                self.advance();
                try self.scratch_nodes.append(self.allocator, try self.parseExpression(.none));
            }
            const span = try self.b.addNodes(self.scratch_nodes.items[s_len..]);
            const end_tok = self.tok_idx;
            return self.b.arrayLiteral(span, end_tok, first_node_main_token) catch ParseError.OutOfMemory;
        }
        return first;
    }

    fn parseInterpolatedString(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = self.tok_idx;
        const s_len = self.scratch_nodes.items.len;
        defer self.scratch_nodes.shrinkRetainingCapacity(s_len);

        try self.scratch_nodes.append(self.allocator, try self.b.stringNode(self.lexeme(0), start_tok));
        self.advance();

        while (true) {
            self.skipIgnored();

            if (self.tag(0) == .invalid) {
                self.reportError(self.getLoc(self.tok_idx), "Interpolation depth exceeded", .{});
                try self.scratch_nodes.append(self.allocator, try self.b.invalidNode(self.tok_idx));
                self.advance();
                break;
            }

            if (self.tag(0) != .string_mid and self.tag(0) != .string_end) {
                const expr = try self.parseExpression(.none);
                try self.scratch_nodes.append(self.allocator, expr);
            }

            self.skipIgnored();

            if (self.tag(0) == .string_end) {
                try self.scratch_nodes.append(self.allocator, try self.b.stringNode(self.lexeme(0), self.tok_idx));
                self.advance();
                break;
            } else if (self.tag(0) == .string_mid) {
                try self.scratch_nodes.append(self.allocator, try self.b.stringNode(self.lexeme(0), self.tok_idx));
                self.advance();
            } else {
                return ParseError.UnexpectedToken;
            }
        }

        const span = try self.b.addNodes(self.scratch_nodes.items[s_len..]);
        return self.b.interpolatedString(span, start_tok) catch ParseError.OutOfMemory;
    }

    fn parsePercentArray(self: *Parser, t: Tag) ParseError!ast.NodeIndex {
        const tok_idx = self.tok_idx;
        const lexeme_str = self.lexeme(0);
        self.advance();
        const inner = lexeme_str[3 .. lexeme_str.len - 1];
        var iter = std.mem.tokenizeAny(u8, inner, " \t\r\n");
        const s_len = self.scratch_nodes.items.len;
        defer self.scratch_nodes.shrinkRetainingCapacity(s_len);
        while (iter.next()) |word| {
            const interned = try self.b.intern(word);
            if (t == .percent_w) {
                try self.scratch_nodes.append(self.allocator, try self.b.createNode(.string, tok_idx, @intFromEnum(interned)));
            } else {
                try self.scratch_nodes.append(self.allocator, try self.b.createNode(.symbol, tok_idx, @intFromEnum(interned)));
            }
        }
        const span = try self.b.addNodes(self.scratch_nodes.items[s_len..]);
        const end_tok = self.tok_idx;
        return self.b.arrayLiteral(span, end_tok, tok_idx) catch ParseError.OutOfMemory;
    }

    fn parseRescueAndEnsure(self: *Parser) ParseError!RescueEnsurePayload {
        const s_len = self.scratch_rescue_clauses.items.len;
        defer self.scratch_rescue_clauses.shrinkRetainingCapacity(s_len);
        while (self.tag(0) == .keyword_rescue) {
            self.advance();
            var variable: ast.StringId = .none;
            var errors_span: ast.Span = .{ .start = 0, .end = 0 };
            if (self.tag(0) == .constant or self.tag(0) == .ident) {
                const str_s_len = self.scratch_strings.items.len;
                defer self.scratch_strings.shrinkRetainingCapacity(str_s_len);
                while (self.tag(0) == .constant or self.tag(0) == .ident) {
                    try self.scratch_strings.append(self.allocator, try self.b.intern(self.lexeme(0)));
                    self.advance();
                    if (self.tag(0) == .comma) self.advance() else break;
                }
                errors_span = try self.b.addStringLists(self.scratch_strings.items[str_s_len..]);
            }
            if (self.tag(0) == .arrow) {
                self.advance();
                if (self.tag(0) == .ident) {
                    variable = try self.b.intern(self.lexeme(0));
                    self.advance();
                }
            }
            self.skipIgnored();
            const rescue_body = try self.parseBlock(&.{ .keyword_rescue, .keyword_ensure, .keyword_end });
            try self.scratch_rescue_clauses.append(self.allocator, .{
                .errors = errors_span,
                .variable = variable,
                .body = rescue_body,
            });
        }
        var ensure_body: ast.NodeIndex = .none;
        if (self.tag(0) == .keyword_ensure) {
            self.advance();
            self.skipIgnored();
            ensure_body = try self.parseBlock(&.{.keyword_end});
        }
        return .{
            .rescues = try self.b.addRescueClauses(self.scratch_rescue_clauses.items[s_len..]),
            .ensure_body = ensure_body,
        };
    }

    fn parseRescueModifierExpr(self: *Parser, left: ast.NodeIndex) ParseError!ast.NodeIndex {
        self.advance();
        const left_main_token = self.b.tree.getNode(left).?.main_token;
        const rescue_expr = try self.parseExpression(getInfixPrecedence(.keyword_rescue));
        return self.b.rescueModifier(left, rescue_expr, left_main_token) catch ParseError.OutOfMemory;
    }

    fn parseTopLevelScopeResolution(self: *Parser) ParseError!ast.NodeIndex {
        const tok_idx = try self.expect(.colon_colon);
        const right_idx = if (self.tag(0) == .constant or self.tag(0) == .ident) self.tok_idx else return ParseError.UnexpectedToken;
        self.advance();
        const s_len = self.scratch_strings.items.len;
        defer self.scratch_strings.shrinkRetainingCapacity(s_len);
        try self.scratch_strings.append(self.allocator, try self.b.intern(self.tokens.lexeme(self.source, right_idx)));
        const span = try self.b.addStringLists(self.scratch_strings.items[s_len..]);
        return self.b.namespaceAccess(span, tok_idx) catch ParseError.OutOfMemory;
    }

    fn isCommandCallStart(self: *Parser) bool {
        const t = self.tag(0);
        switch (t) {
            .newline, .eof, .comment, .docstring, .r_paren, .r_brace, .r_bracket, .comma, .colon, .string_mid, .string_end, .keyword_rescue, .keyword_else, .keyword_elsif, .keyword_when, .keyword_ensure, .keyword_end, .keyword_if, .keyword_unless, .keyword_while, .keyword_until => return false,
            .keyword_do, .l_brace => return true,
            else => {
                if (isAssignmentOp(t)) return false;
                const prev_idx = if (self.tok_idx > 0) self.tok_idx - 1 else 0;
                const prev_end = self.tokens.starts[prev_idx] + self.tokens.lengths[prev_idx];
                const curr_start = self.tokens.starts[self.tok_idx];
                const has_space = curr_start > prev_end;
                if (has_space and t == .l_bracket) return true;
                if (@intFromEnum(getInfixPrecedence(t)) == 0) return true;
                return false;
            },
        }
    }

    fn parseCommandArgsAndBlock(self: *Parser) ParseError!struct { args: ast.Span, block: ?ast.NodeIndex } {
        const s_len = self.scratch_named_args.items.len;
        defer self.scratch_named_args.shrinkRetainingCapacity(s_len);
        while (self.tag(0) != .newline and self.tag(0) != .eof and self.tag(0) != .keyword_do and self.tag(0) != .l_brace and self.tag(0) != .r_paren and self.tag(0) != .r_bracket and self.tag(0) != .r_brace and self.tag(0) != .keyword_if and self.tag(0) != .keyword_unless and self.tag(0) != .keyword_while and self.tag(0) != .keyword_until) {
            try self.scratch_named_args.append(self.allocator, try self.parseNamedArg());
            if (self.tag(0) == .comma) {
                self.advance();
                self.skipIgnored();
            } else break;
        }
        const args_span = try self.b.addNamedArgs(self.scratch_named_args.items[s_len..]);
        var block_node: ?ast.NodeIndex = null;
        if (self.tag(0) == .keyword_do or self.tag(0) == .l_brace) {
            block_node = try self.parseBlockClosure();
        }
        return .{ .args = args_span, .block = block_node };
    }

    fn parseGroupedExpression(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.l_paren);
        if (self.tag(0) == .r_paren) {
            self.advance();
            return self.b.nilNode(start_tok) catch ParseError.OutOfMemory;
        }
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
            .tilde => .bitwise_not,
            else => .not,
        };
        return self.b.unary(op, try self.parseExpression(.unary), tok_idx) catch ParseError.OutOfMemory;
    }

    fn parseScopeResolution(self: *Parser, left: ast.NodeIndex) ParseError!ast.NodeIndex {
        _ = try self.expect(.colon_colon);
        const right_idx = if (self.tag(0) == .constant or self.tag(0) == .ident) self.tok_idx else return ParseError.UnexpectedToken;
        self.advance();
        const left_node = self.b.tree.getNode(left) orelse return ParseError.InvalidExpression;
        const left_tag = left_node.tag;
        const left_data = left_node.data;
        const left_main_token = left_node.main_token;
        if (left_tag == .namespace_access) {
            const s_len = self.scratch_strings.items.len;
            defer self.scratch_strings.shrinkRetainingCapacity(s_len);
            const span = self.b.tree.nodeSpan(left_node);
            try self.scratch_strings.appendSlice(self.allocator, self.b.tree.getStringLists(span));
            try self.scratch_strings.append(self.allocator, try self.b.intern(self.tokens.lexeme(self.source, right_idx)));
            const new_span = try self.b.addStringLists(self.scratch_strings.items[s_len..]);
            return self.b.namespaceAccess(new_span, left_main_token) catch ParseError.OutOfMemory;
        } else if (left_tag == .identifier) {
            const s_len = self.scratch_strings.items.len;
            defer self.scratch_strings.shrinkRetainingCapacity(s_len);
            try self.scratch_strings.append(self.allocator, @as(ast.StringId, @enumFromInt(left_data)));
            try self.scratch_strings.append(self.allocator, try self.b.intern(self.tokens.lexeme(self.source, right_idx)));
            const new_span = try self.b.addStringLists(self.scratch_strings.items[s_len..]);
            return self.b.namespaceAccess(new_span, left_main_token) catch ParseError.OutOfMemory;
        } else {
            return ParseError.InvalidExpression;
        }
    }

    fn parseArrayLiteral(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.l_bracket);
        const s_len = self.scratch_nodes.items.len;
        defer self.scratch_nodes.shrinkRetainingCapacity(s_len);
        const elements = try self.parseCommaSeparated(ast.NodeIndex, &self.scratch_nodes, parseArrayElement, .r_bracket);
        const end_tok = self.tok_idx;
        _ = try self.expect(.r_bracket);
        const span = try self.b.addNodes(elements);
        return self.b.arrayLiteral(span, end_tok, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseHashLiteral(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = try self.expect(.l_brace);
        const s_len = self.scratch_hash_entries.items.len;
        defer self.scratch_hash_entries.shrinkRetainingCapacity(s_len);
        const entries = try self.parseCommaSeparated(ast.HashEntry, &self.scratch_hash_entries, parseHashEntry, .r_brace);
        _ = try self.expect(.r_brace);
        const span = try self.b.addHashEntries(entries);
        return self.b.hashLiteral(span, start_tok) catch ParseError.OutOfMemory;
    }

    fn parseBlockParam(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = self.tok_idx;
        if (self.tag(0) == .star) {
            self.advance();
            const ident_tok = try self.expect(.ident);
            const ident_node = try self.b.identifierNode(self.tokens.lexeme(self.source, ident_tok), ident_tok);
            return self.b.splatExpr(ident_node, start_tok) catch ParseError.OutOfMemory;
        } else if (self.tag(0) == .star_star) {
            self.advance();
            const ident_tok = try self.expect(.ident);
            const ident_node = try self.b.identifierNode(self.tokens.lexeme(self.source, ident_tok), ident_tok);
            return self.b.doubleSplatExpr(ident_node, start_tok) catch ParseError.OutOfMemory;
        } else if (self.tag(0) == .ident) {
            self.advance();
            return self.b.identifierNode(self.tokens.lexeme(self.source, start_tok), start_tok) catch ParseError.OutOfMemory;
        } else if (self.tag(0) == .l_paren) {
            self.advance();
            const s_len = self.scratch_nodes.items.len;
            defer self.scratch_nodes.shrinkRetainingCapacity(s_len);
            const tuple_params = try self.parseCommaSeparated(ast.NodeIndex, &self.scratch_nodes, parseBlockParam, .r_paren);
            const end_tok = self.tok_idx;
            _ = try self.expect(.r_paren);
            const span = try self.b.addNodes(tuple_params);
            return self.b.arrayLiteral(span, end_tok, start_tok) catch ParseError.OutOfMemory;
        }
        return ParseError.UnexpectedToken;
    }

    fn parseAssertOrEcho(self: *Parser) ParseError!ast.NodeIndex {
        const start_tok = self.tok_idx;
        self.advance();
        const args = try self.parseParenArgs();
        const end_tok = self.tok_idx;
        const call_node = self.b.methodCall(.none, try self.b.intern(self.tokens.lexeme(self.source, start_tok)), args, .none, false, end_tok, start_tok) catch return ParseError.OutOfMemory;
        if (self.tag(0) == .semicolon) {
            self.advance();
            return call_node;
        } else if (self.tag(0) == .l_brace) {
            self.advance();
            const child_block = try self.parseBlock(&.{.r_brace});
            _ = try self.expect(.r_brace);
            const call_data = self.b.tree.getNode(call_node).?.data;
            self.b.tree.extra_data.items[call_data + 4] = @intFromEnum(child_block);
            return call_node;
        } else if (self.tag(0) != .r_brace and self.tag(0) != .eof) {
            const child_stmt = try self.parseStatement();
            const s_len = self.scratch_nodes.items.len;
            defer self.scratch_nodes.shrinkRetainingCapacity(s_len);
            try self.scratch_nodes.append(self.allocator, child_stmt);
            const child_main_token = self.b.tree.getNode(child_stmt).?.main_token;
            const child_end_tok = self.tok_idx;
            const block = try self.b.block(&.{}, self.scratch_nodes.items[s_len..], child_end_tok, child_main_token);
            const call_data = self.b.tree.getNode(call_node).?.data;
            self.b.tree.extra_data.items[call_data + 4] = @intFromEnum(block);
            return call_node;
        }
        return call_node;
    }

    fn getInfixPrecedence(t: Tag) Precedence {
        return switch (t) {
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

    fn tagToBinaryOp(t: Tag) ?ast.BinaryOp {
        return switch (t) {
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
