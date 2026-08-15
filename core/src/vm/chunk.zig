const std = @import("std");
const value = @import("../core/value.zig");

/// The Virtual Machine Instruction Set
pub const OpCode = enum(u8) {
    // Constants & Literals
    op_constant,
    op_constant_wide,
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
    op_closure_wide,
    op_get_upvalue,
    op_set_upvalue,
    op_close_upvalue,

    // Object Orientation
    op_class,
    op_class_wide,
    op_get_property,
    op_get_property_wide,
    op_set_property,
    op_set_property_wide,
    op_class_method,
    op_class_method_wide,
    op_get_class_var,
    op_get_class_var_wide,
    op_set_class_var,
    op_set_class_var_wide,
    op_module,
    op_module_wide,
    op_mixin,
    op_method,
    op_method_wide,
    op_unpack,
    op_unpack_splat,
    op_pack_splat,
    op_defined,
    op_defined_wide,
    op_extract_kwarg,
    op_extract_kwarg_wide,
    op_is_instance,

    // Stack Operations
    op_pop,
    op_dup,

    // Variables
    op_get_local,
    op_set_local,
    op_get_global,
    op_get_global_wide,
    op_define_global,
    op_define_global_wide,
    op_set_global,
    op_set_global_wide,

    // Math
    op_add,
    op_subtract,
    op_multiply,
    op_divide,
    op_modulo,
    op_exponent,
    op_negate,

    // Logical
    op_not,
    op_equal,
    op_case_equal,
    op_greater,
    op_less,

    // Control Flow
    op_jump,
    op_jump_if_false,
    op_jump_if_nil,
    op_jump_if_not_nil,
    op_switch,
    op_loop,

    // Exception Handling
    op_setup_rescue,
    op_pop_rescue,
    op_throw,

    // Functions & Builtins
    op_call,
    op_invoke,
    op_invoke_wide,
    op_super_invoke,
    op_import,
    op_import_wide,
    op_inherit,
    op_yield,
    op_block_given,
    op_return,
};

pub const DebugSpan = struct {
    ip: u32,
    source_offset: u32,
};

pub const Chunk = struct {
    code: std.ArrayListUnmanaged(u8),
    debug_spans: std.ArrayListUnmanaged(DebugSpan),
    constants: value.ValueArray,
    max_stack_slots: usize,

    pub fn init() Chunk {
        return .{
            .code = .empty,
            .debug_spans = .empty,
            .constants = .empty,
            .max_stack_slots = 0,
        };
    }

    /// Writes a single byte (either an OpCode or an Operand)
    pub fn write(self: *Chunk, allocator: std.mem.Allocator, byte: u8, source_offset: u32) !void {
        try self.code.append(allocator, byte);
        // Highly compressed RLE: Only append if the offset changed!
        if (self.debug_spans.items.len == 0 or self.debug_spans.items[self.debug_spans.items.len - 1].source_offset != source_offset) {
            try self.debug_spans.append(allocator, .{ .ip = @intCast(self.code.items.len - 1), .source_offset = source_offset });
        }
    }

    /// Convenience wrapper to write an OpCode enum
    pub fn writeOp(self: *Chunk, allocator: std.mem.Allocator, op: OpCode, source_offset: u32) !void {
        try self.write(allocator, @intFromEnum(op), source_offset);
    }

    /// Adds a Value to the constant pool and returns its 0-based index
    pub fn addConstant(self: *Chunk, allocator: std.mem.Allocator, val: value.Value) !usize {
        try self.constants.append(allocator, val);
        return self.constants.items.len - 1; // Return usize
    }

    /// O(log N) binary search could be used here, but linear is fine for error traces
    pub fn getOffset(self: *const Chunk, target_ip: usize) u32 {
        var last_offset: u32 = 0;
        for (self.debug_spans.items) |span| {
            if (span.ip > target_ip) break;
            last_offset = span.source_offset;
        }
        return last_offset;
    }

    pub fn free(self: *Chunk, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.debug_spans.deinit(allocator);
        self.constants.deinit(allocator);
        self.* = init();
    }
};
