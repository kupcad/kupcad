const std = @import("std");

pub const Location = struct {
    line: u32,
    col: u32,
    file_id: u32, // Maps to a file path in your centralized Symbol/String Pool
};

/// A generic Token wrapper that takes a language-specific Tag enum.
pub fn Token(comptime TagType: type) type {
    return struct {
        tag: TagType,
        loc: Location,
        lexeme: []const u8,
    };
}
