const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const geom_arena = @import("../geometry/arena.zig");
const generators = @import("generators.zig");
const verifier = @import("../topology/verifier.zig").Verifier;

test "Generator: Cube Strict Topology Validation" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const cube_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    verifier.assertValidTestOnly(alloc, &t_arena, &g_arena, .{}, cube_idx);
}
