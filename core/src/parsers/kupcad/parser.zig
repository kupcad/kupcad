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
    assignment = 1, // =
    logical_or = 2, // ||
    logical_and = 3, // &&
    equality = 4, // == !=
    comparison = 5, // < <= > >=
    term = 6, // + -
    factor = 7, // * / %
    exponent = 8, // **
    unary = 9, // ! -
    call = 10, // . ()
};

pub const Parser = struct {
    lexer: *Lexer,
    allocator: std.mem.Allocator,
    current: Token,

    pub fn init(lexer: *Lexer, allocator: std.mem.Allocator) Parser {
        var parser = Parser{
            .lexer = lexer,
            .allocator = allocator,
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
        return self.parseBlock(&.{});
    }

    pub fn parseStatement(self: *Parser) ParseError!*Node {
        while (self.current.tag == .newline) {
            self.advance();
        }

        return switch (self.current.tag) {
            .keyword_import => try self.parseImportStatement(),
            .keyword_if => try self.parseIfStatement(),
            else => try self.parseExpression(.none),
        };
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

            if (self.current.tag == .newline) {
                self.advance();
                continue;
            }

            const stmt = try self.parseStatement();
            try stmts.append(self.allocator, stmt);

            if (self.current.tag == .newline) {
                self.advance();
            }
        }

        const stmts_slice = try stmts.toOwnedSlice(self.allocator);
        return self.createNode(.{
            .block = .{
                .stmts = stmts_slice,
            },
        }, start_loc);
    }

    fn parseImportStatement(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_import);
        _ = try self.expect(.l_brace);

        var symbols: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer symbols.deinit(self.allocator);

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            if (self.current.tag == .ident or self.current.tag == .constant) {
                try symbols.append(self.allocator, self.current.lexeme);
                self.advance();
            } else {
                return ParseError.UnexpectedToken;
            }

            if (self.current.tag == .comma) {
                self.advance();
            } else {
                break;
            }
        }

        _ = try self.expect(.r_brace);
        _ = try self.expect(.keyword_from);
        const path_tok = try self.expect(.string);

        const symbols_slice = try symbols.toOwnedSlice(self.allocator);

        return self.createNode(.{
            .import_stmt = .{
                .symbols = symbols_slice,
                .path = path_tok.lexeme,
            },
        }, start_tok.loc);
    }

    fn parseIfStatement(self: *Parser) ParseError!*Node {
        const start_tok = self.current;
        if (self.current.tag == .keyword_if or self.current.tag == .keyword_elsif) {
            self.advance();
        } else {
            return ParseError.UnexpectedToken;
        }

        const condition = try self.parseExpression(.none);

        while (self.current.tag == .newline) {
            self.advance();
        }

        const then_branch = try self.parseBlock(&.{ .keyword_elsif, .keyword_else, .keyword_end });

        var else_branch: ?*Node = null;

        if (self.current.tag == .keyword_elsif) {
            else_branch = try self.parseIfStatement();
        } else if (self.current.tag == .keyword_else) {
            self.advance(); // consume 'else'
            while (self.current.tag == .newline) {
                self.advance();
            }
            else_branch = try self.parseBlock(&.{.keyword_end});
            _ = try self.expect(.keyword_end);
        } else if (self.current.tag == .keyword_end) {
            self.advance(); // consume 'end'
        }

        return self.createNode(.{
            .if_stmt = .{
                .condition = condition,
                .then_branch = then_branch,
                .else_branch = else_branch,
            },
        }, start_tok.loc);
    }

    pub fn parseExpression(self: *Parser, precedence: Precedence) ParseError!*Node {
        const start_tok = self.current;

        // --- PREFIX ---
        var left = switch (start_tok.tag) {
            .number => try self.parseNumber(),
            .string => try self.parseString(),
            .symbol => try self.parseSymbol(),
            .keyword_true, .keyword_false => try self.parseBoolean(),
            .keyword_nil => try self.parseNil(),
            .ident, .constant => try self.parseIdentifierOrAssignment(),
            .l_paren => try self.parseGroupedExpression(),
            .minus, .bang => try self.parseUnary(),
            .keyword_if => try self.parseIfStatement(),
            else => return ParseError.InvalidExpression,
        };

        // --- INFIX / POSTFIX LOOP ---
        while (@intFromEnum(precedence) < @intFromEnum(getInfixPrecedence(self.current.tag))) {
            const op_tok = self.current;
            left = switch (op_tok.tag) {
                .plus, .minus, .star, .slash, .percent, .star_star, .equal_equal, .bang_equal, .less, .less_equal, .greater, .greater_equal, .and_and, .or_or => try self.parseBinary(left),
                .dot => try self.parseMethodCall(left),
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

    fn parseIdentifierOrAssignment(self: *Parser) ParseError!*Node {
        const tok = self.current;
        self.advance();

        if (self.current.tag == .equal) {
            self.advance(); // consume '='
            const val_node = try self.parseExpression(.assignment);
            return self.createNode(.{
                .assignment = .{
                    .name = tok.lexeme,
                    .value = val_node,
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

    fn parseUnary(self: *Parser) ParseError!*Node {
        const tok = self.current;
        self.advance();

        const op: ast.UnaryOp = if (tok.tag == .minus) .negate else .not;
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

        const next_prec = if (tok.tag == .star_star)
            @as(Precedence, @enumFromInt(@intFromEnum(getInfixPrecedence(tok.tag)) - 1))
        else
            getInfixPrecedence(tok.tag);

        const right = try self.parseExpression(next_prec);

        return self.createNode(.{
            .binary_op = .{
                .op = op,
                .left = left,
                .right = right,
            },
        }, tok.loc);
    }

    fn parseMethodCall(self: *Parser, receiver: *Node) ParseError!*Node {
        _ = try self.expect(.dot);
        const method_tok = try self.expect(.ident);

        var args: std.ArrayListUnmanaged(ast.NamedArg) = .empty;
        errdefer args.deinit(self.allocator);

        if (self.current.tag == .l_paren) {
            self.advance(); // consume '('
            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                var arg_name: []const u8 = "";
                if (self.current.tag == .ident and self.peekNextTag() == .colon) {
                    arg_name = self.current.lexeme;
                    self.advance(); // consume name
                    self.advance(); // consume ':'
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
        }

        var block_node: ?*Node = null;
        if (self.current.tag == .keyword_do) {
            block_node = try self.parseDoBlock();
        }

        const args_slice = try args.toOwnedSlice(self.allocator);

        return self.createNode(.{
            .method_call = .{
                .receiver = receiver,
                .method_name = method_tok.lexeme,
                .args = args_slice,
                .block = block_node,
            },
        }, method_tok.loc);
    }

    fn parseDoBlock(self: *Parser) ParseError!*Node {
        const start_tok = try self.expect(.keyword_do);

        var params: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer params.deinit(self.allocator);

        if (self.current.tag == .pipe) {
            self.advance(); // consume '|'
            while (self.current.tag != .pipe and self.current.tag != .eof) {
                if (self.current.tag == .ident) {
                    try params.append(self.allocator, self.current.lexeme);
                    self.advance();
                } else {
                    return ParseError.UnexpectedToken;
                }

                if (self.current.tag == .comma) {
                    self.advance();
                } else {
                    break;
                }
            }
            _ = try self.expect(.pipe);
        }

        const block_node = try self.parseBlock(&.{.keyword_end});
        _ = try self.expect(.keyword_end);

        const params_slice = try params.toOwnedSlice(self.allocator);

        return self.createNode(.{
            .block = .{
                .params = params_slice,
                .stmts = block_node.kind.block.stmts,
            },
        }, start_tok.loc);
    }

    inline fn peekNextTag(self: *Parser) Tag {
        var copy = self.lexer.*;
        return copy.next().tag;
    }

    fn createNode(self: *Parser, kind: Node.Kind, loc: ast.Location) ParseError!*Node {
        const node = self.allocator.create(Node) catch return ParseError.OutOfMemory;
        node.* = .{ .kind = kind, .loc = loc };
        return node;
    }

    fn getInfixPrecedence(tag: Tag) Precedence {
        return switch (tag) {
            .equal => .assignment,
            .or_or => .logical_or,
            .and_and => .logical_and,
            .equal_equal, .bang_equal => .equality,
            .less, .less_equal, .greater, .greater_equal => .comparison,
            .plus, .minus => .term,
            .star, .slash, .percent => .factor,
            .star_star => .exponent,
            .dot => .call,
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
