//! Checks a bytecode chunk before the VM runs it: `verifyChunk` decodes every instruction,
//! checking its opcode, that its operands lie inside the code, that constant, inline cache
//! and slot indices are in range and that jumps land on an instruction, and verifies the
//! chunks of nested functions too. Called by the compiler and by `vm.zig`.

const std = @import("std");
const chunk = @import("chunk.zig");

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

fn checkConstant(c: *const chunk.Chunk, idx: usize) VerifierError!void {
    if (idx >= c.constants.items.len) return error.InvalidConstantIndex;
}

fn checkInlineCache(c: *const chunk.Chunk, code: []const u8, at: usize) VerifierError!void {
    if (chunk.readU16(code, at) >= c.inline_caches.items.len) return error.InvalidInlineCacheIndex;
}

fn checkGlobalCache(c: *const chunk.Chunk, code: []const u8, at: usize) VerifierError!void {
    if (chunk.readU16(code, at) >= c.global_caches.items.len) return error.InvalidGlobalCacheIndex;
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

    /// Checks the operands of `op`, whose opcode byte is behind `ip`, as chunk.operandsOf
    /// lays them out, and steps over them.
    fn operands(self: *Walk, op: chunk.OpCode) VerifierError!void {
        const c = self.c;
        const code = self.code;
        switch (chunk.operandsOf(op)) {
            .none => {},
            .constant => try checkConstant(c, code[try self.take(1)]),
            .constant_wide => try checkConstant(c, chunk.readU16(code, try self.take(2))),
            .local => try self.scope.checkLocal(code[try self.take(1)]),
            .local_wide => try self.scope.checkLocal(chunk.readU16(code, try self.take(2))),
            .upvalue => try self.scope.checkUpvalue(code[try self.take(1)]),
            .count => _ = try self.take(1),
            .count_wide, .count_pair, .call => _ = try self.take(2),
            .kwarg => try checkConstant(c, code[try self.take(2) + 1]),
            .kwarg_wide => try checkConstant(c, chunk.readU16(code, try self.take(3) + 1)),
            .global => {
                const at = try self.take(3);
                try checkConstant(c, code[at]);
                try checkGlobalCache(c, code, at + 1);
            },
            .global_wide => {
                const at = try self.take(4);
                try checkConstant(c, chunk.readU16(code, at));
                try checkGlobalCache(c, code, at + 2);
            },
            .property => {
                const at = try self.take(3);
                try checkConstant(c, code[at]);
                try checkInlineCache(c, code, at + 1);
            },
            .property_wide => {
                const at = try self.take(4);
                try checkConstant(c, chunk.readU16(code, at));
                try checkInlineCache(c, code, at + 2);
            },
            .invoke => {
                const at = try self.take(5);
                try checkConstant(c, code[at]);
                try checkInlineCache(c, code, at + 3);
            },
            .invoke_wide => {
                const at = try self.take(6);
                try checkConstant(c, chunk.readU16(code, at));
                try checkInlineCache(c, code, at + 4);
            },
            .for_next => {
                const at = try self.take(2 + JUMP_OPERAND_SIZE);
                try self.scope.checkLocal(@as(usize, chunk.readU16(code, at)) + 1);
                try self.jumpTo(self.ip + chunk.readU32(code, at + 2));
            },
            .jump => {
                const offset = chunk.readU32(code, try self.take(JUMP_OPERAND_SIZE));
                try self.jumpTo(self.ip + offset);
            },
            .loop => {
                const offset = chunk.readU32(code, try self.take(JUMP_OPERAND_SIZE));
                if (self.ip < offset) return error.InvalidJumpOffset;
                try self.jumpTo(self.ip - offset);
            },
            .switch_table, .switch_table_wide => |layout| try self.jumpTable(layout == .switch_table_wide),
            .closure, .closure_wide => |layout| try self.closure(layout == .closure_wide),
        }
    }

    /// op_switch: a case count (1 or 2 bytes), the cases (a constant and a jump offset
    /// each), then the default's jump offset, all offsets from the end of the instruction.
    fn jumpTable(self: *Walk, wide: bool) VerifierError!void {
        const code = self.code;
        const count_at = try self.take(if (wide) 2 else 1);
        const case_count = if (wide) chunk.readU16(code, count_at) else @as(usize, code[count_at]);
        const table = try self.take(case_count * SWITCH_ENTRY_SIZE + JUMP_OPERAND_SIZE);
        const after = self.ip;
        for (0..case_count) |i| {
            const entry = table + i * SWITCH_ENTRY_SIZE;
            try checkConstant(self.c, chunk.readU16(code, entry));
            try self.jumpTo(after + chunk.readU32(code, entry + 2));
        }
        try self.jumpTo(after + chunk.readU32(code, after - JUMP_OPERAND_SIZE));
    }

    /// op_closure: the function's constant (1 or 2 bytes) and a descriptor per upvalue it
    /// captures; the function's own chunk is verified too, one level deeper.
    fn closure(self: *Walk, wide: bool) VerifierError!void {
        const code = self.code;
        const idx_at = try self.take(if (wide) 2 else 1);
        const func_idx = if (wide) chunk.readU16(code, idx_at) else @as(usize, code[idx_at]);
        try checkConstant(self.c, func_idx);
        // Anything but a function here means a corrupt script.
        const func_val = self.c.constants.items[func_idx];
        if (!func_val.isFunction()) return error.CorruptedBytecode;
        const func_obj = func_val.asFunction();

        const descriptors = try self.take(func_obj.upvalue_count * UPVALUE_DESCRIPTOR_SIZE);
        // Each upvalue captures one of this frame's locals or one of its upvalues.
        for (0..func_obj.upvalue_count) |i| {
            const at = descriptors + i * UPVALUE_DESCRIPTOR_SIZE;
            const captured = chunk.readU16(code, at + 1);
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
