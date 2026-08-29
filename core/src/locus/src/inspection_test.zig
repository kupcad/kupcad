const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const gen = @import("generators.zig");
const insp = @import("inspection.zig");

test "Inspection: Query Faces Direction and Centroid Alignment" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Centered 10x10x10 cube (bounds span [-5, 5])
    const cube_id = try gen.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    // Query face facing strictly +Z
    const faces_opt = try insp.queryFaces(alloc, &t_arena, &g_arena, cube_id, .{ 0.0, 0.0, 1.0 }, 1e-4);
    try std.testing.expect(faces_opt != null);
    const faces = faces_opt.?;
    defer alloc.free(faces);

    try std.testing.expectEqual(@as(usize, 1), faces.len);
    try std.testing.expectApproxEqAbs(0.0, faces[0].centroid[0], 1e-5);
    try std.testing.expectApproxEqAbs(0.0, faces[0].centroid[1], 1e-5);
    try std.testing.expectApproxEqAbs(5.0, faces[0].centroid[2], 1e-5); // Top plane is at Z = +5
    try std.testing.expectApproxEqAbs(1.0, faces[0].normal[2], 1e-5);
}
