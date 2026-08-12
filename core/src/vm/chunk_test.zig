const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const value = @import("../core/value.zig");

test "Chunk: add constants to pool" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    // Using Value API methods
    const val = value.Value.initNumber(42.5);
    const index = try c.addConstant(testing.allocator, val);

    // Validate that the constant pool returns 0-based indices
    try testing.expectEqual(@as(u8, 0), index);

    // Using ValueArray API
    try testing.expectEqual(@as(usize, 1), c.constants.items.len);
    try testing.expectEqual(@as(f64, 42.5), c.constants.items[0].asNumber());
}

test "Chunk: handles Phase 1-5 advanced opcodes" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    // Test writing new opcodes with varying line numbers to test RLE
    try c.writeOp(testing.allocator, .op_build_range, 0);
    try c.writeOp(testing.allocator, .op_array_spread, 0);

    // Test jump instruction spacing
    try c.writeOp(testing.allocator, .op_setup_rescue, 0);
    try c.write(testing.allocator, 0x00, 0); // High byte
    try c.write(testing.allocator, 0xFF, 0); // Low byte

    try testing.expectEqual(@as(usize, 5), c.code.items.len);
    try testing.expectEqual(chunk.OpCode.op_build_range, @as(chunk.OpCode, @enumFromInt(c.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_array_spread, @as(chunk.OpCode, @enumFromInt(c.code.items[1])));
    try testing.expectEqual(chunk.OpCode.op_setup_rescue, @as(chunk.OpCode, @enumFromInt(c.code.items[2])));
}

test "Chunk: DebugSpan RLE compression groups identical source offsets" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    // Write 3 instructions occurring at source offset 10 (e.g., same AST node)
    try c.writeOp(testing.allocator, .op_nil, 10);
    try c.writeOp(testing.allocator, .op_true, 10);
    try c.writeOp(testing.allocator, .op_false, 10);

    // Write 1 instruction occurring at source offset 25
    try c.writeOp(testing.allocator, .op_return, 25);

    // Verify raw bytecode length
    try testing.expectEqual(@as(usize, 4), c.code.items.len);

    // Verify RLE compression: 4 instructions should be compressed into exactly 2 spans!
    try testing.expectEqual(@as(usize, 2), c.debug_spans.items.len);

    // Span 1: IP 0 -> Offset 10
    try testing.expectEqual(@as(u32, 0), c.debug_spans.items[0].ip);
    try testing.expectEqual(@as(u32, 10), c.debug_spans.items[0].source_offset);

    // Span 2: IP 3 -> Offset 25
    try testing.expectEqual(@as(u32, 3), c.debug_spans.items[1].ip);
    try testing.expectEqual(@as(u32, 25), c.debug_spans.items[1].source_offset);

    // Verify the O(N) lookup resolves the IP back to the correct offset
    try testing.expectEqual(@as(u32, 10), c.getOffset(0));
    try testing.expectEqual(@as(u32, 10), c.getOffset(2)); // Still inside the first span
    try testing.expectEqual(@as(u32, 25), c.getOffset(3)); // Crossed into the second span
}
