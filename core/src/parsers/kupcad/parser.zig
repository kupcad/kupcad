const std = @import("std");
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const Tag = lexer_mod.Tag;
const Token = lexer_mod.Token;
const ast = @import("../common/ast.zig");
const Node = ast.Node;
pub const ParseError = @import("../common/errors.zig").ParseError;

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
    exponent = 14, // **
    unary = 15, // ! -
    call = 16, // . &. () [] ::
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

    fn parseBeginStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_begin);
        self.skipIgnored();
        const body = try self.parseBlock(&.{ .keyword_rescue, .keyword_ensure, .keyword_end });

        var rescues: std.ArrayListUnmanaged(ast.RescueClause) = .empty;
        errdefer rescues.deinit(self.allocator);

        while (self.current.tag == .keyword_rescue) {
            self.advance();
            var errors: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer errors.deinit(self.allocator);
            var variable: ?[]const u8 = null;

            if (self.current.tag == .constant or self.current.tag == .ident) {
                while (self.current.tag == .constant or self.current.tag == .ident) {
                    try errors.append(self.allocator, self.current.lexeme);
                    self.advance();
                    if (self.current.tag == .comma) self.advance() else break;
                }
            }

            if (self.current.tag == .arrow) { // => e
                self.advance();
                if (self.current.tag == .ident) {
                    variable = self.current.lexeme;
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
        if (self.current.tag == .keyword_ensure) {
            self.advance();
            self.skipIgnored();
            ensure_body = try self.parseBlock(&.{.keyword_end});
        }
        _ = try self.expect(.keyword_end);

        return self.createNode(.{ .begin_stmt = .{ .body = body, .rescues = try rescues.toOwnedSlice(self.allocator), .ensure_body = ensure_body } }, start_tok.loc);
    }

    fn parseImportStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_import);

        var symbols: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer symbols.deinit(self.allocator);

        if (self.current.tag == .l_brace) {
            // e.g. import { a, b } from "path"
            self.advance();
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
        } else if (self.current.tag == .constant or self.current.tag == .ident) {
            // e.g. import Hardware from "path"
            try symbols.append(self.allocator, self.current.lexeme);
            self.advance();
            _ = try self.expect(.keyword_from);
        } else if (self.current.tag != .string) {
            return ParseError.UnexpectedToken;
        }

        const path_tok = try self.expect(.string);
        return self.createNode(.{
            .import_stmt = .{ .symbols = try symbols.toOwnedSlice(self.allocator), .path = path_tok.lexeme },
        }, start_tok.loc);
    }

    fn parseIfStatement(self: *Parser) ParseError!*Node {
        const start_tok = self.current;
        if (self.current.tag == .keyword_if or self.current.tag == .keyword_elsif) self.advance() else return ParseError.UnexpectedToken;

        const condition = try self.parseExpression(.none);
        if (self.current.tag == .keyword_then) self.advance();

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
        if (self.current.tag == .keyword_then) self.advance();

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
                const val_node = try self.parseExpressionList();
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
        if (self.current.tag == .keyword_then) self.advance();

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
        var is_class_method = false;
        var name_tok: Token = undefined;
        if (self.current.tag == .keyword_self and self.next_tok.tag == .dot) {
            is_class_method = true;
            self.advance(); // consume self
            self.advance(); // consume .
            name_tok = if (self.current.tag == .ident or self.current.tag == .constant) self.current else return ParseError.UnexpectedToken;
            self.advance();
        } else {
            name_tok = if (self.current.tag == .ident or self.current.tag == .constant) self.current else return ParseError.UnexpectedToken;
            self.advance();
        }
        const params = try self.parseParenParams();
        self.skipIgnored();

        // Parse main body up to rescue, ensure, or end
        const body_node = try self.parseBlock(&.{ .keyword_rescue, .keyword_ensure, .keyword_end });

        var rescues: std.ArrayListUnmanaged(ast.RescueClause) = .empty;
        errdefer rescues.deinit(self.allocator);

        while (self.current.tag == .keyword_rescue) {
            self.advance();
            var errors: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer errors.deinit(self.allocator);
            var variable: ?[]const u8 = null;

            if (self.current.tag == .constant or self.current.tag == .ident) {
                while (self.current.tag == .constant or self.current.tag == .ident) {
                    try errors.append(self.allocator, self.current.lexeme);
                    self.advance();
                    if (self.current.tag == .comma) self.advance() else break;
                }
            }
            if (self.current.tag == .arrow) { // => e
                self.advance();
                if (self.current.tag == .ident) {
                    variable = self.current.lexeme;
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
        if (self.current.tag == .keyword_ensure) {
            self.advance();
            self.skipIgnored();
            ensure_body = try self.parseBlock(&.{.keyword_end});
        }

        _ = try self.expect(.keyword_end);

        // If implicit rescue/ensure was used, wrap the body in a begin_stmt
        var final_body = body_node;
        if (rescues.items.len > 0 or ensure_body != null) {
            final_body = try self.createNode(.{
                .begin_stmt = .{
                    .body = body_node,
                    .rescues = try rescues.toOwnedSlice(self.allocator),
                    .ensure_body = ensure_body,
                },
            }, start_tok.loc);
        }

        return self.createNode(.{
            .def_stmt = .{
                .name = name_tok.lexeme,
                .params = params,
                .body = final_body,
                .is_class_method = is_class_method,
            },
        }, start_tok.loc);
    }

    fn parseClassPath(self: *Parser) ParseError!*Node {
        const start_loc = self.current.loc;
        var path_list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer path_list.deinit(self.allocator);

        while (self.current.tag == .constant or self.current.tag == .ident) {
            try path_list.append(self.allocator, self.current.lexeme);
            self.advance();
            if (self.current.tag == .colon_colon) {
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
        if (self.current.tag != .constant and self.current.tag != .ident) return ParseError.UnexpectedToken;
        const name_node = try self.parseClassPath();

        var super_class: ?*Node = null;
        if (self.current.tag == .less) {
            self.advance();
            if (self.current.tag != .constant and self.current.tag != .ident) return ParseError.UnexpectedToken;
            super_class = try self.parseClassPath();
        }
        self.skipIgnored();
        const body = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);
        return self.createNode(.{ .class_stmt = .{ .name = name_node, .super_class = super_class, .body = body } }, start_tok.loc);
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
            val = try self.parseExpressionList();
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
            .keyword_if => left = try self.parseIfStatement(),
            .keyword_unless => left = try self.parseUnlessStatement(),
            .keyword_case => left = try self.parseCaseStatement(),
            .percent_w, .percent_i => left = try self.parsePercentArray(start_tok.tag),
            else => return ParseError.InvalidExpression,
        }

        while (true) {
            // Handle multi-line method chaining (Fluent API)
            if (self.current.tag == .newline) {
                const next_tag = self.next_tok.tag;
                if (next_tag == .dot or next_tag == .ampersand_dot) {
                    self.advance(); // consume newline to continue the chain
                } else {
                    break; // normal end of statement
                }
            }

            // Allow mid-expression comments
            while (self.current.tag == .comment) self.advance();

            if (@intFromEnum(precedence) >= @intFromEnum(getInfixPrecedence(self.current.tag))) break;

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
                .keyword_rescue => try self.parseRescueModifierExpr(left),
                else => break,
            };
        }
        return left;
    }

    fn parseExpressionList(self: *Parser) ParseError!*Node {
        const first = try self.parseExpression(.assignment); // Stop at commas
        if (self.current.tag == .comma) {
            var elements: std.ArrayListUnmanaged(*Node) = .empty;
            errdefer elements.deinit(self.allocator);
            try elements.append(self.allocator, first);
            while (self.current.tag == .comma) {
                self.advance();
                try elements.append(self.allocator, try self.parseExpression(.assignment));
            }
            return self.createNode(.{ .array_literal = try elements.toOwnedSlice(self.allocator) }, first.loc);
        }
        return first;
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

    fn parsePercentArray(self: *Parser, tag: Tag) ParseError!*Node {
        const tok = self.current;
        self.advance();
        // Extract inner content e.g. from `%w[a b]`
        const inner = tok.lexeme[3 .. tok.lexeme.len - 1];
        var iter = std.mem.tokenizeAny(u8, inner, " \t\r\n");
        var elements: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer elements.deinit(self.allocator);

        while (iter.next()) |word| {
            if (tag == .percent_w) {
                elements.append(self.allocator, try self.createNode(.{ .string = word }, tok.loc)) catch return ParseError.OutOfMemory;
            } else {
                elements.append(self.allocator, try self.createNode(.{ .symbol = word }, tok.loc)) catch return ParseError.OutOfMemory;
            }
        }
        return self.createNode(.{ .array_literal = try elements.toOwnedSlice(self.allocator) }, tok.loc);
    }

    fn parseRescueModifierExpr(self: *Parser, left: *Node) ParseError!*Node {
        const tok = self.current;
        self.advance();
        const rescue_expr = try self.parseExpression(getInfixPrecedence(.keyword_rescue));
        return self.createNode(.{ .rescue_modifier = .{ .expr = left, .rescue_expr = rescue_expr } }, tok.loc);
    }

    fn parseSuper(self: *Parser) ParseError!*Node {
        const tok = try self.expect(.keyword_super);

        if (self.current.tag == .l_paren) {
            const args = try self.parseParenArgs();
            var block_node: ?*Node = null;
            if (self.current.tag == .keyword_do or self.current.tag == .l_brace) block_node = try self.parseBlockClosure();
            return self.createNode(.{
                .super_call = .{ .args = args, .block = block_node },
            }, tok.loc);
        }

        if (self.isCommandCallStart()) {
            const cmd = try self.parseCommandArgsAndBlock();
            return self.createNode(.{
                .super_call = .{ .args = cmd.args, .block = cmd.block },
            }, tok.loc);
        }

        return self.createNode(.{
            .super_call = .{ .args = &.{}, .block = null },
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
        return self.b.identifierNode(tok.lexeme, tok.loc);
    }

    fn parseArrayLiteral(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.l_bracket);
        var elements: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer elements.deinit(self.allocator);

        while (self.current.tag != .r_bracket and self.current.tag != .eof) {
            self.skipIgnored();
            if (self.current.tag == .r_bracket) break;

            if (self.current.tag == .star) {
                const star_loc = self.current.loc;
                self.advance();
                const inner = try self.parseExpression(.none);
                try elements.append(self.allocator, try self.createNode(.{ .splat_expr = inner }, star_loc));
            } else {
                try elements.append(self.allocator, try self.parseExpression(.none));
            }

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

            if (self.current.tag == .star_star) {
                const star_loc = self.current.loc;
                self.advance();
                const inner = try self.parseExpression(.none);
                const double_splat = try self.createNode(.{ .double_splat_expr = inner }, star_loc);
                // Clever AST representation: map **kwargs to both key and value
                try entries.append(self.allocator, .{ .key = double_splat, .value = double_splat });
            } else {
                var key: *Node = undefined;
                if (self.current.tag == .ident and self.next_tok.tag == .colon) {
                    const key_tok = self.current;
                    self.advance();
                    self.advance();
                    // Now properly constructs a .symbol node instead of .string
                    key = try self.createNode(.{ .symbol = key_tok.lexeme }, key_tok.loc);
                } else {
                    key = try self.parseExpression(.none);
                    if (self.current.tag == .colon or self.current.tag == .arrow) {
                        self.advance();
                    } else return ParseError.UnexpectedToken;
                }
                try entries.append(self.allocator, .{ .key = key, .value = try self.parseExpression(.none) });
            }

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

    fn parseBlockParam(self: *Parser) ParseError!*Node {
        if (self.current.tag == .ident) {
            const tok = self.current;
            self.advance();
            return self.b.identifierNode(tok.lexeme, tok.loc);
        } else if (self.current.tag == .l_paren) {
            const start_loc = self.current.loc;
            self.advance();
            var tuple_params: std.ArrayListUnmanaged(*Node) = .empty;
            errdefer tuple_params.deinit(self.allocator);
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                try tuple_params.append(self.allocator, try self.parseBlockParam());
                if (self.current.tag == .comma) self.advance() else break;
            }
            _ = try self.expect(.r_paren);
            return self.createNode(.{ .array_literal = try tuple_params.toOwnedSlice(self.allocator) }, start_loc);
        }
        return ParseError.UnexpectedToken;
    }

    fn parseBlockClosure(self: *Parser) ParseError!*Node {
        const is_brace = (self.current.tag == .l_brace);
        const start_tok = if (is_brace) try self.expect(.l_brace) else try self.expect(.keyword_do);

        var params: std.ArrayListUnmanaged(*Node) = .empty;
        errdefer params.deinit(self.allocator);

        if (self.current.tag == .pipe) {
            self.advance();
            while (self.current.tag != .pipe and self.current.tag != .eof) {
                try params.append(self.allocator, try self.parseBlockParam());
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
