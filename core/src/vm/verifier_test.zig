const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const verifier = @import("verifier.zig");
const value = @import("../core/value.zig");

test "Verifier: Accepts mathematically sound bytecode" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_nil, 0);
    try c.writeOp(testing.allocator, .op_return, 0);

    // Should pass without returning an error
    try verifier.verifyChunk(&c);
}

test "Verifier: Rejects truncated 1-byte operands (OutOfBoundsRead)" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    // op_constant requires 1 byte operand, but we provide none
    try c.writeOp(testing.allocator, .op_constant, 0);

    try testing.expectError(error.OutOfBoundsRead, verifier.verifyChunk(&c));
}

test "Verifier: Rejects truncated 4-byte operands" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    // op_invoke requires 4 bytes (name, arity, IC high, IC low)
    try c.writeOp(testing.allocator, .op_invoke, 0);
    try c.write(testing.allocator, 0, 0); // Provide only 1 byte

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

test "Verifier: Rejects backward jumps that underflow (InvalidJumpOffset)" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_loop, 0);
    // Try to jump backwards by 100 bytes when we are only at byte 4
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 0, 0);
    try c.write(testing.allocator, 100, 0);

    try testing.expectError(error.InvalidJumpOffset, verifier.verifyChunk(&c));
}

test "Verifier: Rejects invalid opcodes to prevent bad dispatch" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.write(testing.allocator, 255, 0); // 255 is not a valid mapped opcode

    try testing.expectError(error.InvalidOpCode, verifier.verifyChunk(&c));
}
