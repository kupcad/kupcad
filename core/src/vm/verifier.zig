//! Checks a bytecode chunk before the VM runs it: `verifyChunk` decodes every instruction,
//! checking its opcode, that its operands lie inside the code, that constant, inline cache
//! and slot indices are in range and that jumps land on an instruction, and verifies the
//! chunks of nested functions too. Called by the compiler and by `vm.zig`.

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
    InvalidGlobalCacheIndex,
    /// A local or upvalue slot outside the function's frame or closure.
    InvalidSlot,
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

/// What a chunk's code may address: the slots of its frame and its closure's upvalues.
/// Out-of-range slot operands used to reach the VM, where only debug builds assert.
const Scope = struct {
    local_count: usize,
    upvalue_count: usize,

    fn checkLocal(self: Scope, slot: usize) VerifierError!void {
        if (slot >= self.local_count) return error.InvalidSlot;
    }

    fn checkUpvalue(self: Scope, slot: usize) VerifierError!void {
        if (slot >= self.upvalue_count) return error.InvalidSlot;
    }
};

/// A top-level chunk (a script or module) has no enclosing closure, so no upvalues.
pub fn verifyChunk(allocator: std.mem.Allocator, c: *const chunk.Chunk) VerifierError!void {
    return verifyChunkDepth(allocator, c, .{ .local_count = c.local_count, .upvalue_count = 0 }, 0);
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

fn checkGlobalCache(c: *const chunk.Chunk, code: []const u8, at: usize) VerifierError!void {
    if (readU16(code, at) >= c.global_caches.items.len) return error.InvalidGlobalCacheIndex;
}

fn verifyChunkDepth(allocator: std.mem.Allocator, c: *const chunk.Chunk, scope: Scope, depth: usize) VerifierError!void {
    if (depth > MAX_NESTED_CHUNK_DEPTH) return error.CorruptedBytecode;
    const code = c.code.items;

    // Jumps must land on the first byte of an instruction, not inside an operand.
    // Targets are collected during the linear decode and checked once all
    // instruction starts are known (forward jumps point at not-yet-decoded code).
    var starts = std.bit_set.Dynamic.initEmpty(allocator, code.len) catch return error.OutOfMemory;
    defer starts.deinit(allocator);
    var walk: Walk = .{ .allocator = allocator, .c = c, .code = code, .scope = scope, .depth = depth };
    defer walk.targets.deinit(allocator);

    while (walk.ip < code.len) {
        starts.set(walk.ip);
        const op_raw = code[walk.ip];
        // Ensure opcode is a valid enum variant
        if (op_raw > @backingInt(chunk.OpCode.op_return)) return error.InvalidOpCode;
        walk.ip += 1;
        try walk.operands(@fromBackingInt(op_raw));
    }

    // `len` itself counts as a boundary: hand-assembled chunks (and dead code after
    // a final jump) may target the end. The compiler always terminates with op_return.
    for (walk.targets.items) |target| {
        if (target > code.len or (target < code.len and !starts.isSet(target))) return error.InvalidJumpOffset;
    }
}

/// The decode of one chunk: where it has got to, and the jump targets it has met.
const Walk = struct {
    allocator: std.mem.Allocator,
    c: *const chunk.Chunk,
    code: []const u8,
    scope: Scope,
    depth: usize,
    ip: usize = 0,
    targets: std.ArrayList(usize) = .empty,

    /// Steps over the next `n` operand bytes, which must lie inside the code, and gives
    /// where they start.
    fn take(self: *Walk, n: usize) VerifierError!usize {
        if (self.ip + n > self.code.len) return error.OutOfBoundsRead;
        defer self.ip += n;
        return self.ip;
    }

    /// A jump to `target`, checked once every instruction start is known.
    fn jumpTo(self: *Walk, target: usize) VerifierError!void {
        if (target > self.code.len) return error.InvalidJumpOffset;
        self.targets.append(self.allocator, target) catch return error.OutOfMemory;
    }

    /// Checks the operands of `op`, whose opcode byte is behind `ip`, and steps over them.
    fn operands(self: *Walk, op: chunk.OpCode) VerifierError!void {
        const c = self.c;
        const code = self.code;
        switch (op) {
            .op_nil, .op_true, .op_false, .op_pop, .op_return, .op_add, .op_subtract, .op_multiply, .op_divide, .op_modulo, .op_exponent, .op_bitwise_and, .op_bitwise_or, .op_bitwise_xor, .op_shift_left, .op_shift_right, .op_equal, .op_case_equal, .op_less, .op_greater, .op_less_equal, .op_greater_equal, .op_cmp, .op_not, .op_negate, .op_positive, .op_bitwise_not, .op_dup, .op_dup_two, .op_array_push, .op_array_spread, .op_map_insert, .op_map_spread, .op_get_index, .op_set_index, .op_pop_rescue, .op_throw, .op_block_given, .op_is_nil, .op_is_instance, .op_close_upvalue, .op_inherit, .op_mixin, .op_break_block => {},

            // 1-byte constant index
            .op_constant, .op_class, .op_module, .op_set_member, .op_method, .op_class_method, .op_defined, .op_get_class_var, .op_set_class_var, .op_import => try checkConstant(c, code[try self.take(1)]),
            // 2-byte constant index
            .op_constant_wide, .op_class_wide, .op_module_wide, .op_set_member_wide, .op_method_wide, .op_class_method_wide, .op_defined_wide, .op_get_class_var_wide, .op_set_class_var_wide, .op_import_wide => try checkConstant(c, readU16(code, try self.take(2))),

            // Slots
            .op_get_local, .op_set_local => try self.scope.checkLocal(code[try self.take(1)]),
            .op_get_local_wide, .op_set_local_wide => try self.scope.checkLocal(readU16(code, try self.take(2))),
            .op_get_upvalue, .op_set_upvalue => try self.scope.checkUpvalue(code[try self.take(1)]),

            // Counts and arities: 1 or 2 bytes; a call's argument count and CallFlags byte
            .op_build_array, .op_build_map, .op_build_range, .op_interpolate, .op_unpack => _ = try self.take(1),
            .op_build_array_wide, .op_build_map_wide, .op_pack_splat, .op_unpack_splat => _ = try self.take(2),
            .op_call, .op_yield, .op_super_invoke => _ = try self.take(2),

            // 1-byte map slot + 1- or 2-byte constant index
            .op_extract_kwarg => try checkConstant(c, code[try self.take(2) + 1]),
            .op_extract_kwarg_wide => try checkConstant(c, readU16(code, try self.take(3) + 1)),

            // Name constant (1 or 2 bytes) + 2-byte GlobalCache
            .op_get_global, .op_define_global => {
                const at = try self.take(3);
                try checkConstant(c, code[at]);
                try checkGlobalCache(c, code, at + 1);
            },
            .op_get_global_wide, .op_define_global_wide => {
                const at = try self.take(4);
                try checkConstant(c, readU16(code, at));
                try checkGlobalCache(c, code, at + 2);
            },

            // Name constant (1 or 2 bytes) + 2-byte inline cache
            .op_get_property, .op_set_property, .op_get_ivar => {
                const at = try self.take(3);
                try checkConstant(c, code[at]);
                try checkInlineCache(c, code, at + 1);
            },
            .op_get_property_wide, .op_set_property_wide, .op_get_ivar_wide => {
                const at = try self.take(4);
                try checkConstant(c, readU16(code, at));
                try checkInlineCache(c, code, at + 2);
            },

            // Name constant (1 or 2 bytes) + 1-byte arity + 1-byte CallFlags + 2-byte inline cache
            .op_invoke => {
                const at = try self.take(5);
                try checkConstant(c, code[at]);
                try checkInlineCache(c, code, at + 3);
            },
            .op_invoke_wide => {
                const at = try self.take(6);
                try checkConstant(c, readU16(code, at));
                try checkInlineCache(c, code, at + 4);
            },

            // u16 slot of the loop state (it spans two slots), then a 4-byte exit offset
            .op_for_next => {
                const at = try self.take(2 + JUMP_OPERAND_SIZE);
                try self.scope.checkLocal(readU16(code, at) + 1);
                try self.jumpTo(self.ip + readU32(code, at + 2));
            },

            // 4-byte jump offsets, from the end of the instruction
            .op_jump, .op_jump_if_false, .op_jump_if_nil, .op_jump_if_not_nil, .op_setup_rescue => {
                const offset = readU32(code, try self.take(JUMP_OPERAND_SIZE));
                try self.jumpTo(self.ip + offset);
            },
            .op_loop => {
                const offset = readU32(code, try self.take(JUMP_OPERAND_SIZE));
                if (self.ip < offset) return error.InvalidJumpOffset;
                try self.jumpTo(self.ip - offset);
            },

            .op_switch, .op_switch_wide => try self.jumpTable(op == .op_switch_wide),
            .op_closure, .op_closure_wide => try self.closure(op == .op_closure_wide),
        }
    }

    /// op_switch: a case count (1 or 2 bytes), the cases (a constant and a jump offset
    /// each), then the default's jump offset, all offsets from the end of the instruction.
    fn jumpTable(self: *Walk, wide: bool) VerifierError!void {
        const code = self.code;
        const count_at = try self.take(if (wide) 2 else 1);
        const case_count = if (wide) readU16(code, count_at) else @as(usize, code[count_at]);
        const table = try self.take(case_count * SWITCH_ENTRY_SIZE + JUMP_OPERAND_SIZE);
        const after = self.ip;
        for (0..case_count) |i| {
            const entry = table + i * SWITCH_ENTRY_SIZE;
            try checkConstant(self.c, readU16(code, entry));
            try self.jumpTo(after + readU32(code, entry + 2));
        }
        try self.jumpTo(after + readU32(code, after - JUMP_OPERAND_SIZE));
    }

    /// op_closure: the function's constant (1 or 2 bytes) and a descriptor per upvalue it
    /// captures; the function's own chunk is verified too, one level deeper.
    fn closure(self: *Walk, wide: bool) VerifierError!void {
        const code = self.code;
        const idx_at = try self.take(if (wide) 2 else 1);
        const func_idx = if (wide) readU16(code, idx_at) else @as(usize, code[idx_at]);
        try checkConstant(self.c, func_idx);
        // Anything but a function here means a corrupt script.
        const func_val = self.c.constants.items[func_idx];
        if (!func_val.isFunction()) return error.CorruptedBytecode;
        const func_obj = func_val.asFunction();

        const descriptors = try self.take(func_obj.upvalue_count * UPVALUE_DESCRIPTOR_SIZE);
        // Each upvalue captures one of this frame's locals or one of its upvalues.
        for (0..func_obj.upvalue_count) |i| {
            const at = descriptors + i * UPVALUE_DESCRIPTOR_SIZE;
            const captured = readU16(code, at + 1);
            switch (code[at]) { // the VM's is_local flag
                1 => try self.scope.checkLocal(captured),
                0 => try self.scope.checkUpvalue(captured),
                else => return error.CorruptedBytecode,
            }
        }

        if (func_obj.chunk) |child_ptr| {
            const child: *const chunk.Chunk = @ptrCast(@alignCast(child_ptr));
            if (child == self.c) return error.CorruptedBytecode;
            // The function sizes its frames (see VM.padClosureFrame), not its chunk.
            try verifyChunkDepth(self.allocator, child, .{ .local_count = func_obj.local_count, .upvalue_count = func_obj.upvalue_count }, self.depth + 1);
        }
    }
};
