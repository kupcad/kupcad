const std = @import("std");
const value = @import("../core/value.zig");

/// The Virtual Machine Instruction Set
pub const OpCode = enum(u8) {
    // Constants & Literals
    op_constant,
    op_nil,
    op_true,
    op_false,

    // Stack Operations
    op_pop,

    // Variables
    op_get_local,
    op_set_local,
    op_get_global,
    op_define_global,
    op_set_global,

    // Math
    op_add,
    op_subtract,
    op_multiply,
    op_divide,
    op_negate,

    // Logical
    op_not,
    op_equal,
    op_greater,
    op_less,

    // Control Flow
    op_jump,
    op_jump_if_false,
    op_loop,

    // Functions & Builtins
    op_call,
    op_return,
};

pub const LineStart = struct {
    line: u32,
    count: u32,
};

pub const Chunk = struct {
    code: std.ArrayListUnmanaged(u8),
    lines: std.ArrayListUnmanaged(LineStart),
    constants: value.ValueArray,
    max_stack_slots: usize,

    pub fn init() Chunk {
        return .{
            .code = .empty,
            .lines = .empty,
            .constants = .empty,
            .max_stack_slots = 0,
        };
    }

    /// Writes a single byte (either an OpCode or an Operand)
    pub fn write(self: *Chunk, allocator: std.mem.Allocator, byte: u8, line: u32) !void {
        try self.code.append(allocator, byte);
        if (self.lines.items.len > 0 and self.lines.items[self.lines.items.len - 1].line == line) {
            self.lines.items[self.lines.items.len - 1].count += 1;
        } else {
            try self.lines.append(allocator, .{ .line = line, .count = 1 });
        }
    }

    /// Convenience wrapper to write an OpCode enum
    pub fn writeOp(self: *Chunk, allocator: std.mem.Allocator, op: OpCode, line: u32) !void {
        try self.write(allocator, @intFromEnum(op), line);
    }

    /// Adds a Value to the constant pool and returns its 0-based index
    pub fn addConstant(self: *Chunk, allocator: std.mem.Allocator, val: value.Value) !u8 {
        try self.constants.append(allocator, val);
        return @intCast(self.constants.items.len - 1);
    }

    pub fn free(self: *Chunk, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.lines.deinit(allocator);
        self.constants.deinit(allocator);
        self.* = init();
    }
};
