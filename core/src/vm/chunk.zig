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
    op_build_array_wide,
    op_array_push,
    op_array_spread,
    op_build_map,
    op_build_map_wide,
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
    op_set_member,
    op_set_member_wide,
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
    op_is_nil,

    // Stack Operations
    op_pop,
    op_dup,
    op_dup_two,

    // Variables
    op_get_local,
    op_get_local_wide,
    op_set_local,
    op_set_local_wide,
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
    op_bitwise_and,
    op_negate,

    // Logical
    op_not,
    op_equal,
    op_case_equal,
    op_greater,
    op_less,
    op_cmp,

    // Control Flow
    op_jump,
    op_jump_if_false,
    op_jump_if_nil,
    op_jump_if_not_nil,
    op_switch,
    op_switch_wide,
    op_loop,
    op_break_block,

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

// A 2-way Polymorphic Inline Cache (PIC)
pub const InlineCache = struct {
    cached_class_1: ?*value.ObjClass = null,
    cached_val_1: value.Value = value.Value.initNil(),
    offset_1: usize = 0,

    cached_class_2: ?*value.ObjClass = null,
    cached_val_2: value.Value = value.Value.initNil(),
    offset_2: usize = 0,
};

pub const DebugSpan = struct {
    ip: u32,
    source_offset: u32,
};

pub const Chunk = struct {
    code: std.ArrayListUnmanaged(u8),
    inline_caches: std.ArrayListUnmanaged(InlineCache),
    debug_spans: std.ArrayListUnmanaged(DebugSpan),
    constants: value.ValueArray,
    max_stack_slots: usize,
    local_count: usize,
    local_names: std.ArrayListUnmanaged([]const u8), // For REPL introspection

    pub fn init() Chunk {
        return .{
            .code = .empty,
            .inline_caches = .empty,
            .debug_spans = .empty,
            .constants = .empty,
            .max_stack_slots = 0,
            .local_count = 0,
            .local_names = .empty,
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

    /// O(log N) binary search for lightning-fast stack traces
    pub fn getOffset(self: *const Chunk, target_ip: usize) u32 {
        const spans = self.debug_spans.items;
        if (spans.len == 0) return 0;

        var left: usize = 0;
        var right: usize = spans.len - 1;
        var result_offset: u32 = 0;

        while (left <= right) {
            const mid = left + (right - left) / 2;
            const span = spans[mid];

            if (span.ip <= target_ip) {
                // This span is valid, but there might be a closer one to the right
                result_offset = span.source_offset;
                left = mid + 1;
            } else {
                // This span is too far ahead, search the left half
                if (mid == 0) break; // Prevent usize underflow
                right = mid - 1;
            }
        }

        return result_offset;
    }

    pub fn addInlineCache(self: *Chunk, allocator: std.mem.Allocator) !usize {
        const idx = self.inline_caches.items.len;
        try self.inline_caches.append(allocator, InlineCache{});
        return idx;
    }

    pub fn free(self: *Chunk, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.inline_caches.deinit(allocator);
        self.debug_spans.deinit(allocator);
        self.constants.deinit(allocator);
        self.local_names.deinit(allocator);
        self.* = init();
    }
};
