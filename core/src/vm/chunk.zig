const std = @import("std");
const value = @import("../core/value.zig");

/// The Virtual Machine Instruction Set
pub const OpCode = enum(u8) {
    // Constants & Literals
    op_constant,
    op_nil,
    op_true,
    op_false,

    // Data Structures
    op_build_array,
    op_array_push,
    op_array_spread,
    op_build_map,
    op_map_insert,
    op_map_spread,
    op_build_range,
    op_interpolate,
    op_get_index,
    op_set_index,

    // Closures & Upvalues
    op_closure,
    op_get_upvalue,
    op_set_upvalue,
    op_close_upvalue,

    // Object Orientation
    op_class,
    op_get_property,
    op_set_property,
    op_method,
    op_unpack,
    op_is_instance,

    // Stack Operations
    op_pop,
    op_dup,

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
    op_jump_if_nil,
    op_switch,
    op_loop,

    // Exception Handling
    op_setup_rescue,
    op_pop_rescue,
    op_throw,

    // Functions & Builtins
    op_call,
    op_invoke,
    op_import,
    op_return,
};

pub const LineStart = struct {
    line: u32,
    count: u32,
};

pub const Chunk = struct {
    code: std.ArrayListUnmanaged(u8),
    constants: value.ValueArray,
    max_stack_slots: usize,

    pub fn init() Chunk {
        return .{
            .code = .empty,
            .constants = .empty,
            .max_stack_slots = 0,
        };
    }

    /// Writes a single byte (either an OpCode or an Operand)
    pub fn write(self: *Chunk, allocator: std.mem.Allocator, byte: u8) !void {
        try self.code.append(allocator, byte);
    }

    /// Convenience wrapper to write an OpCode enum
    pub fn writeOp(self: *Chunk, allocator: std.mem.Allocator, op: OpCode) !void {
        try self.write(allocator, @intFromEnum(op));
    }

    /// Adds a Value to the constant pool and returns its 0-based index
    pub fn addConstant(self: *Chunk, allocator: std.mem.Allocator, val: value.Value) !u8 {
        try self.constants.append(allocator, val);
        return @intCast(self.constants.items.len - 1);
    }

    pub fn free(self: *Chunk, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.constants.deinit(allocator);
        self.* = init();
    }
};
