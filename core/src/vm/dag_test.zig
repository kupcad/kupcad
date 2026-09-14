const std = @import("std");
const dag = @import("dag.zig");

test "DAG: addBalancedChain flattens Unions into Batch nodes" {
    // Setup
    var buffer: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var builder = @import("dag.zig").DAGBuilder.init(fba.allocator());
    defer builder.deinit();

    const c1 = try builder.addCube(10, 10, 10, true);
    const c2 = try builder.addCube(20, 20, 20, true);
    const c3 = try builder.addCube(30, 30, 30, true);
    const c4 = try builder.addCube(40, 40, 40, true);

    const targets = [_]u32{ c1, c2, c3, c4 };

    // Action
    const result_idx = try builder.addBalancedChain(.union_op, &targets);
    const root_node = builder.nodes.items[result_idx];

    // Assert: It bypassed binary trees and flattened to a single Batch Union
    try std.testing.expectEqual(.batch_union_op, root_node.tag);

    const payload = builder.getBatchUnionPayload(root_node);
    try std.testing.expectEqual(@as(usize, 4), payload.len);
}

test "DAG: addBalancedChain balances Differences into an O(log N) tree" {
    var buffer: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var builder = @import("dag.zig").DAGBuilder.init(fba.allocator());
    defer builder.deinit();

    const c1 = try builder.addCube(10, 10, 10, true);
    const c2 = try builder.addCube(20, 20, 20, true);
    const c3 = try builder.addCube(30, 30, 30, true);
    const c4 = try builder.addCube(40, 40, 40, true);

    const targets = [_]u32{ c1, c2, c3, c4 };

    // Action
    const root_idx = try builder.addBalancedChain(.difference_op, &targets);
    const root_node = builder.nodes.items[root_idx];

    // Assert: Root is a difference_op, not a batch
    try std.testing.expectEqual(.difference_op, root_node.tag);

    const root_payload = builder.getBinaryPayload(root_node);

    const left_node = builder.nodes.items[root_payload.left];
    const right_node = builder.nodes.items[root_payload.right];

    // Assert: Tree is perfectly balanced (c1 - c2) - (c3 - c4)
    try std.testing.expectEqual(.difference_op, left_node.tag);
    try std.testing.expectEqual(.difference_op, right_node.tag);

    const left_payload = builder.getBinaryPayload(left_node);
    try std.testing.expectEqual(c1, left_payload.left);
    try std.testing.expectEqual(c2, left_payload.right);
}
