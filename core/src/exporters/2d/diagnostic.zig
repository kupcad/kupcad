//! What is wrong with a drawing a reader (dxf_read.zig, svg_read.zig) can't read: one
//! message, formatted where the reader finds the fault, for the import to raise.

const std = @import("std");

/// How long a message can be.
const MESSAGE_CAPACITY = 320;

pub const Diagnostic = struct {
    buffer: [MESSAGE_CAPACITY]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Keeps the message (cut short at MESSAGE_CAPACITY) and gives the error to return.
    pub fn fail(self: *Diagnostic, comptime fmt: []const u8, args: anytype) error{InvalidDrawing} {
        const written = std.fmt.bufPrint(&self.buffer, fmt, args) catch self.buffer[0..];
        self.len = written.len;
        return error.InvalidDrawing;
    }
};
