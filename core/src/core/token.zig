//! The token types the lexer and parser share: `Location`, `Comment`, the generic
//! `Token(Tag)` the lexer produces and `TokenList(Tag)`, the struct-of-arrays they are packed in.

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

/// A heredoc's body, kept beside the tokens: its token is the opener (`<<~NAME`), so the
/// tokens stay in source order, and the body is the lines after the opener's line (or
/// after the terminator of a heredoc opened before it there), up to its terminator line.
pub const Heredoc = struct {
    token: u32,
    body_start: u32,
    body_len: u32,

    /// Where its terminator line starts: the body's lines end there.
    pub fn bodyEnd(self: Heredoc) u32 {
        return self.body_start + self.body_len;
    }
};

/// Struct-of-Arrays (SoA) for Tokens.
/// Drastically improves cache locality during parsing and lookahead.
pub fn TokenList(comptime TagType: type) type {
    return struct {
        tags: []TagType,
        starts: []u32,
        lengths: []u32,
        /// One per heredoc token, in token order.
        heredocs: []const Heredoc = &.{},

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.tags);
            allocator.free(self.starts);
            allocator.free(self.lengths);
            allocator.free(self.heredocs);
        }

        /// The body of the heredoc whose opener is token `index`.
        pub fn heredoc(self: @This(), index: u32) Heredoc {
            const found = std.sort.binarySearch(Heredoc, self.heredocs, index, struct {
                fn order(tok: u32, h: Heredoc) std.math.Order {
                    return std.math.order(tok, h.token);
                }
            }.order);
            return self.heredocs[found orelse unreachable]; // the lexer records one per heredoc token
        }

        /// Helper to extract the exact lexeme on demand
        pub fn lexeme(self: @This(), source: []const u8, index: usize) []const u8 {
            if (index >= self.starts.len) return "";
            const start = self.starts[index];
            return source[start .. start + self.lengths[index]];
        }
    };
}
