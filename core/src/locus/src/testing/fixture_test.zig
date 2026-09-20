const std = @import("std");
const testing = std.testing;
const math_env = @import("../math_env.zig");
const topo_arena = @import("../topology/arena.zig");
const geom_arena = @import("../geometry/arena.zig");
const generators = @import("../operations/generators.zig");
const verifier = @import("../topology/verifier.zig").Verifier;
const fixture_mod = @import("fixture.zig");

test "Fixture Suite: Cube 10x10 Roundtrip Serialization & Verification" {
    const alloc = testing.allocator;
    const env = math_env.MathEnv{};

    // 1. Generate standard live Cube
    var src_t = topo_arena.TopologyArena.init();
    defer src_t.deinit(alloc);
    var src_g = geom_arena.GeometryArena.init();
    defer src_g.deinit(alloc);

    const cube_solid = try generators.generateCube(alloc, &src_t, &src_g, 10.0, 10.0, 10.0, true);

    // Verify initial generator output
    try verifier.validateSolid(alloc, &src_t, &src_g, env, cube_solid, .{});

    // 2. Serialize live arenas to JSON string
    const json_output = try fixture_mod.Fixture.dump(alloc, &src_t, &src_g, cube_solid, env);
    defer alloc.free(json_output);

    // Ensure valid JSON payload generated
    try testing.expect(json_output.len > 0);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"target_solid\": 0") != null);

    // 3. Deserialize into fresh, isolated arenas
    var dst_t = topo_arena.TopologyArena.init();
    defer dst_t.deinit(alloc);
    var dst_g = geom_arena.GeometryArena.init();
    defer dst_g.deinit(alloc);

    const loaded = try fixture_mod.Fixture.load(alloc, json_output, &dst_t, &dst_g);

    // 4. Validate deserialized B-Rep solid against topological invariants
    try verifier.validateSolid(alloc, &dst_t, &dst_g, loaded.env, loaded.solid_idx, .{});

    // 5. Parity Assertions between source and deserialized state
    try testing.expectEqual(src_t.vertices.items.len, dst_t.vertices.items.len);
    try testing.expectEqual(src_t.half_edges.items.len, dst_t.half_edges.items.len);
    try testing.expectEqual(src_t.faces.items.len, dst_t.faces.items.len);
    try testing.expectEqual(src_g.points.items.len, dst_g.points.items.len);

    // Verify coordinates match within tolerance
    for (src_g.points.items, dst_g.points.items) |p_src, p_dst| {
        try testing.expect(env.isCoincident(p_src, p_dst));
    }
}
