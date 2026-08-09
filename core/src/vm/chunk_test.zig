const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const value = @import("../core/value.zig");

test "Chunk: initialize and write opcodes with RLE line tracking" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    try c.writeOp(testing.allocator, .op_return, 10);

    // Validate that the array accurately tracked both the byte and the line start
    try testing.expectEqual(@as(usize, 1), c.code.items.len);
    try testing.expectEqual(@as(u8, @intFromEnum(chunk.OpCode.op_return)), c.code.items[0]);
    try testing.expectEqual(@as(usize, 1), c.lines.items.len);
    try testing.expectEqual(@as(u32, 10), c.lines.items[0].line);
    try testing.expectEqual(@as(u32, 1), c.lines.items[0].count);
}

test "Chunk: RLE line compression groups contiguous instructions on same line" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);

    // Write 3 instructions on line 42 and 1 instruction on line 43
    try c.writeOp(testing.allocator, .op_nil, 42);
    try c.writeOp(testing.allocator, .op_true, 42);
    try c.writeOp(testing.allocator, .op_false, 42);
    try c.writeOp(testing.allocator, .op_return, 43);

    try testing.expectEqual(@as(usize, 4), c.code.items.len);

    // RLE compression should create exactly 2 LineStart entries
    try testing.expectEqual(@as(usize, 2), c.lines.items.len);

    // Entry 1: Line 42 (3 instructions)
    try testing.expectEqual(@as(u32, 42), c.lines.items[0].line);
    try testing.expectEqual(@as(u32, 3), c.lines.items[0].count);

    // Entry 2: Line 43 (1 instruction)
    try testing.expectEqual(@as(u32, 43), c.lines.items[1].line);
    try testing.expectEqual(@as(u32, 1), c.lines.items[1].count);
}

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
