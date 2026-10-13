const std = @import("std");
const chunk = @import("chunk.zig");
const value = @import("../core/value.zig");

pub const VerifierError = error{
    CorruptedBytecode,
    InvalidOpCode,
    OutOfBoundsRead,
    InvalidJumpOffset,
    InvalidConstantIndex,
    InvalidInlineCacheIndex,
    OutOfMemory,
};

/// Bytes per op_switch jump-table entry: 2-byte constant index + 4-byte jump offset.
const SWITCH_ENTRY_SIZE: usize = 6;
/// Bytes per op_closure upvalue descriptor: is_local flag + 2-byte index.
const UPVALUE_DESCRIPTOR_SIZE: usize = 3;
/// Size of a jump offset operand.
const JUMP_OPERAND_SIZE: usize = 4;
/// Bound on verifying nested function chunks (each `def`/block nests one level).
const MAX_NESTED_CHUNK_DEPTH: usize = 256;

/// Verifies `c` and, recursively, the chunks of every function in its constant pool.
pub fn verifyChunk(c: *const chunk.Chunk) VerifierError!void {
    return verifyChunkWithAllocator(std.heap.page_allocator, c);
}

pub fn verifyChunkWithAllocator(allocator: std.mem.Allocator, c: *const chunk.Chunk) VerifierError!void {
    return verifyChunkDepth(allocator, c, 0);
}

fn readU16(code: []const u8, at: usize) usize {
    return (@as(usize, code[at]) << 8) | @as(usize, code[at + 1]);
}

fn readU32(code: []const u8, at: usize) usize {
    return (@as(usize, code[at]) << 24) | (@as(usize, code[at + 1]) << 16) |
        (@as(usize, code[at + 2]) << 8) | @as(usize, code[at + 3]);
}

fn checkConstant(c: *const chunk.Chunk, idx: usize) VerifierError!void {
    if (idx >= c.constants.items.len) return error.InvalidConstantIndex;
}

fn checkInlineCache(c: *const chunk.Chunk, code: []const u8, at: usize) VerifierError!void {
    if (readU16(code, at) >= c.inline_caches.items.len) return error.InvalidInlineCacheIndex;
}

fn verifyChunkDepth(allocator: std.mem.Allocator, c: *const chunk.Chunk, depth: usize) VerifierError!void {
    if (depth > MAX_NESTED_CHUNK_DEPTH) return error.CorruptedBytecode;

    const code = c.code.items;
    const len = code.len;

    // Jumps must land on the first byte of an instruction, not inside an operand.
    // Targets are collected during the linear decode and checked once all
    // instruction starts are known (forward jumps point at not-yet-decoded code).
    var starts = std.DynamicBitSetUnmanaged.initEmpty(allocator, len) catch return error.OutOfMemory;
    defer starts.deinit(allocator);
    var targets: std.ArrayListUnmanaged(usize) = .empty;
    defer targets.deinit(allocator);

    var ip: usize = 0;
    while (ip < len) {
        starts.set(ip);
        const op_raw = code[ip];
        // Ensure opcode is a valid enum variant
        if (op_raw > @backingInt(chunk.OpCode.op_return)) return error.InvalidOpCode;

        const op: chunk.OpCode = @fromBackingInt(op_raw);
        ip += 1;

        // Verify Operands based on OpCode definitions
        switch (op) {
            .op_nil, .op_true, .op_false, .op_pop, .op_return, .op_add, .op_subtract, .op_multiply, .op_divide, .op_modulo, .op_exponent, .op_bitwise_and, .op_bitwise_or, .op_bitwise_xor, .op_shift_left, .op_shift_right, .op_equal, .op_case_equal, .op_less, .op_greater, .op_cmp, .op_not, .op_negate, .op_dup, .op_dup_two, .op_array_push, .op_array_spread, .op_map_insert, .op_map_spread, .op_get_index, .op_set_index, .op_pop_rescue, .op_throw, .op_block_given, .op_is_nil, .op_is_instance, .op_close_upvalue, .op_inherit, .op_mixin, .op_break_block => {
                // No operands to verify
            },

            // 1-byte constant index
            .op_constant, .op_get_global, .op_define_global, .op_set_global, .op_class, .op_module, .op_set_member, .op_method, .op_class_method, .op_defined, .op_get_class_var, .op_set_class_var, .op_import => {
                if (ip + 1 > len) return error.OutOfBoundsRead;
                try checkConstant(c, code[ip]);
                ip += 1;
            },

            // 1-byte non-constant operand (slot, count, arity)
            .op_get_local, .op_set_local, .op_build_array, .op_build_map, .op_build_range, .op_interpolate, .op_unpack, .op_call, .op_yield, .op_get_upvalue, .op_set_upvalue, .op_super_invoke => {
                if (ip + 1 > len) return error.OutOfBoundsRead;
                ip += 1;
            },

            // 2-byte constant index
            .op_constant_wide, .op_get_global_wide, .op_define_global_wide, .op_set_global_wide, .op_class_wide, .op_module_wide, .op_set_member_wide, .op_method_wide, .op_class_method_wide, .op_defined_wide, .op_get_class_var_wide, .op_set_class_var_wide, .op_import_wide => {
                if (ip + 2 > len) return error.OutOfBoundsRead;
                try checkConstant(c, readU16(code, ip));
                ip += 2;
            },

            // 2-byte non-constant operand
            .op_get_local_wide, .op_set_local_wide, .op_build_array_wide, .op_build_map_wide, .op_pack_splat, .op_unpack_splat => {
                if (ip + 2 > len) return error.OutOfBoundsRead;
                ip += 2;
            },

            // 1-byte map slot + 1-byte constant index
            .op_extract_kwarg => {
                if (ip + 2 > len) return error.OutOfBoundsRead;
                try checkConstant(c, code[ip + 1]);
                ip += 2;
            },

            // 1-byte map slot + 2-byte constant index
            .op_extract_kwarg_wide => {
                if (ip + 3 > len) return error.OutOfBoundsRead;
                try checkConstant(c, readU16(code, ip + 1));
                ip += 3;
            },

            // 1-byte name constant + 2-byte Inline Cache
            .op_get_property, .op_set_property => {
                if (ip + 3 > len) return error.OutOfBoundsRead;
                try checkConstant(c, code[ip]);
                try checkInlineCache(c, code, ip + 1);
                ip += 3;
            },

            // 2-byte name constant + 2-byte Inline Cache
            .op_get_property_wide, .op_set_property_wide => {
                if (ip + 4 > len) return error.OutOfBoundsRead;
                try checkConstant(c, readU16(code, ip));
                try checkInlineCache(c, code, ip + 2);
                ip += 4;
            },

            // 1-byte name constant + 1-byte arity + 2-byte Inline Cache
            .op_invoke => {
                if (ip + 4 > len) return error.OutOfBoundsRead;
                try checkConstant(c, code[ip]);
                try checkInlineCache(c, code, ip + 2);
                ip += 4;
            },

            // 2-byte name constant + 1-byte arity + 2-byte Inline Cache
            .op_invoke_wide => {
                if (ip + 5 > len) return error.OutOfBoundsRead;
                try checkConstant(c, readU16(code, ip));
                try checkInlineCache(c, code, ip + 3);
                ip += 5;
            },

            // 4-byte jump offsets
            .op_jump, .op_jump_if_false, .op_jump_if_nil, .op_jump_if_not_nil, .op_loop, .op_setup_rescue => {
                if (ip + JUMP_OPERAND_SIZE > len) return error.OutOfBoundsRead;
                const offset = readU32(code, ip);
                ip += JUMP_OPERAND_SIZE;

                if (op == .op_loop) {
                    if (ip < offset) return error.InvalidJumpOffset;
                    targets.append(allocator, ip - offset) catch return error.OutOfMemory;
                } else {
                    if (ip + offset > len) return error.InvalidJumpOffset;
                    targets.append(allocator, ip + offset) catch return error.OutOfMemory;
                }
            },

            // Dynamic lengths
            .op_switch, .op_switch_wide => {
                const is_wide = op == .op_switch_wide;
                const count_size: usize = if (is_wide) 2 else 1;
                if (ip + count_size > len) return error.OutOfBoundsRead;

                const case_count = if (is_wide) readU16(code, ip) else @as(usize, code[ip]);
                ip += count_size;

                if (ip + (case_count * SWITCH_ENTRY_SIZE) + JUMP_OPERAND_SIZE > len) return error.OutOfBoundsRead;
                const table_start = ip;
                // All offsets are relative to the end of the instruction (after the default jump)
                const after = ip + (case_count * SWITCH_ENTRY_SIZE) + JUMP_OPERAND_SIZE;

                for (0..case_count) |i| {
                    const entry = table_start + i * SWITCH_ENTRY_SIZE;
                    try checkConstant(c, readU16(code, entry));
                    const offset = readU32(code, entry + 2);
                    if (after + offset > len) return error.InvalidJumpOffset;
                    targets.append(allocator, after + offset) catch return error.OutOfMemory;
                }
                const default_offset = readU32(code, after - JUMP_OPERAND_SIZE);
                if (after + default_offset > len) return error.InvalidJumpOffset;
                targets.append(allocator, after + default_offset) catch return error.OutOfMemory;

                ip = after;
            },

            .op_closure, .op_closure_wide => {
                const is_wide = op == .op_closure_wide;
                const idx_size: usize = if (is_wide) 2 else 1;
                if (ip + idx_size > len) return error.OutOfBoundsRead;

                const func_idx = if (is_wide) readU16(code, ip) else @as(usize, code[ip]);
                ip += idx_size;

                try checkConstant(c, func_idx);
                const func_val = c.constants.items[func_idx];

                // Safety: Assume it's an ObjFunction to verify the upvalue size payload.
                // If it isn't, the script is corrupt.
                if (func_val.isObject() and func_val.asObj().obj_type == .function) {
                    const func_obj: *value.ObjFunction = @alignCast(@fieldParentPtr("obj", func_val.asObj()));
                    if (ip + (func_obj.upvalue_count * UPVALUE_DESCRIPTOR_SIZE) > len) return error.OutOfBoundsRead;
                    ip += func_obj.upvalue_count * UPVALUE_DESCRIPTOR_SIZE;

                    if (func_obj.chunk) |child_ptr| {
                        const child: *const chunk.Chunk = @ptrCast(@alignCast(child_ptr));
                        if (child == c) return error.CorruptedBytecode;
                        try verifyChunkDepth(allocator, child, depth + 1);
                    }
                } else {
                    return error.CorruptedBytecode;
                }
            },
        }
    }

    // `len` itself counts as a boundary: hand-assembled chunks (and dead code after
    // a final jump) may target the end. The compiler always terminates with op_return.
    for (targets.items) |target| {
        if (target > len or (target < len and !starts.isSet(target))) return error.InvalidJumpOffset;
    }
}
