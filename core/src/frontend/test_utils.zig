const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");

pub fn ExpectedToken(comptime TagType: type) type {
    return struct {
        tag: TagType,
        lexeme: []const u8,
    };
}

pub inline fn t(tag: anytype, lexeme: []const u8) ExpectedToken(@TypeOf(tag)) {
    return .{ .tag = tag, .lexeme = lexeme };
}

pub fn expectTokens(comptime LexerType: type, source: []const u8, expected: anytype) !void {
    var lexer = LexerType.init(source, 0);
    inline for (expected) |exp| {
        const tok = lexer.next();
        try testing.expectEqual(exp.tag, tok.tag);
        try testing.expectEqualStrings(exp.lexeme, tok.lexeme);
    }
}

pub fn ParserTest(comptime LexerType: type, comptime ParserType: type) type {
    return struct {
        // Change from a value to a pointer
        arena: *std.heap.ArenaAllocator,
        lexer: *LexerType,
        parser: *ParserType,

        const Self = @This();

        pub fn init(source: []const u8) !Self {
            const arena = try testing.allocator.create(std.heap.ArenaAllocator);
            errdefer testing.allocator.destroy(arena);
            arena.* = std.heap.ArenaAllocator.init(testing.allocator);
            errdefer arena.deinit();

            const allocator = arena.allocator();

            const lexer = try allocator.create(LexerType);
            lexer.* = LexerType.init(source, 0);

            // Lex everything upfront in tests
            const tokens = try lexer.lexAll(allocator);

            const parser = try allocator.create(ParserType);
            // Pass tokens and source
            parser.* = try ParserType.init(tokens, source, allocator);

            return .{
                .arena = arena,
                .lexer = lexer,
                .parser = parser,
            };
        }

        pub fn deinit(self: *Self) void {
            // Clean up the allocations inside the arena
            self.arena.deinit();
            // Clean up the arena struct itself
            testing.allocator.destroy(self.arena);
        }

        // Convenience method for data-oriented AST access in tests
        pub fn getNode(self: *Self, index: ast.NodeIndex) *const ast.Node {
            return self.parser.b.tree.getNode(index).?;
        }
    };
}
