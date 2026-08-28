const std = @import("std");
const testing = std.testing;
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");
const slicing = @import("slicing.zig");
const tessellate = @import("tessellate.zig");

test "Slicing: trimByPlane cuts solid in half along plane with dynamic bounds" {
    const alloc = testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    const sliced_id = try slicing.trimByPlane(alloc, &t_arena, &g_arena, cube_id, 0, 0, 1, 0.0);

    const bbox = slicing.getSolidBBox(&t_arena, sliced_id);

    // Verify Bounding Box dynamically scaled and successfully intersected
    try testing.expect(bbox.min[0] <= -5.0);
    try testing.expect(bbox.max[0] >= 5.0);
    try testing.expect(bbox.min[1] <= -5.0);
    try testing.expect(bbox.max[1] >= 5.0);
    try testing.expect(bbox.min[2] <= -5.0);
    try testing.expectApproxEqAbs(0.0, bbox.max[2], 1e-5); // Trim plane constraint remains absolute
}

test "Slicing: sliceMeshToContours produces closed 2D loops" {
    const alloc = testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cyl_id = try generators.generateCylinder(alloc, &t_arena, &g_arena, 5.0, 20.0, true);
    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, cyl_id, &mesh, .{});

    const contours = try slicing.sliceMeshToContours(alloc, &mesh, 0.0);
    defer {
        for (contours) |c| alloc.free(c);
        alloc.free(contours);
    }

    try testing.expect(contours.len > 0);
    try testing.expect(contours[0].len >= 3);
}
