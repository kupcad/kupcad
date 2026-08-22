const std = @import("std");
const chunk = @import("chunk.zig");
const value = @import("../core/value.zig");

pub const VerifierError = error{
    CorruptedBytecode,
    InvalidOpCode,
    OutOfBoundsRead,
    InvalidJumpOffset,
    InvalidConstantIndex,
};

pub fn verifyChunk(c: *const chunk.Chunk) VerifierError!void {
    var ip: usize = 0;
    const len = c.code.items.len;

    while (ip < len) {
        const op_raw = c.code.items[ip];
        // Ensure opcode is a valid enum variant
        if (op_raw > @intFromEnum(chunk.OpCode.op_return)) return error.InvalidOpCode;

        const op: chunk.OpCode = @enumFromInt(op_raw);
        ip += 1;

        // Verify Operands based on OpCode definitions
        switch (op) {
            .op_nil, .op_true, .op_false, .op_pop, .op_return, .op_add, .op_subtract, .op_multiply, .op_divide, .op_modulo, .op_exponent, .op_bitwise_and, .op_equal, .op_case_equal, .op_less, .op_greater, .op_not, .op_negate, .op_dup, .op_dup_two, .op_array_push, .op_array_spread, .op_map_insert, .op_map_spread, .op_get_index, .op_set_index, .op_pop_rescue, .op_throw, .op_block_given, .op_is_nil, .op_is_instance, .op_close_upvalue, .op_inherit, .op_mixin, .op_break_block => {
                // No operands to verify
            },

            // 1-byte operand
            .op_constant, .op_get_local, .op_set_local, .op_get_global, .op_define_global, .op_set_global, .op_build_array, .op_build_map, .op_build_range, .op_interpolate, .op_unpack, .op_call, .op_yield, .op_get_upvalue, .op_set_upvalue, .op_class, .op_module, .op_set_member, .op_method, .op_class_method, .op_defined, .op_get_class_var, .op_set_class_var, .op_super_invoke, .op_import => {
                if (ip + 1 > len) return error.OutOfBoundsRead;
                ip += 1;
            },

            // 2-byte operand
            .op_constant_wide, .op_get_local_wide, .op_set_local_wide, .op_get_global_wide, .op_define_global_wide, .op_set_global_wide, .op_build_array_wide, .op_build_map_wide, .op_class_wide, .op_module_wide, .op_set_member_wide, .op_method_wide, .op_class_method_wide, .op_defined_wide, .op_get_class_var_wide, .op_set_class_var_wide, .op_import_wide, .op_pack_splat, .op_unpack_splat, .op_extract_kwarg => {
                if (ip + 2 > len) return error.OutOfBoundsRead;
                ip += 2;
            },

            // 3-byte operand (1 byte + 2 byte Inline Cache)
            .op_get_property, .op_set_property, .op_extract_kwarg_wide => {
                if (ip + 3 > len) return error.OutOfBoundsRead;
                ip += 3;
            },

            // 4-byte operand (2 byte + 2 byte Inline Cache, OR 1 byte name + 1 byte arity + 2 byte IC)
            .op_get_property_wide, .op_set_property_wide, .op_invoke => {
                if (ip + 4 > len) return error.OutOfBoundsRead;
                ip += 4;
            },

            // 5-byte operand (2 byte name + 1 byte arity + 2 byte IC)
            .op_invoke_wide => {
                if (ip + 5 > len) return error.OutOfBoundsRead;
                ip += 5;
            },

            // 4-byte jump offsets
            .op_jump, .op_jump_if_false, .op_jump_if_nil, .op_jump_if_not_nil, .op_loop, .op_setup_rescue => {
                if (ip + 4 > len) return error.OutOfBoundsRead;

                const b3 = @as(usize, c.code.items[ip]);
                const b2 = @as(usize, c.code.items[ip + 1]);
                const b1 = @as(usize, c.code.items[ip + 2]);
                const b0 = @as(usize, c.code.items[ip + 3]);
                const offset = (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;

                ip += 4;

                if (op == .op_loop) {
                    if (ip < offset) return error.InvalidJumpOffset;
                } else {
                    if (ip + offset > len) return error.InvalidJumpOffset;
                }
            },

            // Dynamic lengths
            .op_switch, .op_switch_wide => {
                const is_wide = op == .op_switch_wide;
                if (is_wide and ip + 2 > len) return error.OutOfBoundsRead;
                if (!is_wide and ip + 1 > len) return error.OutOfBoundsRead;

                const case_count = if (is_wide) (@as(usize, c.code.items[ip]) << 8) | @as(usize, c.code.items[ip + 1]) else @as(usize, c.code.items[ip]);
                ip += if (is_wide) @as(usize, 2) else @as(usize, 1);

                // 6 bytes per case + 4 bytes default jump
                if (ip + (case_count * 6) + 4 > len) return error.OutOfBoundsRead;
                ip += (case_count * 6) + 4;
            },

            .op_closure, .op_closure_wide => {
                const is_wide = op == .op_closure_wide;
                if (is_wide and ip + 2 > len) return error.OutOfBoundsRead;
                if (!is_wide and ip + 1 > len) return error.OutOfBoundsRead;

                const func_idx = if (is_wide) (@as(usize, c.code.items[ip]) << 8) | @as(usize, c.code.items[ip + 1]) else @as(usize, c.code.items[ip]);
                ip += if (is_wide) @as(usize, 2) else @as(usize, 1);

                if (func_idx >= c.constants.items.len) return error.InvalidConstantIndex;
                const func_val = c.constants.items[func_idx];

                // Safety: Assume it's an ObjFunction to verify the upvalue size payload.
                // If it isn't, the script is corrupt.
                if (func_val.isObject() and func_val.asObj().obj_type == .function) {
                    const func_obj = @as(*value.ObjFunction, @alignCast(@fieldParentPtr("obj", func_val.asObj())));
                    if (ip + (func_obj.upvalue_count * 3) > len) return error.OutOfBoundsRead;
                    ip += func_obj.upvalue_count * 3;
                } else {
                    return error.CorruptedBytecode;
                }
            },
        }
    }
}
