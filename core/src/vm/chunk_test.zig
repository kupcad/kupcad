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
    try c.writeOp(testing.allocator, .op_build_range);
    try c.writeOp(testing.allocator, .op_array_spread);

    // Test jump instruction spacing
    try c.writeOp(testing.allocator, .op_setup_rescue);
    try c.write(testing.allocator, 0x00); // High byte
    try c.write(testing.allocator, 0xFF); // Low byte

    try testing.expectEqual(@as(usize, 5), c.code.items.len);
    try testing.expectEqual(chunk.OpCode.op_build_range, @as(chunk.OpCode, @enumFromInt(c.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_array_spread, @as(chunk.OpCode, @enumFromInt(c.code.items[1])));
    try testing.expectEqual(chunk.OpCode.op_setup_rescue, @as(chunk.OpCode, @enumFromInt(c.code.items[2])));
}
