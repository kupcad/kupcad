const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const verifier = @import("verifier.zig");
const value = @import("../core/value.zig");
const VM = @import("vm.zig").VM;

test "Verifier: Accepts mathematically sound bytecode" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_nil, 0);
    try c.writeOp(testing.allocator, .op_return, 0);

    try verifier.verifyChunk(&c);
}

test "Verifier: Rejects truncated 1-byte operands (OutOfBoundsRead)" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_constant, 0);
    // Missing 1 byte operand
    try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(&c));
}

test "Verifier: Rejects truncated 2-byte operands" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_constant_wide, 0);
    try c.write(testing.allocator, 0, 0); // Provide 1 byte instead of 2

    try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(&c));
}

test "Verifier: Rejects truncated 3-byte operands" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_get_property, 0);
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 0, 0); // Provide 2 bytes instead of 3

    try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(&c));
}

test "Verifier: Rejects truncated 4-byte operands" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_invoke, 0);
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 0, 0); // Provide 3 bytes instead of 4

    try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(&c));
}

test "Verifier: Rejects truncated 5-byte operands" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_invoke_wide, 0);
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 0, 0); // Provide 4 bytes instead of 5

    try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(&c));
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

    try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(&c));
}

test "Verifier: Rejects invalid jump offsets safely" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_jump, 0);
    try c.write(testing.allocator, 0xFF, 0);
    try c.write(testing.allocator, 0xFF, 0);
    try c.write(testing.allocator, 0xFF, 0);
    try c.write(testing.allocator, 0xFF, 0); // Offset points way past the end of the array

    try testing.expectError(error.InvalidJumpOffset, verifier.verifyChunk(&c));
}

test "Verifier: Rejects backward jumps that underflow" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_loop, 0);
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 100, 0); // Jump backwards 100 bytes when we are only at byte 4

    try testing.expectError(error.InvalidJumpOffset, verifier.verifyChunk(&c));
}

test "Verifier: Rejects invalid opcodes to prevent bad dispatch" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.write(testing.allocator, 255, 0); // 255 is not a valid mapped opcode

    try testing.expectError(error.InvalidOpCode, verifier.verifyChunk(&c));
}

test "Verifier: op_closure validates constant array boundaries" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_closure, 0);
    try c.write(testing.allocator, 99, 0); // Constant 99 doesn't exist

    try testing.expectError(error.InvalidConstantIndex, verifier.verifyChunk(&c));
}

test "Verifier: op_closure rejects targeting non-function constants" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    // Constant is a Number, not a Function!
    const dummy_idx = try c.addConstant(testing.allocator, value.Value.initNumber(42.0));

    try c.writeOp(testing.allocator, .op_closure, 0);
    try c.write(testing.allocator, @intCast(dummy_idx), 0);

    try testing.expectError(error.CorruptedBytecode, verifier.verifyChunk(&c));
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

    try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(&c));
}
