const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const value = @import("../core/value.zig");

test "Chunk: initialize and write opcodes" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_return, 10);

    // Validate that the array accurately tracked both the byte and the line number
    try testing.expectEqual(@as(usize, 1), c.code.items.len);
    try testing.expectEqual(@as(u8, @intFromEnum(chunk.OpCode.op_return)), c.code.items[0]);
    try testing.expectEqual(@as(usize, 1), c.lines.items.len);
    try testing.expectEqual(@as(u32, 10), c.lines.items[0]);
}

test "Chunk: add constants to pool" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    // Using your actual Value API methods
    const val = value.Value.initNumber(42.5);
    const index = try c.addConstant(testing.allocator, val);

    // Validate that the constant pool returns 0-based indices
    try testing.expectEqual(@as(u8, 0), index);

    // Using your native ValueArray (ArrayListUnmanaged) API
    try testing.expectEqual(@as(usize, 1), c.constants.items.len);
    try testing.expectEqual(@as(f64, 42.5), c.constants.items[0].asNumber());
}
