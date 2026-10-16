const std = @import("std");
const testing = std.testing;
const dag = @import("dag.zig");
const verifier = @import("dag_verifier.zig");

/// A node of `tag` whose payload is `extra` appended to the builder's extra_data.
fn nodeWith(b: *dag.DAGBuilder, tag: dag.DAGTag, extra: []const u32) !dag.DAGNode {
    const at: u32 = @intCast(b.extra_data.items.len);
    try b.extra_data.appendSlice(testing.allocator, extra);
    return .{ .tag = tag, .data = at };
}

fn expectProblem(expected: []const u8, b: *const dag.DAGBuilder, node: dag.DAGNode) !void {
    try testing.expectEqualStrings(expected, verifier.problem(b, node) orelse "sound");
}

test "DAG verifier: what every builder makes is sound" {
    var b = dag.DAGBuilder.init(testing.allocator);
    defer b.deinit();
    // The builder checks each node as it adds it (in tests), so this one script of every
    // shape is the check: a malformed node would have stopped it.
    const cube = try b.addCube(1, 2, 3, false);
    const sq = try b.addSquare(1, 1, true);
    const circ = try b.addCircle(1, 16);
    const poly = try b.addPolygon(@constCast(&[_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } }));
    const ext = try b.addExtrude(sq, 2, 1, 0, 1, 1);
    _ = try b.addRevolve(try b.addCrossSectionTransform(circ, .{ 1, 0, 0, 1, 5, 0 }), 16, 360);
    _ = try b.addLoft(sq, poly, 3);
    _ = try b.addOffset(sq, 0.5, 0);
    _ = try b.addBinary(.cs_union_op, sq, circ);
    _ = try b.addSlice(try b.addBinary(.union_op, cube, ext), 0.5);
    _ = try b.addProject(cube);
    _ = try b.addBatchUnion(&.{ cube, ext });
    _ = try b.addBatchHull(&.{ cube, ext });
    _ = try b.addTrimByPlane(try b.addHull(cube), 0, 0, 1, 0);
    _ = try b.addTransformMatrix(try b.addMirror(cube, 1, 0, 0), .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 });
    _ = try b.addPolyhedron(&.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } }, &.{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 0, 3, 2 }, .{ 1, 2, 3 } });
    _ = try b.addPolygonsEvenOdd(&.{ &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 0, 4 } }, &.{ .{ 1, 1 }, .{ 2, 1 }, .{ 1, 2 } } });
    _ = try b.addSetMaterial(cube, 1);
    _ = try b.addEmpty(true);
}

test "DAG verifier: names what is wrong with a malformed node" {
    var b = dag.DAGBuilder.init(testing.allocator);
    defer b.deinit();
    const cube = try b.addCube(1, 1, 1, false);
    const sq = try b.addSquare(1, 1, false);
    const nums: u32 = @intCast(b.numbers.items.len);
    try b.numbers.appendSlice(testing.allocator, &.{ 1, 1, 1 });

    try expectProblem("an operand is a solid where a sketch belongs", &b, try nodeWith(&b, .extrude, &.{ cube, nums }));
    try expectProblem("an operand is a sketch where a solid belongs", &b, try nodeWith(&b, .translate, &.{ sq, nums }));
    try expectProblem("an operand is a sketch where a solid belongs", &b, try nodeWith(&b, .union_op, &.{ cube, sq }));
    try expectProblem("an operand isn't a node built before it", &b, try nodeWith(&b, .hull, &.{99}));
    try expectProblem("it has no operands", &b, try nodeWith(&b, .batch_union_op, &.{0}));
    try expectProblem("its numbers are outside the numbers table", &b, try nodeWith(&b, .translate, &.{ cube, 1000 }));
    try expectProblem("its operands are outside extra_data", &b, .{ .tag = .difference_op, .data = @intCast(b.extra_data.items.len) });
    try expectProblem("it names no concrete handle", &b, .{ .tag = .concrete, .data = 0 });
    try expectProblem("its settings id names no settings", &b, .{ .tag = .empty_solid, .settings = 7 });

    // A NaN in the numbers: the evaluator skips checking a moved solid on the promise
    // that no transform carries one.
    const nan_at: u32 = @intCast(b.numbers.items.len);
    try b.numbers.appendSlice(testing.allocator, &.{ std.math.nan(f64), 0, 0 });
    try expectProblem("a number in it is NaN or infinite", &b, try nodeWith(&b, .translate, &.{ cube, nan_at }));

    // A polyhedron whose face names a fourth point of three.
    const pts_at: u32 = @intCast(b.poly_points.items.len);
    try b.poly_points.appendSlice(testing.allocator, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } });
    const faces_at: u32 = @intCast(b.poly_faces.items.len);
    try b.poly_faces.append(testing.allocator, .{ 0, 1, 3 });
    try expectProblem("a face names a point it doesn't have", &b, try nodeWith(&b, .polyhedron_op, &.{ pts_at, 3, faces_at, 1, 0, 0 }));
}

test "DAG verifier: every tag is a solid or a sketch, as the evaluator reads it" {
    try testing.expectEqual(verifier.Kind.sketch, verifier.kindOf(.slice_op));
    try testing.expectEqual(verifier.Kind.solid, verifier.kindOf(.extrude));
    try testing.expectEqual(verifier.Kind.solid, verifier.kindOf(.concrete));
    try testing.expectEqual(verifier.Kind.sketch, verifier.kindOf(.cs_transform));
}
