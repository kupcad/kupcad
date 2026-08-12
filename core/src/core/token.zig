const std = @import("std");

pub const Location = struct {
    offset: u32,
    length: u32 = 0,
    file_id: u32, // Maps to a file path in your centralized Symbol/String Pool
};

pub const Comment = struct {
    lexeme: []const u8,
    loc: Location,
};

/// A generic Token wrapper that takes a language-specific Tag enum.
/// Used by the Lexer before tokens are packed into the SoA TokenList.
pub fn Token(comptime TagType: type) type {
    return struct {
        tag: TagType,
        loc: Location,
        lexeme: []const u8,

        pub fn endOffset(self: @This()) u32 {
            return self.loc.offset + @as(u32, @intCast(self.lexeme.len));
        }
    };
}

/// Struct-of-Arrays (SoA) for Tokens.
/// Drastically improves cache locality during parsing and lookahead.
pub fn TokenList(comptime TagType: type) type {
    return struct {
        tags: []TagType,
        starts: []u32,
        lengths: []u32,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.tags);
            allocator.free(self.starts);
            allocator.free(self.lengths);
        }

        /// Helper to extract the exact lexeme on demand
        pub fn lexeme(self: @This(), source: []const u8, index: usize) []const u8 {
            if (index >= self.starts.len) return "";
            const start = self.starts[index];
            return source[start .. start + self.lengths[index]];
        }
    };
}
