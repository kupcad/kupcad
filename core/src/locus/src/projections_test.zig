const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const gen = @import("generators.zig");
const proj = @import("projections.zig");
const prop = @import("properties.zig");

test "Projections: 3D Solid Silhouette to 2D Cross Section" {
    const alloc = std.testing.allocator;
    var in_t = topo.TopologyArena.init(alloc);
    defer in_t.deinit(alloc);
    var in_g = geom.GeometryArena.init(alloc);
    defer in_g.deinit(alloc);

    var out_t = topo.TopologyArena.init(alloc);
    defer out_t.deinit(alloc);
    var out_g = geom.GeometryArena.init(alloc);
    defer out_g.deinit(alloc);

    const cube_id = try gen.generateCube(alloc, &in_t, &in_g, 10.0, 10.0, 10.0, true);

    const cs_id_opt = try proj.projectSolid(alloc, &out_t, &out_g, &in_t, &in_g, cube_id);
    try std.testing.expect(cs_id_opt != null);
    const cs_id = cs_id_opt.?;

    // 10x10 cube projected onto 2D plane must yield a 10x10 square footprint (Area = 100)
    const area = prop.crossSectionArea(&out_t, cs_id);
    try std.testing.expectApproxEqAbs(100.0, area, 1e-4);
}
