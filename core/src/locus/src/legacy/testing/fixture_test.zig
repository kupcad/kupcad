const std = @import("std");
const testing = std.testing;
const topo_arena = @import("../topology/arena.zig");
const geom_arena = @import("../geometry/arena.zig");
const math_env = @import("../math_env.zig");
const generators = @import("../operations/generators.zig");
const verifier = @import("../topology/verifier.zig");
const fixture_mod = @import("fixture.zig");

/// The snapshot `name` of the primitives (../fixtures/primitives), embedded: read by a path,
/// it was another file wherever the tests ran, and no file at all under WebAssembly.
fn snapshot(comptime name: []const u8) []const u8 {
    return @embedFile("../fixtures/primitives/" ++ name);
}

// ============================================================================
// 3D Solid Snapshot Fixtures
// ============================================================================

test "Snapshot Suite: Cube 10x10x10" {
    const alloc = testing.allocator;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{});

    try fixture_mod.Fixture.matchSnapshot(alloc, "cube.json", snapshot("cube.json"), &t_arena, &g_arena, solid, env);
}

test "Snapshot Suite: Cylinder" {
    const alloc = testing.allocator;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid = try generators.generateCylinder(alloc, &t_arena, &g_arena, 5.0, 20.0, true);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{});

    try fixture_mod.Fixture.matchSnapshot(alloc, "cylinder.json", snapshot("cylinder.json"), &t_arena, &g_arena, solid, env);
}

test "Snapshot Suite: Sphere" {
    const alloc = testing.allocator;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid = try generators.generateSphere(alloc, &t_arena, &g_arena, 10.0);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{});

    try fixture_mod.Fixture.matchSnapshot(alloc, "sphere.json", snapshot("sphere.json"), &t_arena, &g_arena, solid, env);
}

// ============================================================================
// 2D Cross-Section Snapshot Fixtures
// ============================================================================

test "Snapshot Suite: Square (2D)" {
    const alloc = testing.allocator;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid = try generators.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, true);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{ .require_closed_shells = false, .check_twins = false });

    try fixture_mod.Fixture.matchSnapshot(alloc, "square.json", snapshot("square.json"), &t_arena, &g_arena, solid, env);
}

test "Snapshot Suite: Circle (2D)" {
    const alloc = testing.allocator;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid = try generators.generateCircle(alloc, &t_arena, &g_arena, 5.0, 12);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{ .require_closed_shells = false, .check_twins = false });

    try fixture_mod.Fixture.matchSnapshot(alloc, "circle.json", snapshot("circle.json"), &t_arena, &g_arena, solid, env);
}

test "Snapshot Suite: Polygon (2D)" {
    const alloc = testing.allocator;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const pts = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 5, 10 } };
    const solid = try generators.generatePolygon(alloc, &t_arena, &g_arena, &pts);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{ .require_closed_shells = false, .check_twins = false });

    try fixture_mod.Fixture.matchSnapshot(alloc, "polygon.json", snapshot("polygon.json"), &t_arena, &g_arena, solid, env);
}

test "Snapshot Suite: PolygonsEvenOdd (2D)" {
    const alloc = testing.allocator;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const hole = [_][2]f64{ .{ -5, -5 }, .{ 5, -5 }, .{ 5, 5 }, .{ -5, 5 } };

    var polys: std.ArrayList([]const [2]f64) = .empty;
    defer polys.deinit(alloc);

    try polys.append(alloc, &outer);
    try polys.append(alloc, &hole);

    const solid = try generators.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, polys.items);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{ .require_closed_shells = false, .check_twins = false });

    try fixture_mod.Fixture.matchSnapshot(alloc, "poly_even_odd.json", snapshot("poly_even_odd.json"), &t_arena, &g_arena, solid, env);
}
