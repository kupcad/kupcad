const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");
const Compiler = @import("compiler.zig").Compiler;

test "Compiler: compiles basic binary addition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const left = try b.number("10", 0);
    const right = try b.number("5", 0);
    const bin_node = try b.binary(.add, left, right, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &out_chunk);
    try comp.compile(bin_node);

    try testing.expectEqual(@as(usize, 7), out_chunk.code.items.len);

    // Left Node
    try testing.expectEqual(@as(u8, @intFromEnum(chunk.OpCode.op_constant)), out_chunk.code.items[0]);
    try testing.expectEqual(@as(u8, 0), out_chunk.code.items[1]);
    try testing.expectEqual(@as(f64, 10.0), out_chunk.constants.items[0].asNumber());

    // Right Node
    try testing.expectEqual(@as(u8, @intFromEnum(chunk.OpCode.op_constant)), out_chunk.code.items[2]);
    try testing.expectEqual(@as(u8, 1), out_chunk.code.items[3]);
    try testing.expectEqual(@as(f64, 5.0), out_chunk.constants.items[1].asNumber());

    // Operator
    try testing.expectEqual(@as(u8, @intFromEnum(chunk.OpCode.op_add)), out_chunk.code.items[4]);
}
