const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const token = @import("token.zig");

const TestContext = struct {
    node_count: usize = 0,
};

fn countNodes(ptr: *anyopaque, node: *ast.Node) anyerror!bool {
    _ = node;
    var ctx = @as(*TestContext, @ptrCast(@alignCast(ptr)));
    ctx.node_count += 1;
    // Returning true tells the Visitor to automatically traverse children
    return true;
}

test "AST Visitor: Successfully walks all nodes automatically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const loc = token.Location{ .line = 1, .col = 1, .offset = 0, .length = 0, .file_id = 0 };

    // Construct a simulated manual AST: `1 + 2`
    const left = try b.number("1", loc);
    const right = try b.number("2", loc);
    const bin_op = try b.createNode(.{ .binary_op = try b.box(ast.BinaryExpr, .{ .op = .add, .left = left, .right = right }) }, loc);

    var ctx = TestContext{};
    const visitor = ast.Visitor{
        .ptr = &ctx,
        .visitFn = countNodes,
    };

    try visitor.walk(bin_op);

    // It should have successfully traversed the binary_op, the left number, and the right number
    try testing.expectEqual(@as(usize, 3), ctx.node_count);
}
