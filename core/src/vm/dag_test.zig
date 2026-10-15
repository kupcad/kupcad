const std = @import("std");
const dag = @import("dag.zig");
const geom = @import("../kernel/geometry_handle.zig");

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

// --- CSE hashing and child validation ---

test "DAG: polyhedron hash separates points and faces" {
    var b1 = dag.DAGBuilder.init(std.testing.allocator);
    defer b1.deinit();
    var b2 = dag.DAGBuilder.init(std.testing.allocator);
    defer b2.deinit();

    // The last point of `pts1` has the exact bytes of the first two faces of
    // `faces2`, so both pts++faces byte streams are identical.
    const shifted = [2][3]u32{ .{ 0, 1, 2 }, .{ 3, 4, 5 } };
    const as_point: [3]f64 = @bitCast(shifted);
    const pts1 = [_][3]f64{ .{ 0, 0, 0 }, as_point };
    const faces1 = [_][3]u32{.{ 6, 7, 8 }};
    const pts2 = [_][3]f64{.{ 0, 0, 0 }};
    const faces2 = [_][3]u32{ shifted[0], shifted[1], .{ 6, 7, 8 } };

    // Separate builders, so a structural-equality fallback cannot hide a collision.
    const p1 = try b1.addPolyhedron(&pts1, &faces1);
    const p2 = try b2.addPolyhedron(&pts2, &faces2);
    try std.testing.expect(b1.node_hashes.items[p1] != b2.node_hashes.items[p2]);
}

test "DAG: a raw hash collision does not merge different nodes" {
    // Learn the hash cube(2) will get, using a scratch builder (hashing is content-based).
    var scratch = dag.DAGBuilder.init(std.testing.allocator);
    defer scratch.deinit();
    const c2_scratch = try scratch.addCube(2, 2, 2, false);
    const c2_hash = scratch.node_hashes.items[c2_scratch];

    var builder = dag.DAGBuilder.init(std.testing.allocator);
    defer builder.deinit();
    const c1 = try builder.addCube(1, 1, 1, false);

    // Simulate a 64-bit collision: cube(2)'s hash already maps to cube(1).
    try builder.dedup_map.put(builder.arena.allocator(), c2_hash, c1);

    const c2 = try builder.addCube(2, 2, 2, false);
    try std.testing.expect(c2 != c1);
    try std.testing.expect(builder.node_hashes.items[c2] != builder.node_hashes.items[c1]);
    try std.testing.expect(builder.node_hashes.items[c2] != c2_hash);

    // Identical nodes still deduplicate (via the probed hash).
    try std.testing.expectEqual(c2, try builder.addCube(2, 2, 2, false));
}

test "DAG: builder rejects the concrete sentinel as a child" {
    // The sentinel marks concrete (decompose/simplify) leaves; it is not a node index.
    var builder = dag.DAGBuilder.init(std.testing.allocator);
    defer builder.deinit();
    const c = try builder.addCube(1, 1, 1, false);
    try std.testing.expectError(error.InvalidDAGNode, builder.addTranslate(dag.CONCRETE_NODE_SENTINEL, 1, 0, 0));
    try std.testing.expectError(error.InvalidDAGNode, builder.addBinary(.union_op, c, dag.CONCRETE_NODE_SENTINEL));
    try std.testing.expectError(error.InvalidDAGNode, builder.addBatchUnion(&.{ c, dag.CONCRETE_NODE_SENTINEL }));
    // Rollback leaves the builder usable.
    try std.testing.expectEqual(@as(usize, 1), builder.nodes.items.len);
}

test "DAG: settings are interned, the defaults being id 0" {
    var builder = dag.DAGBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try std.testing.expectEqual(@as(dag.SettingsId, 0), try builder.internSettings(.{}));
    const brep = try builder.internSettings(.{ .engine = .brep_native });
    try std.testing.expect(brep != 0);
    try std.testing.expectEqual(brep, try builder.internSettings(.{ .engine = .brep_native }));
    try std.testing.expect(try builder.internSettings(.{ .tolerance = 1e-3 }) != brep);
    try std.testing.expectEqual(geom.EngineType.brep_native, builder.settings(brep).engine);
}

test "DAG: a node records the settings it was made under, and they tell it apart" {
    var builder = dag.DAGBuilder.init(std.testing.allocator);
    defer builder.deinit();
    const plain = try builder.addCube(1, 1, 1, false);
    builder.current_settings = try builder.internSettings(.{ .tolerance = 1e-3 });
    const fine = try builder.addCube(1, 1, 1, false);
    try std.testing.expect(fine != plain); // not merged by CSE
    try std.testing.expect(builder.node_hashes.items[fine] != builder.node_hashes.items[plain]);
    try std.testing.expectEqual(@as(f64, 1e-3), builder.settings(builder.nodes.items[fine].settings).tolerance);
    try std.testing.expectEqual(plain, blk: {
        builder.current_settings = 0;
        break :blk try builder.addCube(1, 1, 1, false);
    });
}
