const std = @import("std");
const dag = @import("dag.zig");
const bezier = @import("../core/bezier.zig");
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

test "DAG: addBalancedChain subtracts the union of the cutters" {
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

    // c1 - (c2 ∪ c3 ∪ c4): one difference whose cutter is a batch union. It used to be
    // the balanced (c1 - c2) - (c3 - c4), which isn't a difference of the four.
    try std.testing.expectEqual(.difference_op, root_node.tag);
    const root_payload = builder.getBinaryPayload(root_node);
    try std.testing.expectEqual(c1, root_payload.left);

    const cutters = builder.nodes.items[root_payload.right];
    try std.testing.expectEqual(.batch_union_op, cutters.tag);
    try std.testing.expectEqualSlices(u32, &.{ c2, c3, c4 }, builder.getBatchUnionPayload(cutters));
}

// --- CSE hashing and child validation ---

test "DAG: a projection as made is built under its target's settings, and the ones in force stay" {
    var b = dag.DAGBuilder.init(std.testing.allocator);
    defer b.deinit();
    const fine = try b.internSettings(.{ .tolerance = 0.5 });
    b.current_settings = fine;
    const cube = try b.addCube(1, 1, 1, false);
    b.current_settings = 0;
    const as_made = try b.addProjectAsMade(cube);
    try std.testing.expectEqual(fine, b.nodes.items[as_made].settings);
    try std.testing.expectEqual(@as(dag.SettingsId, 0), b.current_settings);
    // A plain projection takes the settings in force, so the two are different nodes
    const plain = try b.addProject(cube);
    try std.testing.expectEqual(@as(dag.SettingsId, 0), b.nodes.items[plain].settings);
    try std.testing.expect(plain != as_made);
}

test "DAG: polyhedron hash separates points and faces" {
    var b1 = dag.DAGBuilder.init(std.testing.allocator);
    defer b1.deinit();
    var b2 = dag.DAGBuilder.init(std.testing.allocator);
    defer b2.deinit();

    // The last point of `pts1` has the exact bytes of the first two faces of
    // `faces2` (all zero), so both pts++faces byte streams are identical; every face
    // names a point its own polyhedron has.
    const shifted = [2][3]u32{ .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    const as_point: [3]f64 = @bitCast(shifted);
    const pts1 = [_][3]f64{ .{ 0, 0, 0 }, as_point };
    const faces1 = [_][3]u32{.{ 0, 0, 0 }};
    const pts2 = [_][3]f64{.{ 0, 0, 0 }};
    const faces2 = [_][3]u32{ shifted[0], shifted[1], .{ 0, 0, 0 } };

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
    try builder.dedup_map.put(builder.gpa, c2_hash, c1);

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

test "DAG: operandsOf gives each node's operands, whatever its layout" {
    var b = dag.DAGBuilder.init(std.testing.allocator);
    defer b.deinit();
    const cube = try b.addCube(1, 1, 1, false);
    const ball = try b.addSphere(1, 8);
    const small = try b.addSquare(1, 1, true);
    const big = try b.addSquare(2, 2, true);
    const cases = [_]struct { node: dag.DAGNodeIndex, operands: []const dag.DAGNodeIndex }{
        .{ .node = cube, .operands = &.{} },
        .{ .node = try b.addBinary(.difference_op, cube, ball), .operands = &.{ cube, ball } },
        .{ .node = try b.addBatchUnion(&.{ ball, cube }), .operands = &.{ ball, cube } },
        .{ .node = try b.addHull(ball), .operands = &.{ball} },
        .{ .node = try b.addTranslate(cube, 1, 2, 3), .operands = &.{cube} },
        .{ .node = try b.addSetMaterial(ball, 1), .operands = &.{ball} },
        .{ .node = try b.addLoft(small, big, 4), .operands = &.{ small, big } },
        .{ .node = try b.addExtrude(big, 2, 0, 0, 1, 1), .operands = &.{big} },
        .{ .node = try b.addPolygon(@constCast(&[_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } })), .operands = &.{} },
        .{ .node = try b.addPolyhedron(&.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } }, &.{ .{ 0, 1, 2 }, .{ 0, 3, 1 }, .{ 0, 2, 3 }, .{ 1, 3, 2 } }), .operands = &.{} },
    };
    for (cases) |case| {
        errdefer std.debug.print("node: {s}\n", .{@tagName(b.nodes.items[case.node].tag)});
        try std.testing.expectEqualSlices(dag.DAGNodeIndex, case.operands, b.operandsOf(b.nodes.items[case.node]));
    }
}

test "DAG: compaction keeps the live nodes with their payloads, hashes and meshes" {
    const kernel = @import("../kernel/kernel.zig");
    var b = dag.DAGBuilder.init(std.testing.allocator);
    defer b.deinit();
    // One node of each layout, with dead nodes between them.
    const dead_cube = try b.addCube(9, 9, 9, false);
    const cube = try b.addCube(1, 2, 3, true);
    b.current_settings = try b.internSettings(.{ .tolerance = 0.01 });
    const ball = try b.addSphere(1.5, 12);
    b.current_settings = 0;
    _ = try b.addTranslate(dead_cube, 1, 1, 1);
    const cut = try b.addBinary(.difference_op, cube, ball);
    const many = try b.addBatchUnion(&.{ cube, ball, cut });
    const moved = try b.addTranslate(many, 1, 2, 3);
    const tinted = try b.addSetMaterial(moved, 2);
    const named = try b.addSetName(tinted, try b.internPartName("frame"));
    const hulled = try b.addHull(named);
    const small = try b.addSquare(1, 1, true);
    const big = try b.addSquare(2, 2, true);
    const lofted = try b.addLoft(small, big, 4);
    const outline = try b.addPolygon(@constCast(&[_][2]f64{ .{ 0, 0 }, .{ 3, 0 }, .{ 0, 3 } }));
    const two = [_][]const [2]f64{ &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 0, 4 } }, &.{ .{ 1, 1 }, .{ 2, 1 }, .{ 1, 2 } } };
    const holed = try b.addPolygonsEvenOdd(&two, &.{});
    const shifted = try b.addCrossSectionTransform(holed, .{ 1, 0, 0, 1, 5, 5 });
    const tetra = try b.addPolyhedron(&.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } }, &.{ .{ 0, 1, 2 }, .{ 0, 3, 1 }, .{ 0, 2, 3 }, .{ 1, 3, 2 } });
    const dead_leaf = try b.addConcrete(kernel.cube(&.{}, 1, 1, 1, false) orelse return error.KernelFailed);
    const leaf = try b.addConcrete(kernel.cube(&.{}, 2, 2, 2, false) orelse return error.KernelFailed);
    const empty = try b.addEmpty(true);
    _ = dead_leaf;

    const roots = [_]dag.DAGNodeIndex{ hulled, lofted, outline, shifted, tetra, leaf, empty };
    var live = try b.liveNodes(std.testing.allocator, &roots);
    defer live.deinit(std.testing.allocator);
    const hashes_before = try std.testing.allocator.dupe(u64, b.node_hashes.items);
    defer std.testing.allocator.free(hashes_before);
    const nodes_before = b.nodes.items.len;

    const renumbered = try b.compact(&live);
    defer std.testing.allocator.free(renumbered);

    try std.testing.expectEqual(live.count(), b.nodes.items.len);
    try std.testing.expect(b.nodes.items.len < nodes_before);
    try std.testing.expectEqual(@as(usize, 1), b.held_leaves);
    for (0..nodes_before) |old| {
        if (!live.isSet(old)) {
            try std.testing.expectEqual(std.math.maxInt(dag.DAGNodeIndex), renumbered[old]);
            continue;
        }
        const new = renumbered[old];
        errdefer std.debug.print("node {d} ({s}), now {d}\n", .{ old, @tagName(b.nodes.items[new].tag), new });
        // The hash covers the payload and the operands' hashes: equal, the copy is whole.
        try std.testing.expectEqual(hashes_before[old], b.node_hashes.items[new]);
        try std.testing.expectEqual(hashes_before[old], try b.recomputedHash(new));
    }
    try std.testing.expectEqual(@as(dag.SettingsId, 1), b.nodes.items[renumbered[ball]].settings);
    // The part names stay, as the settings do
    try std.testing.expectEqualStrings("frame", b.partName(b.getNamePayload(b.nodes.items[renumbered[named]]).name_id));
    // An identical node is still found, at its new index.
    try std.testing.expectEqual(renumbered[cube], try b.addCube(1, 2, 3, true));
    try std.testing.expectEqual(renumbered[moved], try b.addTranslate(renumbered[many], 1, 2, 3));
}

test "DAG: a node is found again exactly when every part of its payload matches" {
    // Hashing and equality both read the payload by its layout (payloadParts); each layout
    // here is built twice alike, then with one part changed.
    const kernel = @import("../kernel/kernel.zig");
    var b = dag.DAGBuilder.init(std.testing.allocator);
    defer b.deinit();
    const cube = try b.addCube(1, 1, 1, false);
    const ball = try b.addSphere(1, 8);
    const small = try b.addSquare(1, 1, true);
    const big = try b.addSquare(2, 2, true);
    const tri = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } };
    const moved_tri = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 2 } };
    const pts = [_][3]f64{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    const moved_pts = [_][3]f64{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 2 } };
    const faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 0, 3, 1 }, .{ 0, 2, 3 }, .{ 1, 3, 2 } };
    const contours = [_][]const [2]f64{ &tri, &tri };
    // One name, one id: a name doesn't make the same shape another node
    const bolt = try b.internPartName("bolt");
    const nut = try b.internPartName("nut");
    try std.testing.expectEqual(bolt, try b.internPartName("bolt"));
    const moved_contours = [_][]const [2]f64{ &tri, &moved_tri };
    const curve = bezier.Flattened{ .contour = 0, .first = 0, .count = 2, .cubic = .{ .c1 = .{ 0.3, 0.1 }, .c2 = .{ 0.6, 0.1 } } };
    const bent_curve = bezier.Flattened{ .contour = 0, .first = 0, .count = 2, .cubic = .{ .c1 = .{ 0.3, 0.2 }, .c2 = .{ 0.6, 0.1 } } };
    const other_run = bezier.Flattened{ .contour = 1, .first = 1, .count = 2, .cubic = .{ .c1 = .{ 0.3, 0.1 }, .c2 = .{ 0.6, 0.1 } } };
    const cases = [_]struct { layout: []const u8, first: dag.DAGNodeIndex, again: dag.DAGNodeIndex, changed: []const dag.DAGNodeIndex }{
        .{ .layout = "numbers", .first = try b.addCube(1, 2, 3, false), .again = try b.addCube(1, 2, 3, false), .changed = &.{ try b.addCube(1, 2, 4, false), try b.addCube(1, 2, 3, true) } },
        .{ .layout = "operands", .first = try b.addBinary(.difference_op, cube, ball), .again = try b.addBinary(.difference_op, cube, ball), .changed = &.{try b.addBinary(.difference_op, ball, cube)} },
        .{ .layout = "operand_list", .first = try b.addBatchUnion(&.{ cube, ball }), .again = try b.addBatchUnion(&.{ cube, ball }), .changed = &.{try b.addBatchUnion(&.{ cube, ball, cube })} },
        .{ .layout = "target_numbers", .first = try b.addTranslate(cube, 1, 2, 3), .again = try b.addTranslate(cube, 1, 2, 3), .changed = &.{ try b.addTranslate(ball, 1, 2, 3), try b.addTranslate(cube, 1, 2, 4), try b.addRotate(cube, 1, 2, 3) } },
        .{ .layout = "target_value", .first = try b.addSetMaterial(cube, 1), .again = try b.addSetMaterial(cube, 1), .changed = &.{try b.addSetMaterial(cube, 2)} },
        .{ .layout = "target_value (a name)", .first = try b.addSetName(cube, bolt), .again = try b.addSetName(cube, bolt), .changed = &.{ try b.addSetName(cube, nut), try b.addSetMaterial(cube, bolt) } },
        .{ .layout = "loft", .first = try b.addLoft(small, big, 3), .again = try b.addLoft(small, big, 3), .changed = &.{ try b.addLoft(small, big, 4), try b.addLoft(big, small, 3) } },
        .{ .layout = "polygon", .first = try b.addPolygon(@constCast(&tri)), .again = try b.addPolygon(@constCast(&tri)), .changed = &.{try b.addPolygon(@constCast(&moved_tri))} },
        .{ .layout = "polygons", .first = try b.addPolygonsEvenOdd(&contours, &.{}), .again = try b.addPolygonsEvenOdd(&contours, &.{}), .changed = &.{ try b.addPolygonsEvenOdd(&moved_contours, &.{}), try b.addPolygonsEvenOdd(contours[0..1], &.{}), try b.addPolygonsEvenOdd(&contours, &.{curve}) } },
        .{ .layout = "polygons (a curve)", .first = try b.addPolygonsEvenOdd(&contours, &.{curve}), .again = try b.addPolygonsEvenOdd(&contours, &.{curve}), .changed = &.{ try b.addPolygonsEvenOdd(&contours, &.{bent_curve}), try b.addPolygonsEvenOdd(&contours, &.{other_run}) } },
        .{ .layout = "polyhedron", .first = try b.addPolyhedron(&pts, &faces), .again = try b.addPolyhedron(&pts, &faces), .changed = &.{try b.addPolyhedron(&moved_pts, &faces)} },
        .{ .layout = "none", .first = try b.addEmpty(true), .again = try b.addEmpty(true), .changed = &.{try b.addEmpty(false)} },
    };
    for (cases) |case| {
        errdefer std.debug.print("layout: {s}\n", .{case.layout});
        try std.testing.expectEqual(case.first, case.again);
        for (case.changed) |changed| try std.testing.expect(changed != case.first and b.node_hashes.items[changed] != b.node_hashes.items[case.first]);
    }
    // Two leaves are two nodes, even of one mesh's copies.
    const mesh = kernel.cube(&.{}, 1, 1, 1, false) orelse return error.KernelFailed;
    const leaf = try b.addConcrete(mesh);
    const other = try b.addConcrete(kernel.clone(mesh) orelse return error.KernelFailed);
    try std.testing.expect(leaf != other and b.node_hashes.items[leaf] != b.node_hashes.items[other]);
}
