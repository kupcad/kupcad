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

const RescueEnsurePayload = struct {
    rescues: []const ast.RescueClause,
    ensure_body: ?*Node,
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

    pub fn init(lexer: *Lexer, allocator: std.mem.Allocator) Parser {
        return Parser{
            .tokens = common_token.BufferedLexer(Lexer, Token, Tag).init(lexer),
            .allocator = allocator,
            .b = ast.Builder.init(allocator, ast.Dialect.kupcad),
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
        self.advance(); // Skip the token that triggered the error

        while (self.tokens.current.tag != .eof) {
            // If we just consumed a newline, we are safely at the start of a new line
            if (self.tokens.previous.tag == .newline) return;

            // Otherwise, look for keywords that definitively start a new statement
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
        while (self.tokens.current.tag == .newline or self.tokens.current.tag == .comment) self.advance();
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

    pub fn parseBlock(self: *Parser, end_tags: []const Tag) ParseError!*Node {
        const start_loc = self.tokens.current.loc;
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer stmts.deinit(self.allocator);

        while (self.tokens.current.tag != .eof) {
            var is_end = false;
            for (end_tags) |end_tag| {
                if (self.tokens.current.tag == end_tag) {
                    is_end = true;
                    break;
                }
            }
            if (is_end) break;

            if (self.tokens.current.tag == .newline or self.tokens.current.tag == .comment) {
                self.advance();
                continue;
            }

            if (self.parseStatement()) |parsed_stmt| {
                try stmts.append(self.allocator, parsed_stmt);
            } else |err| {
                // Never swallow OutOfMemory; only swallow syntax errors
                if (err == ParseError.OutOfMemory) return err;
                self.synchronize();
            }
            if (self.tokens.current.tag == .newline) self.advance();
        }

        return self.createNode(.{ .block = try self.b.box(ast.Block, .{ .stmts = try stmts.toOwnedSlice(self.allocator) }) }, start_loc);
    }

    pub fn parseStatement(self: *Parser) ParseError!*Node {
        self.skipIgnored();
        var stmt = switch (self.tokens.current.tag) {
            .keyword_import => try self.parseImportOrExportStatement(false),
            .keyword_export => try self.parseImportOrExportStatement(true),
            .keyword_if => try self.parseIfOrUnless(false),
            .keyword_unless => try self.parseIfOrUnless(true),
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

        if (self.tokens.current.tag == .keyword_if or self.tokens.current.tag == .keyword_unless or self.tokens.current.tag == .keyword_while or self.tokens.current.tag == .keyword_until) {
            const mod_tag = self.tokens.current.tag;
            const mod_loc = self.tokens.current.loc;
            self.advance();

            const cond = try self.parseExpression(.none);
            const then_block = try self.createNode(.{
                .block = try self.b.box(ast.Block, .{ .stmts = try self.allocator.dupe(*Node, &.{stmt}) }),
            }, stmt.loc);

            if (mod_tag == .keyword_if or mod_tag == .keyword_unless) {
                stmt = try self.createNode(.{
                    .if_stmt = try self.b.box(ast.IfStmt, .{ .condition = cond, .then_branch = then_block, .else_branch = null, .is_unless = (mod_tag == .keyword_unless) }),
                }, mod_loc);
            } else {
                stmt = try self.createNode(.{
                    .while_stmt = try self.b.box(ast.WhileStmt, .{ .condition = cond, .body = then_block, .is_until = (mod_tag == .keyword_until) }),
                }, mod_loc);
            }
        }

        return stmt;
    }

    fn parseExprOrMultiAssign(self: *Parser) ParseError!*Node {
        const is_multi = if ((self.tokens.current.tag == .ident or self.tokens.current.tag == .constant or self.tokens.current.tag == .star) and (self.tokens.peekTag() == .comma or self.tokens.peekTag() == .ident)) self.isMultipleAssignmentStatement() else false;

        if (is_multi) {
            const start_loc = self.tokens.current.loc;
            var lhs_list: std.ArrayListUnmanaged(ast.LhsExpr) = .empty;
            errdefer lhs_list.deinit(self.allocator);

            while (self.tokens.current.tag != .newline and self.tokens.current.tag != .eof and self.tokens.current.tag != .keyword_then) {
                var mod: ?ast.ArgModifier = null;
                if (self.tokens.current.tag == .star) {
                    mod = .splat;
                    self.advance();
                }
                if (self.tokens.current.tag == .ident or self.tokens.current.tag == .constant) {
                    try lhs_list.append(self.allocator, .{ .name = self.tokens.current.lexeme, .modifier = mod });
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

                return self.createNode(.{
                    .multiple_assignment = try self.b.box(ast.MultipleAssignment, .{
                        .lhs = try lhs_list.toOwnedSlice(self.allocator),
                        .op = tagToAssignmentOp(op_tag),
                        .value = val_node,
                    }),
                }, start_loc);
            } else return ParseError.UnexpectedToken;
        }
        return try self.parseExpression(.none);
    }

    fn parseLambda(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.minus_greater);
        const params = try self.parseParenParams();
        self.skipIgnored();

        var body: *Node = undefined;
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

        return self.createNode(.{ .lambda_expr = try self.b.box(ast.LambdaExpr, .{ .params = params, .body = body }) }, start_tok.loc);
    }

    fn parseAssignmentExpr(self: *Parser, left: *Node) ParseError!*Node {
        const op_tag = self.tokens.current.tag;
        self.advance();

        // Use ExpressionList to capture `x = 1, 2` as an ArrayLiteral
        const value = try self.parseExpressionList();

        if (left.kind.kupcad == .identifier) {
            return self.createNode(.{ .assignment = try self.b.box(ast.Assignment, .{
                .name = left.kind.kupcad.identifier,
                .op = tagToAssignmentOp(op_tag),
                .value = value,
            }) }, left.loc);
        } else if (left.kind.kupcad == .method_call and left.kind.kupcad.method_call.args.len == 0 and left.kind.kupcad.method_call.block == null) {
            return self.createNode(.{ .property_assignment = try self.b.box(ast.PropertyAssignment, .{
                .target = left.kind.kupcad.method_call.receiver orelse return ParseError.InvalidExpression,
                .property = left.kind.kupcad.method_call.method_name,
                .op = tagToAssignmentOp(op_tag),
                .value = value,
            }) }, left.loc);
        }
        return ParseError.InvalidExpression;
    }

    fn parseBinary(self: *Parser, left: *Node) ParseError!*Node {
        const tok = self.tokens.current;
        self.advance();

        if (tok.tag == .dot_dot or tok.tag == .dot_dot_dot) {
            return self.createNode(.{ .range = try self.b.box(ast.Range, .{ .start = left, .end = try self.parseExpression(.range), .is_exclusive = (tok.tag == .dot_dot_dot) }) }, tok.loc);
        }

        const op = tagToBinaryOp(tok.tag) orelse return ParseError.InvalidExpression;
        const next_prec = if (tok.tag == .star_star)
            @as(Precedence, @enumFromInt(@intFromEnum(getInfixPrecedence(tok.tag)) - 1))
        else
            getInfixPrecedence(tok.tag);

        return self.createNode(.{
            .binary_op = try self.b.box(ast.BinaryExpr, .{ .op = op, .left = left, .right = try self.parseExpression(next_prec) }),
        }, tok.loc);
    }

    fn parseTernary(self: *Parser, condition: *Node) ParseError!*Node {
        const q_tok = try self.expect(.question);
        const then_branch = try self.parseExpression(.none);
        _ = try self.expect(.colon);
        const else_branch = try self.parseExpression(.none);

        return self.createNode(.{ .ternary_op = try self.b.box(ast.TernaryExpr, .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch }) }, q_tok.loc);
    }

    fn parseIndexAccessOrAssignment(self: *Parser, target: *Node) ParseError!*Node {
        const bracket_tok = try self.expect(.l_bracket);

        const index = try self.parseExpressionList();

        _ = try self.expect(.r_bracket);

        if (isAssignmentOp(self.tokens.current.tag)) {
            const op_tag = self.tokens.current.tag;
            self.advance();
            return self.createNode(.{
                .index_assignment = try self.b.box(ast.IndexAssignment, .{
                    .target = target,
                    .index = index,
                    .op = tagToAssignmentOp(op_tag),
                    .value = try self.parseExpressionList(),
                }),
            }, bracket_tok.loc);
        }

        return self.createNode(.{ .index_access = .{ .target = target, .index = index } }, bracket_tok.loc);
    }

    fn parseBlockClosure(self: *Parser) ParseError!*Node {
        const is_brace = (self.tokens.current.tag == .l_brace);
        const start_tok = if (is_brace) try self.expect(.l_brace) else try self.expect(.keyword_do);

        var params: []const *Node = &.{};
        if (self.tokens.current.tag == .pipe) {
            self.advance();
            params = try self.parseCommaSeparated(*Node, parseBlockParam, .pipe);
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
            .block = try self.b.box(ast.Block, .{ .params = params, .stmts = block_node.kind.kupcad.block.stmts }),
        }, start_tok.loc);
    }

    fn parseBeginStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_begin);
        self.skipIgnored();
        const body = try self.parseBlock(&.{ .keyword_rescue, .keyword_ensure, .keyword_end });

        const payload = try self.parseRescueAndEnsure();

        _ = try self.expect(.keyword_end);

        return self.createNode(.{
            .begin_stmt = try self.b.box(ast.BeginStmt, .{
                .body = body,
                .rescues = payload.rescues, // <-- Use payload here
                .ensure_body = payload.ensure_body, // <-- Use payload here
            }),
        }, start_tok.loc);
    }

    fn parseImportOrExportStatement(self: *Parser, is_export: bool) ParseError!*Node {
        const start_tok = try self.expect(if (is_export) .keyword_export else .keyword_import);

        var symbols: std.ArrayListUnmanaged([]const u8) = .empty;
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

        var attributes: ?*Node = null;
        self.skipIgnored();
        if (self.tokens.current.tag == .keyword_with) {
            self.advance();
            attributes = try self.parseHashLiteral();
        }

        if (is_export) {
            return self.createNode(.{
                .export_stmt = try self.b.box(ast.ExportStmt, .{ .symbols = try symbols.toOwnedSlice(self.allocator), .path = interned_path, .attributes = attributes }),
            }, start_tok.loc);
        } else {
            return self.createNode(.{
                .import_stmt = try self.b.box(ast.ImportStmt, .{ .symbols = try symbols.toOwnedSlice(self.allocator), .path = interned_path, .attributes = attributes }),
            }, start_tok.loc);
        }
    }

    fn parseIfOrUnless(self: *Parser, is_unless: bool) ParseError!*Node {
        const start_tok = self.tokens.current;
        self.advance(); // consume if, unless, or elsif

        const condition = try self.parseExpression(.none);
        if (self.tokens.current.tag == .keyword_then) self.advance();
        self.skipIgnored();

        const then_branch = try self.parseBlock(&.{ .keyword_elsif, .keyword_else, .keyword_end });
        var else_branch: ?*Node = null;

        if (self.tokens.current.tag == .keyword_elsif) {
            // 'elsif' is logically an 'if' chain mapped into the else_branch
            else_branch = try self.parseIfOrUnless(false);
        } else if (self.tokens.current.tag == .keyword_else) {
            self.advance();
            self.skipIgnored();
            else_branch = try self.parseBlock(&.{.keyword_end});
            _ = try self.expect(.keyword_end);
        } else if (self.tokens.current.tag == .keyword_end) {
            self.advance();
        }

        return self.createNode(.{
            .if_stmt = try self.b.box(ast.IfStmt, .{
                .condition = condition,
                .then_branch = then_branch,
                .else_branch = else_branch,
                .is_unless = is_unless,
            }),
        }, start_tok.loc);
    }

    fn parseCaseStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_case);
        var condition: ?*Node = null;

        if (self.tokens.current.tag != .newline and self.tokens.current.tag != .keyword_when) {
            condition = try self.parseExpression(.none);
        }
        if (self.tokens.current.tag == .keyword_then) self.advance();

        self.skipIgnored();

        var when_branches: std.ArrayListUnmanaged(ast.WhenBranch) = .empty;
        errdefer when_branches.deinit(self.allocator);

        while (self.tokens.current.tag == .keyword_when) {
            self.advance();
            var conditions: std.ArrayListUnmanaged(*Node) = .empty;
            errdefer conditions.deinit(self.allocator);

            while (self.tokens.current.tag != .newline and self.tokens.current.tag != .eof and self.tokens.current.tag != .keyword_then) {
                try conditions.append(self.allocator, try self.parseExpression(.none));
                if (self.tokens.current.tag == .comma) self.advance() else break;
            }

            if (self.tokens.current.tag == .keyword_then) self.advance();

            self.skipIgnored();

            const body = try self.parseBlock(&.{ .keyword_when, .keyword_else, .keyword_end });
            try when_branches.append(self.allocator, .{
                .conditions = try conditions.toOwnedSlice(self.allocator),
                .body = body,
            });
        }

        var else_branch: ?*Node = null;
        if (self.tokens.current.tag == .keyword_else) {
            self.advance();
            self.skipIgnored();
            else_branch = try self.parseBlock(&.{.keyword_end});
        }
        _ = try self.expect(.keyword_end);

        return self.createNode(.{
            .case_stmt = try self.b.box(ast.CaseStmt, .{
                .condition = condition,
                .when_branches = try when_branches.toOwnedSlice(self.allocator),
                .else_branch = else_branch,
            }),
        }, start_tok.loc);
    }

    fn parseWhileStatement(self: *Parser) ParseError!*Node {
        const is_until = (self.tokens.current.tag == .keyword_until);
        const start_tok = self.tokens.current;
        self.advance();

        const condition = try self.parseExpression(.none);
        self.skipIgnored();

        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.createNode(.{ .while_stmt = try self.b.box(ast.WhileStmt, .{ .condition = condition, .body = body, .is_until = is_until }) }, start_tok.loc);
    }

    fn parseDefStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_def);
        var is_class_method = false;
        var name_tok: Token = undefined;

        if (self.tokens.current.tag == .keyword_self and self.tokens.peekTag() == .dot) {
            is_class_method = true;
            self.advance();
            self.advance();
            name_tok = if (self.tokens.current.tag == .ident or self.tokens.current.tag == .constant) self.tokens.current else return ParseError.UnexpectedToken;
            self.advance();
        } else {
            name_tok = if (self.tokens.current.tag == .ident or self.tokens.current.tag == .constant) self.tokens.current else return ParseError.UnexpectedToken;
            self.advance();
        }

        var params: []const ast.Param = &.{};
        if (self.tokens.current.tag == .l_paren) {
            params = try self.parseParenParams();
        } else {
            // Parenthesis-less parameters: loop until newline or EOF
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

        // Wrap in an implicit begin_stmt if rescue or ensure were present
        if (payload.rescues.len > 0 or payload.ensure_body != null) {
            final_body = try self.createNode(.{
                .begin_stmt = try self.b.box(ast.BeginStmt, .{
                    .body = body_node,
                    .rescues = payload.rescues, // <-- Use payload here
                    .ensure_body = payload.ensure_body, // <-- Use payload here
                }),
            }, start_tok.loc);
        }

        return self.createNode(.{
            .def_stmt = try self.b.box(ast.DefStmt, .{
                .name = name_tok.lexeme,
                .params = params,
                .body = final_body,
                .is_class_method = is_class_method,
            }),
        }, start_tok.loc);
    }

    fn parseModuleStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_module);
        const name_tok = if (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) self.tokens.current else return ParseError.UnexpectedToken;
        self.advance();

        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.createNode(.{ .module_stmt = try self.b.box(ast.ModuleStmt, .{ .name = name_tok.lexeme, .body = body }) }, start_tok.loc);
    }

    fn parseSuper(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.keyword_super);
        if (self.tokens.current.tag == .l_paren) {
            const args = try self.parseParenArgs();
            var block_node: ?*Node = null;
            if (self.tokens.current.tag == .keyword_do or self.tokens.current.tag == .l_brace) block_node = try self.parseBlockClosure();
            return self.createNode(.{
                .super_call = try self.b.box(ast.SuperCall, .{ .args = args, .block = block_node }),
            }, tok.loc);
        }

        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            return self.createNode(.{
                .super_call = try self.b.box(ast.SuperCall, .{ .args = cmd.args, .block = cmd.block }),
            }, tok.loc);
        }

        return self.createNode(.{
            .super_call = try self.b.box(ast.SuperCall, .{ .args = &.{}, .block = null }),
        }, tok.loc);
    }

    fn parseCallOnExpr(self: *Parser, receiver_expr: *Node) ParseError!*Node {
        const args = try self.parseParenArgs();
        var block_node: ?*Node = null;

        if (self.tokens.current.tag == .keyword_do or self.tokens.current.tag == .l_brace) block_node = try self.parseBlockClosure();

        if (receiver_expr.kind.kupcad == .identifier) {
            return self.createNode(.{
                .method_call = try self.b.box(ast.MethodCall, .{ .receiver = null, .method_name = receiver_expr.kind.kupcad.identifier, .args = args, .block = block_node }),
            }, receiver_expr.loc);
        } else {
            return self.createNode(.{
                .method_call = try self.b.box(ast.MethodCall, .{ .receiver = receiver_expr, .method_name = "", .args = args, .block = block_node }),
            }, receiver_expr.loc);
        }
    }

    fn parseMethodCall(self: *Parser, receiver: *Node, is_safe: bool) ParseError!*Node {
        if (self.tokens.current.tag == .dot or self.tokens.current.tag == .ampersand_dot) self.advance();
        const method_tok = try self.expect(.ident);

        if (self.tokens.current.tag == .l_paren) {
            const args = try self.parseParenArgs();
            var block_node: ?*Node = null;
            if (self.tokens.current.tag == .keyword_do or self.tokens.current.tag == .l_brace) block_node = try self.parseBlockClosure();

            return self.createNode(.{
                .method_call = try self.b.box(ast.MethodCall, .{ .receiver = receiver, .method_name = method_tok.lexeme, .args = args, .block = block_node, .is_safe = is_safe }),
            }, method_tok.loc);
        }

        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            return self.createNode(.{
                .method_call = try self.b.box(ast.MethodCall, .{ .receiver = receiver, .method_name = method_tok.lexeme, .args = cmd.args, .block = cmd.block, .is_safe = is_safe }),
            }, method_tok.loc);
        }

        return self.createNode(.{
            .method_call = try self.b.box(ast.MethodCall, .{ .receiver = receiver, .method_name = method_tok.lexeme, .args = &.{}, .block = null, .is_safe = is_safe }),
        }, method_tok.loc);
    }

    fn parseIdentifierOrCall(self: *Parser) ParseError!*Node {
        const tok = self.tokens.current;
        self.advance();

        if (self.tokens.current.tag == .l_paren) {
            const args = try self.parseParenArgs();

            var block_node: ?*Node = null;
            if (self.tokens.current.tag == .keyword_do or self.tokens.current.tag == .l_brace) {
                block_node = try self.parseBlockClosure();
            }

            return self.createNode(.{
                .method_call = try self.b.box(ast.MethodCall, .{
                    .receiver = null,
                    .method_name = tok.lexeme,
                    .args = args,
                    .block = block_node, // <-- Pass the captured block
                    .is_safe = false,
                }),
            }, tok.loc);
        }

        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            return self.createNode(.{
                .method_call = try self.b.box(ast.MethodCall, .{
                    .receiver = null,
                    .method_name = tok.lexeme,
                    .args = cmd.args,
                    .block = cmd.block,
                    .is_safe = false,
                }),
            }, tok.loc);
        }
        return self.b.identifierNode(tok.lexeme, tok.loc);
    }

    pub fn parseProgram(self: *Parser) ParseError!*Node {
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

    fn parseNextStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_next);
        var val: ?*Node = null;
        if (!self.isExprListEnd()) {
            val = try self.parseExpressionList();
        }
        return self.createNode(.{ .next_stmt = val }, start_tok.loc);
    }

    fn parseClassPath(self: *Parser) ParseError!*Node {
        const start_loc = self.tokens.current.loc;

        if (self.tokens.current.tag != .constant and self.tokens.current.tag != .ident) {
            self.reportError(start_loc, "Expected 'constant', but found '{s}'", .{self.tokens.current.lexeme});
            return ParseError.UnexpectedToken;
        }

        var path_list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer path_list.deinit(self.allocator);

        while (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) {
            try path_list.append(self.allocator, self.tokens.current.lexeme);
            self.advance();
            if (self.tokens.current.tag == .colon_colon) {
                self.advance();
            } else break;
        }

        if (path_list.items.len == 1) {
            return self.b.identifierNode(path_list.items[0], start_loc);
        } else {
            return self.createNode(.{ .namespace_access = .{ .path = try path_list.toOwnedSlice(self.allocator) } }, start_loc);
        }
    }

    fn parseClassStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_class);

        const name_node = try self.parseClassPath();

        var super_class: ?*Node = null;
        if (self.tokens.current.tag == .less) {
            self.advance();
            super_class = try self.parseClassPath();
        }

        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        return self.createNode(.{ .class_stmt = try self.b.box(ast.ClassStmt, .{ .name = name_node, .super_class = super_class, .body = body }) }, start_tok.loc);
    }

    fn parseReturnStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_return);
        var val: ?*Node = null;
        if (!self.isExprListEnd()) {
            val = try self.parseExpressionList();
        }
        return self.createNode(.{ .return_stmt = val }, start_tok.loc);
    }

    fn parseYieldStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_yield);
        var args: std.ArrayListUnmanaged(*Node) = .empty;
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
        return self.createNode(.{ .yield_stmt = try args.toOwnedSlice(self.allocator) }, start_tok.loc);
    }

    fn parseBreakStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_break);
        var val: ?*Node = null;
        if (!self.isExprListEnd()) {
            val = try self.parseExpressionList();
        }
        return self.createNode(.{ .break_stmt = val }, start_tok.loc);
    }

    fn parseParamDoc(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.param_doc);
        return self.createNode(.{ .param_doc = tok.lexeme }, tok.loc);
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
            return .{ .name = "", .value = val, .modifier = null };
        }
        const mod = self.parseArgModifier();
        var arg_name: []const u8 = "";

        if (self.tokens.current.tag == .ident and self.tokens.peekTag() == .colon) {
            arg_name = self.tokens.current.lexeme;
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

        const param_name = self.tokens.current.lexeme;
        self.advance();

        var is_keyword = false;
        var default_val: ?*Node = null;

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

    fn parseArrayElement(self: *Parser) ParseError!*Node {
        if (self.tokens.current.tag == .star) {
            const star_loc = self.tokens.current.loc;
            self.advance();
            const inner = try self.parseExpression(.none);
            return self.createNode(.{ .splat_expr = inner }, star_loc);
        } else {
            return self.parseExpression(.none);
        }
    }

    fn parseHashEntry(self: *Parser) ParseError!ast.HashEntry {
        if (self.tokens.current.tag == .star_star) {
            const star_loc = self.tokens.current.loc;
            self.advance();
            const inner = try self.parseExpression(.none);
            const double_splat = try self.createNode(.{ .double_splat_expr = inner }, star_loc);
            return .{ .key = double_splat, .value = double_splat };
        } else {
            var key: *Node = undefined;
            if (self.tokens.current.tag == .ident and self.tokens.peekTag() == .colon) {
                const key_tok = self.tokens.current;
                self.advance();
                self.advance();
                key = try self.b.symbolNode(key_tok.lexeme, key_tok.loc);
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
            .keyword_if => left = try self.parseIfOrUnless(false),
            .keyword_unless => left = try self.parseIfOrUnless(true),
            .keyword_begin => left = try self.parseBeginStatement(),
            .keyword_case => left = try self.parseCaseStatement(),
            .percent_w, .percent_i => left = try self.parsePercentArray(start_tok.tag),
            else => {
                self.reportError(start_tok.loc, "Invalid expression starting with '{s}'", .{start_tok.lexeme});
                return ParseError.InvalidExpression;
            },
        }

        while (true) {
            // Handle multi-line method chaining (Fluent API)
            if (self.tokens.current.tag == .newline) {
                const next_tag = self.tokens.peekTag();
                if (next_tag == .dot or next_tag == .ampersand_dot) {
                    self.advance(); // consume newline to continue the chain
                } else {
                    break; // normal end of statement
                }
            }

            // Allow mid-expression comments
            while (self.tokens.current.tag == .comment) self.advance();
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

    fn parseExpressionList(self: *Parser) ParseError!*Node {
        const first = try self.parseExpression(.none);
        if (self.tokens.current.tag == .comma) {
            var elements: std.ArrayListUnmanaged(*Node) = .empty;
            errdefer elements.deinit(self.allocator);
            try elements.append(self.allocator, first);
            while (self.tokens.current.tag == .comma) {
                self.advance();
                try elements.append(self.allocator, try self.parseExpression(.none));
            }
            return self.createNode(.{ .array_literal = try elements.toOwnedSlice(self.allocator) }, first.loc);
        }
        return first;
    }

    fn parseInterpolatedString(self: *Parser) ParseError!*Node {
        const start_tok = self.tokens.current;
        var parts: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer parts.deinit(self.allocator);

        try parts.append(self.allocator, try self.createNode(.{ .string = start_tok.lexeme }, start_tok.loc));
        self.advance();

        while (true) {
            self.skipIgnored();
            if (self.tokens.current.tag != .string_mid and self.tokens.current.tag != .string_end) {
                const expr = try self.parseExpression(.none);
                try parts.append(self.allocator, expr);
            }
            self.skipIgnored();
            if (self.tokens.current.tag == .string_end) {
                try parts.append(self.allocator, try self.createNode(.{ .string = self.tokens.current.lexeme }, self.tokens.current.loc));
                self.advance();
                break;
            } else if (self.tokens.current.tag == .string_mid) {
                try parts.append(self.allocator, try self.createNode(.{ .string = self.tokens.current.lexeme }, self.tokens.current.loc));
                self.advance();
            } else {
                return ParseError.UnexpectedToken;
            }
        }
        return self.createNode(.{ .interpolated_string = try parts.toOwnedSlice(self.allocator) }, start_tok.loc);
    }

    fn parsePercentArray(self: *Parser, tag: Tag) ParseError!*Node {
        const tok = self.tokens.current;
        self.advance();
        const inner = tok.lexeme[3 .. tok.lexeme.len - 1];
        var iter = std.mem.tokenizeAny(u8, inner, " \t\r\n");

        var elements: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer elements.deinit(self.allocator);

        while (iter.next()) |word| {
            const interned = try self.b.intern(word);
            if (tag == .percent_w) {
                elements.append(self.allocator, try self.createNode(.{ .string = interned }, tok.loc)) catch return ParseError.OutOfMemory;
            } else {
                elements.append(self.allocator, try self.createNode(.{ .symbol = interned }, tok.loc)) catch return ParseError.OutOfMemory;
            }
        }
        return self.createNode(.{ .array_literal = try elements.toOwnedSlice(self.allocator) }, tok.loc);
    }

    fn parseRescueAndEnsure(self: *Parser) ParseError!RescueEnsurePayload {
        var rescues: std.ArrayListUnmanaged(ast.RescueClause) = .empty;
        errdefer rescues.deinit(self.allocator);

        while (self.tokens.current.tag == .keyword_rescue) {
            self.advance();
            var errors: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer errors.deinit(self.allocator);
            var variable: ?[]const u8 = null;

            if (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) {
                while (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) {
                    try errors.append(self.allocator, self.tokens.current.lexeme);
                    self.advance();
                    if (self.tokens.current.tag == .comma) self.advance() else break;
                }
            }

            if (self.tokens.current.tag == .arrow) { // => e
                self.advance();
                if (self.tokens.current.tag == .ident) {
                    variable = self.tokens.current.lexeme;
                    self.advance();
                }
            }

            self.skipIgnored();
            const rescue_body = try self.parseBlock(&.{ .keyword_rescue, .keyword_ensure, .keyword_end });

            try rescues.append(self.allocator, .{
                .errors = try errors.toOwnedSlice(self.allocator),
                .variable = variable,
                .body = rescue_body,
            });
        }

        var ensure_body: ?*Node = null;
        if (self.tokens.current.tag == .keyword_ensure) {
            self.advance();
            self.skipIgnored();
            ensure_body = try self.parseBlock(&.{.keyword_end});
        }

        return .{
            .rescues = try rescues.toOwnedSlice(self.allocator),
            .ensure_body = ensure_body,
        };
    }

    fn parseRescueModifierExpr(self: *Parser, left: *Node) ParseError!*Node {
        const tok = self.tokens.current;
        self.advance();
        const rescue_expr = try self.parseExpression(getInfixPrecedence(.keyword_rescue));
        return self.createNode(.{ .rescue_modifier = .{ .expr = left, .rescue_expr = rescue_expr } }, tok.loc);
    }

    fn parseTopLevelScopeResolution(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.colon_colon);
        const right_tok = if (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) self.tokens.current else return ParseError.UnexpectedToken;
        self.advance();

        var path_list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer path_list.deinit(self.allocator);
        try path_list.append(self.allocator, right_tok.lexeme);

        return self.createNode(.{
            .namespace_access = .{ .path = try path_list.toOwnedSlice(self.allocator) },
        }, tok.loc);
    }

    fn isCommandCallStart(self: *Parser) bool {
        const tag = self.tokens.current.tag;

        switch (tag) {
            .newline, .eof, .r_paren, .r_brace, .r_bracket, .comma, .colon, .string_mid, .string_end, .keyword_rescue, .keyword_else, .keyword_elsif, .keyword_when, .keyword_ensure, .keyword_end, .keyword_if, .keyword_unless, .keyword_while, .keyword_until => return false,

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

    fn parseCommandArgsAndBlock(self: *Parser) ParseError!struct { args: []const ast.NamedArg, block: ?*Node } {
        var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
        errdefer args.deinit(self.allocator);

        while (self.tokens.current.tag != .newline and self.tokens.current.tag != .eof and self.tokens.current.tag != .keyword_do and self.tokens.current.tag != .l_brace and self.tokens.current.tag != .r_paren and self.tokens.current.tag != .r_bracket and self.tokens.current.tag != .r_brace and self.tokens.current.tag != .keyword_if and self.tokens.current.tag != .keyword_unless and self.tokens.current.tag != .keyword_while and self.tokens.current.tag != .keyword_until) {
            try args.append(self.allocator, try self.parseNamedArg());
            if (self.tokens.current.tag == .comma) {
                self.advance();
                self.skipIgnored();
            } else break;
        }

        var block_node: ?*Node = null;
        if (self.tokens.current.tag == .keyword_do or self.tokens.current.tag == .l_brace) {
            block_node = try self.parseBlockClosure();
        }
        return .{ .args = try args.toOwnedSlice(self.allocator), .block = block_node };
    }

    fn parseGroupedExpression(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.l_paren);

        if (self.tokens.current.tag == .r_paren) {
            self.advance();
            return self.createNode(.nil, start_tok.loc);
        }

        const expr = try self.parseExpression(.none);
        _ = try self.expect(.r_paren);
        return expr;
    }

    fn parseUnary(self: *Parser) ParseError!*Node {
        const tok = self.tokens.current;
        self.advance();
        const op: ast.UnaryOp = switch (tok.tag) {
            .minus => .negate,
            .plus => .positive,
            .tilde => .bitwise_not,
            else => .not,
        };
        return self.createNode(.{ .unary_op = .{ .op = op, .operand = try self.parseExpression(.unary) } }, tok.loc);
    }

    fn parseScopeResolution(self: *Parser, left: *Node) ParseError!*Node {
        const tok = try self.expect(.colon_colon);
        const right_tok = if (self.tokens.current.tag == .constant or self.tokens.current.tag == .ident) self.tokens.current else return ParseError.UnexpectedToken;
        self.advance();

        if (left.kind.kupcad == .namespace_access) {
            var path_list: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer path_list.deinit(self.allocator);
            try path_list.appendSlice(self.allocator, left.kind.kupcad.namespace_access.path);
            try path_list.append(self.allocator, right_tok.lexeme);

            return self.createNode(.{
                .namespace_access = .{ .path = try path_list.toOwnedSlice(self.allocator) },
            }, tok.loc);
        } else if (left.kind.kupcad == .identifier) {
            var path_list: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer path_list.deinit(self.allocator);
            try path_list.append(self.allocator, left.kind.kupcad.identifier);
            try path_list.append(self.allocator, right_tok.lexeme);

            return self.createNode(.{
                .namespace_access = .{ .path = try path_list.toOwnedSlice(self.allocator) },
            }, tok.loc);
        } else {
            return ParseError.InvalidExpression;
        }
    }

    fn parseArrayLiteral(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.l_bracket);
        const elements = try self.parseCommaSeparated(*Node, parseArrayElement, .r_bracket);
        _ = try self.expect(.r_bracket);
        return self.createNode(.{ .array_literal = elements }, start_tok.loc);
    }

    fn parseHashLiteral(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.l_brace);
        const entries = try self.parseCommaSeparated(ast.HashEntry, parseHashEntry, .r_brace);
        _ = try self.expect(.r_brace);
        return self.createNode(.{ .hash_literal = entries }, start_tok.loc);
    }

    fn parseBlockParam(self: *Parser) ParseError!*Node {
        if (self.tokens.current.tag == .ident) {
            const tok = self.tokens.current;
            self.advance();
            return self.b.identifierNode(tok.lexeme, tok.loc);
        } else if (self.tokens.current.tag == .l_paren) {
            const start_loc = self.tokens.current.loc;
            self.advance();
            const tuple_params = try self.parseCommaSeparated(*Node, parseBlockParam, .r_paren);
            _ = try self.expect(.r_paren);
            return self.createNode(.{ .array_literal = tuple_params }, start_loc);
        }
        return ParseError.UnexpectedToken;
    }

    fn createNode(self: *Parser, kind: ast.KupCadKind, loc: ast.Location) ParseError!*Node {
        return self.b.createKupCad(kind, loc) catch ParseError.OutOfMemory;
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
