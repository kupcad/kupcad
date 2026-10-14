const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const verifier = @import("verifier.zig");
const value = @import("../core/value.zig");
const VM = @import("vm.zig").VM;

/// Builds a chunk from raw `bytes` (opcodes already cast to u8).
fn chunkFrom(c: *chunk.Chunk, bytes: []const u8) !void {
    for (bytes) |b| try c.write(testing.allocator, b, 0);
}

fn opByte(o: chunk.OpCode) u8 {
    return @backingInt(o);
}

test "Verifier: Accepts mathematically sound bytecode" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_nil, 0);
    try c.writeOp(testing.allocator, .op_return, 0);

    try verifier.verifyChunk(testing.allocator, &c);
}

test "Verifier: Rejects truncated operands (OutOfBoundsRead)" {
    // Each opcode is followed by one byte fewer than its operand width
    const cases = [_]struct { op: chunk.OpCode, provided: usize }{
        .{ .op = .op_constant, .provided = 0 }, // 1-byte
        .{ .op = .op_constant_wide, .provided = 1 }, // 2-byte
        .{ .op = .op_get_property, .provided = 2 }, // 3-byte (name + IC)
        .{ .op = .op_call, .provided = 1 }, // 2-byte (arity + flags)
        .{ .op = .op_invoke, .provided = 4 }, // 5-byte (name + arity + flags + IC)
        .{ .op = .op_invoke_wide, .provided = 5 }, // 6-byte (wide name + arity + flags + IC)
    };
    for (cases) |case| {
        var c = chunk.Chunk.init();
        defer c.free(testing.allocator);
        try c.writeOp(testing.allocator, case.op, 0);
        for (0..case.provided) |_| try c.write(testing.allocator, 0, 0);
        try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(testing.allocator, &c));
    }
}

test "Verifier: Validates op_switch dynamic payload size" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_switch, 0);
    try c.write(testing.allocator, 2, 0); // case_count = 2 (expects 2*6 + 4 = 16 bytes)

    // Add only 10 bytes (simulating a corrupted switch table)
    for (0..10) |_| {
        try c.write(testing.allocator, 0, 0);
    }

    try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(testing.allocator, &c));
}

test "Verifier: Rejects jump offsets outside the chunk" {
    const cases = [_][]const u8{
        // Forward offset points way past the end of the code
        &.{ opByte(.op_jump), 0xFF, 0xFF, 0xFF, 0xFF },
        // Backward jump of 100 bytes when only 5 bytes precede the target
        &.{ opByte(.op_loop), 0, 0, 0, 100 },
    };
    for (cases) |bytes| {
        var c = chunk.Chunk.init();
        defer c.free(testing.allocator);
        try chunkFrom(&c, bytes);
        try testing.expectError(error.InvalidJumpOffset, verifier.verifyChunk(testing.allocator, &c));
    }
}

test "Verifier: Rejects jumps into the middle of an instruction" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);
    _ = try c.addConstant(testing.allocator, value.Value.initNumber(1));

    // op_jump +1 lands on the operand byte of the following op_constant
    const jump_low_byte = 4;
    try chunkFrom(&c, &.{ opByte(.op_jump), 0, 0, 0, 1, opByte(.op_constant), 0, opByte(.op_return) });
    try testing.expectError(error.InvalidJumpOffset, verifier.verifyChunk(testing.allocator, &c));

    // The same jump to an instruction boundary (+2) is accepted
    c.code.items[jump_low_byte] = 2;
    try verifier.verifyChunk(testing.allocator, &c);
}

test "Verifier: Rejects invalid opcodes to prevent bad dispatch" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.write(testing.allocator, 255, 0); // 255 is not a valid mapped opcode

    try testing.expectError(error.InvalidOpCode, verifier.verifyChunk(testing.allocator, &c));
}

test "Verifier: Rejects out-of-range constant indexes" {
    // The chunk holds exactly one constant (index 0); every operand below names index 7
    // or, for 2-byte operands, 0x0100.
    const cases = [_][]const u8{
        &.{ opByte(.op_constant), 7 },
        &.{ opByte(.op_get_global), 7 },
        &.{ opByte(.op_define_global), 7 },
        &.{ opByte(.op_set_global), 7 },
        &.{ opByte(.op_import), 7 },
        &.{ opByte(.op_class), 7 },
        &.{ opByte(.op_method), 7 },
        &.{ opByte(.op_constant_wide), 0x01, 0x00 },
        &.{ opByte(.op_import_wide), 0x01, 0x00 },
        // kwarg extraction: 1-byte map slot, then the key constant
        &.{ opByte(.op_extract_kwarg), 0, 7 },
        &.{ opByte(.op_extract_kwarg_wide), 0, 0x01, 0x00 },
        // property access: name constant, then a (valid) inline cache index
        &.{ opByte(.op_get_property), 7, 0, 0 },
        &.{ opByte(.op_invoke), 7, 0, 0, 0, 0 },
    };
    for (cases) |bytes| {
        var c = chunk.Chunk.init();
        defer c.free(testing.allocator);
        _ = try c.addConstant(testing.allocator, value.Value.initNumber(1));
        _ = try c.addInlineCache(testing.allocator);
        try chunkFrom(&c, bytes);
        try c.writeOp(testing.allocator, .op_return, 0);
        try testing.expectError(error.InvalidConstantIndex, verifier.verifyChunk(testing.allocator, &c));
    }
}

test "Verifier: Rejects out-of-range inline cache indexes" {
    // Name constant 0 is valid; the inline cache index (0) is only valid once a cache exists
    const cases = [_][]const u8{
        &.{ opByte(.op_get_property), 0, 0, 0 },
        &.{ opByte(.op_set_property), 0, 0, 0 },
        &.{ opByte(.op_get_property_wide), 0, 0, 0, 0 },
        &.{ opByte(.op_set_property_wide), 0, 0, 0, 0 },
        &.{ opByte(.op_invoke), 0, 1, 0, 0, 0 },
        &.{ opByte(.op_invoke_wide), 0, 0, 1, 0, 0, 0 },
    };
    for (cases) |bytes| {
        var c = chunk.Chunk.init();
        defer c.free(testing.allocator);
        _ = try c.addConstant(testing.allocator, value.Value.initNumber(1));
        try chunkFrom(&c, bytes);
        try c.writeOp(testing.allocator, .op_return, 0);
        try testing.expectError(error.InvalidInlineCacheIndex, verifier.verifyChunk(testing.allocator, &c));

        _ = try c.addInlineCache(testing.allocator);
        try verifier.verifyChunk(testing.allocator, &c);
    }
}

test "Verifier: Validates op_switch case constants and jump targets" {
    // Layout: op_switch, count=1, [key constant u16, offset u32], default offset u32,
    // then op_constant 0 (2 bytes) and op_return. Offsets are relative to the end of
    // the switch instruction: +0 = op_constant, +1 = its operand, +2 = op_return, +3 = end.
    const Case = struct { key: u8, case_off: u8, default_off: u8, expected: ?verifier.VerifierError };
    const cases = [_]Case{
        .{ .key = 0, .case_off = 2, .default_off = 0, .expected = null },
        .{ .key = 0, .case_off = 3, .default_off = 3, .expected = null }, // end of code is a boundary
        .{ .key = 5, .case_off = 0, .default_off = 0, .expected = error.InvalidConstantIndex },
        .{ .key = 0, .case_off = 4, .default_off = 0, .expected = error.InvalidJumpOffset },
        .{ .key = 0, .case_off = 0, .default_off = 4, .expected = error.InvalidJumpOffset },
        .{ .key = 0, .case_off = 1, .default_off = 0, .expected = error.InvalidJumpOffset },
        .{ .key = 0, .case_off = 0, .default_off = 1, .expected = error.InvalidJumpOffset },
    };
    for (cases) |case| {
        var c = chunk.Chunk.init();
        defer c.free(testing.allocator);
        _ = try c.addConstant(testing.allocator, value.Value.initNumber(1));
        try chunkFrom(&c, &.{ opByte(.op_switch), 1 });
        try chunkFrom(&c, &.{ 0, case.key, 0, 0, 0, case.case_off });
        try chunkFrom(&c, &.{ 0, 0, 0, case.default_off });
        try chunkFrom(&c, &.{ opByte(.op_constant), 0, opByte(.op_return) });
        if (case.expected) |err| {
            try testing.expectError(err, verifier.verifyChunk(testing.allocator, &c));
        } else {
            try verifier.verifyChunk(testing.allocator, &c);
        }
    }
}

test "Verifier: op_closure validates constant array boundaries" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_closure, 0);
    try c.write(testing.allocator, 99, 0); // Constant 99 doesn't exist

    try testing.expectError(error.InvalidConstantIndex, verifier.verifyChunk(testing.allocator, &c));
}

test "Verifier: op_closure rejects targeting non-function constants" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    // Constant is a Number, not a Function!
    const dummy_idx = try c.addConstant(testing.allocator, value.Value.initNumber(42.0));

    try c.writeOp(testing.allocator, .op_closure, 0);
    try c.write(testing.allocator, @intCast(dummy_idx), 0);

    try testing.expectError(error.CorruptedBytecode, verifier.verifyChunk(testing.allocator, &c));
}

test "Verifier: op_closure detects truncated upvalue payloads" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    const func = try vm.gc.allocateFunction(&vm);
    func.upvalue_count = 2; // Expects 6 bytes of upvalue data (2 * 3)

    const func_idx = try c.addConstant(testing.allocator, value.Value.initObj(&func.obj));

    try c.writeOp(testing.allocator, .op_closure, 0);
    try c.write(testing.allocator, @intCast(func_idx), 0);

    // Provide only 2 bytes of upvalue routing data instead of the required 6
    try c.write(testing.allocator, 1, 0);
    try c.write(testing.allocator, 0, 0);

    try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(testing.allocator, &c));
}

test "Verifier: op_closure verifies the nested function's chunk" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // The nested body is malformed even though the outer chunk is well-formed
    var child = chunk.Chunk.init();
    defer child.free(testing.allocator);
    try child.write(testing.allocator, 255, 0);

    var parent = chunk.Chunk.init();
    defer parent.free(testing.allocator);

    const func = try vm.gc.allocateFunction(&vm);
    func.owns_chunk = false;
    func.chunk = &child;
    _ = try parent.addConstant(testing.allocator, value.Value.initObj(&func.obj));
    try chunkFrom(&parent, &.{ opByte(.op_closure), 0, opByte(.op_return) });

    try testing.expectError(error.InvalidOpCode, verifier.verifyChunk(testing.allocator, &parent));

    // A function whose chunk is the chunk being verified would recurse forever
    func.chunk = &parent;
    try testing.expectError(error.CorruptedBytecode, verifier.verifyChunk(testing.allocator, &parent));
}

// --- interpret runs the verifier before execution ---

test "Verifier: interpret refuses malformed bytecode instead of indexing out of bounds" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.mute_errors = true;

    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);
    try c.writeOp(testing.allocator, .op_constant, 0);
    try c.write(testing.allocator, 200, 0);
    try c.writeOp(testing.allocator, .op_return, 0);

    try testing.expectEqual(.compile_error, vm.interpret(&c));
}

test "Verifier: local and upvalue slots must lie in the frame and the closure" {
    // Out-of-range slots used to reach the VM, where only debug builds assert.
    const cases = [_]struct { bytes: []const u8, ok: bool }{
        .{ .bytes = &.{ opByte(.op_get_local), 1 }, .ok = true },
        .{ .bytes = &.{ opByte(.op_get_local), 2 }, .ok = false },
        .{ .bytes = &.{ opByte(.op_nil), opByte(.op_set_local), 2 }, .ok = false },
        .{ .bytes = &.{ opByte(.op_get_local_wide), 0x01, 0x00 }, .ok = false },
        // A top-level chunk has no enclosing closure, so no upvalues.
        .{ .bytes = &.{ opByte(.op_get_upvalue), 0 }, .ok = false },
        .{ .bytes = &.{ opByte(.op_nil), opByte(.op_set_upvalue), 0 }, .ok = false },
    };
    for (cases) |case| {
        errdefer std.debug.print("bytes: {any}\n", .{case.bytes});
        var c = chunk.Chunk.init();
        defer c.free(testing.allocator);
        c.local_count = 2;
        try chunkFrom(&c, case.bytes);
        try c.writeOp(testing.allocator, .op_return, 0);
        if (case.ok) try verifier.verifyChunk(testing.allocator, &c) else try testing.expectError(error.InvalidSlot, verifier.verifyChunk(testing.allocator, &c));
    }
}

test "Verifier: a closure captures only its parent's locals and upvalues" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const cases = [_]struct { is_local: u8, index: u8, child_reads: u8, expected: ?anyerror }{
        .{ .is_local = 1, .index = 1, .child_reads = 0, .expected = null },
        .{ .is_local = 1, .index = 5, .child_reads = 0, .expected = error.InvalidSlot }, // no such local
        .{ .is_local = 0, .index = 0, .child_reads = 0, .expected = error.InvalidSlot }, // the parent has no upvalues
        .{ .is_local = 7, .index = 1, .child_reads = 0, .expected = error.CorruptedBytecode },
        .{ .is_local = 1, .index = 1, .child_reads = 1, .expected = error.InvalidSlot }, // the child has one upvalue
    };
    for (cases) |case| {
        var child = chunk.Chunk.init();
        defer child.free(testing.allocator);
        try chunkFrom(&child, &.{ opByte(.op_get_upvalue), case.child_reads, opByte(.op_return) });

        const func = try vm.gc.allocateFunction(&vm);
        func.chunk = &child;
        func.owns_chunk = false;
        func.upvalue_count = 1;

        var parent = chunk.Chunk.init();
        defer parent.free(testing.allocator);
        parent.local_count = 2;
        const func_idx = try parent.addConstant(testing.allocator, value.Value.initObj(&func.obj));
        try chunkFrom(&parent, &.{ opByte(.op_closure), @intCast(func_idx), case.is_local, 0, case.index, opByte(.op_return) });

        if (case.expected) |err| try testing.expectError(err, verifier.verifyChunk(testing.allocator, &parent)) else try verifier.verifyChunk(testing.allocator, &parent);
    }
}

test "Verifier: op_for_next needs both of its loop slots and an exit inside the chunk" {
    // [op_for_next slot:u16 exit:u32] [op_nil] [op_return]; the exit lands on op_nil.
    const cases = [_]struct { slot: u8, exit: u8, local_count: u16, expected: ?anyerror }{
        .{ .slot = 0, .exit = 0, .local_count = 2, .expected = null },
        .{ .slot = 1, .exit = 0, .local_count = 2, .expected = error.InvalidSlot }, // slot 2 holds the count
        .{ .slot = 0, .exit = 9, .local_count = 2, .expected = error.InvalidJumpOffset },
    };
    for (cases) |case| {
        var c = chunk.Chunk.init();
        defer c.free(testing.allocator);
        c.local_count = case.local_count;
        try chunkFrom(&c, &.{ opByte(.op_for_next), 0, case.slot, 0, 0, 0, case.exit, opByte(.op_nil), opByte(.op_return) });
        if (case.expected) |err| try testing.expectError(err, verifier.verifyChunk(testing.allocator, &c)) else try verifier.verifyChunk(testing.allocator, &c);
    }
    var short = chunk.Chunk.init();
    defer short.free(testing.allocator);
    short.local_count = 2;
    try chunkFrom(&short, &.{ opByte(.op_for_next), 0, 0, 0, 0 });
    try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(testing.allocator, &short));
}
