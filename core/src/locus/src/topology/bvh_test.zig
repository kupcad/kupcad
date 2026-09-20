const std = @import("std");
const types = @import("types.zig");
const topo_arena = @import("arena.zig");
const geom_arena = @import("../geometry/arena.zig");
const bvh = @import("bvh.zig");

test "BVH: Accelerates face collision query efficiently" {
    const alloc = std.testing.allocator;
    var t = topo_arena.TopologyArena.init();
    defer t.deinit(alloc);
    var g = geom_arena.GeometryArena.init();
    defer g.deinit(alloc);

    // Populate fake geometry point
    try g.points.append(alloc, .{ 0.0, 0.0, 0.0 });
    try t.vertices.append(alloc, .{ .point = @enumFromInt(0) });

    // Populate mock topological face
    try t.half_edges.append(alloc, .{
        .start_vertex = @enumFromInt(0),
        .twin = types.NULL_HALF_EDGE,
        .next = @enumFromInt(0),
        .prev = @enumFromInt(0),
        .loop_id = @enumFromInt(0),
        .curve = .{ .index = @enumFromInt(0), .curve_type = .line },
        .forward = true,
    });
    try t.loops.append(alloc, .{ .face_id = @enumFromInt(0), .first_half_edge = @enumFromInt(0) });
    try t.face_loops.append(alloc, @enumFromInt(0));
    try t.faces.append(alloc, .{
        .surface = .{ .index = @enumFromInt(0), .surface_type = .plane },
        .forward = true,
        .loops_start = 0,
        .loops_len = 1,
    });

    var tree = bvh.FlatBVH{};
    defer tree.deinit(alloc);

    const faces = [_]types.FaceIndex{@enumFromInt(0)};
    try tree.build(alloc, &t, &g, &faces);

    var queried = std.ArrayListUnmanaged(types.FaceIndex).empty;
    defer queried.deinit(alloc);

    try tree.queryBox(alloc, .{ -1.0, -1.0, -1.0 }, .{ 1.0, 1.0, 1.0 }, &queried);

    try std.testing.expectEqual(@as(usize, 1), queried.items.len);
    try std.testing.expectEqual(@as(types.FaceIndex, @enumFromInt(0)), queried.items[0]);
}
