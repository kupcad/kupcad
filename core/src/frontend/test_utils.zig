const std = @import("std");
const testing = std.testing;

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
            // Allocate the arena itself on the heap so it has a stable address
            const arena = try testing.allocator.create(std.heap.ArenaAllocator);
            errdefer testing.allocator.destroy(arena);

            // Initialize it
            arena.* = std.heap.ArenaAllocator.init(testing.allocator);
            errdefer arena.deinit();

            // Now it is perfectly safe to take a pointer to it
            const allocator = arena.allocator();

            const lexer = try allocator.create(LexerType);
            lexer.* = LexerType.init(source, 0);

            const parser = try allocator.create(ParserType);
            parser.* = ParserType.init(lexer, allocator);

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
    };
}
