const std = @import("std");
const testing = std.testing;
const topo_arena = @import("../topology/arena.zig");
const geom_arena = @import("../geometry/arena.zig");
const math_env = @import("../math_env.zig");
const generators = @import("../operations/generators.zig");
const verifier = @import("../topology/verifier.zig");
const fixture_mod = @import("fixture.zig");

fn getFixturePath(alloc: std.mem.Allocator, filename: []const u8) ![]u8 {
    const locus_src_dir = comptime blk: {
        const file_path = @src().file;
        const test_dir = std.fs.path.dirname(file_path) orelse ".";
        const src_dir = std.fs.path.dirname(test_dir) orelse ".";

        // When Zig compiles a module defined at src/locus/src/root.zig,
        // @src().file strips 'src/'. We restore it so path.join resolves
        // relative to the repository root (core/).
        if (std.mem.startsWith(u8, src_dir, "locus")) {
            break :blk "src/" ++ src_dir;
        }
        break :blk src_dir;
    };

    return std.fs.path.join(alloc, &[_][]const u8{ locus_src_dir, "fixtures", "primitives", filename });
}

// ============================================================================
// 3D Solid Snapshot Fixtures
// ============================================================================

test "Snapshot Suite: Cube 10x10x10" {
    const alloc = testing.allocator;
    const io = testing.io;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{});

    const file_path = try getFixturePath(alloc, "cube.json");
    defer alloc.free(file_path);

    try fixture_mod.Fixture.matchSnapshot(alloc, io, file_path, &t_arena, &g_arena, solid, env);
}

test "Snapshot Suite: Cylinder" {
    const alloc = testing.allocator;
    const io = testing.io;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid = try generators.generateCylinder(alloc, &t_arena, &g_arena, 5.0, 20.0, true);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{});

    const file_path = try getFixturePath(alloc, "cylinder.json");
    defer alloc.free(file_path);

    try fixture_mod.Fixture.matchSnapshot(alloc, io, file_path, &t_arena, &g_arena, solid, env);
}

test "Snapshot Suite: Sphere" {
    const alloc = testing.allocator;
    const io = testing.io;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid = try generators.generateSphere(alloc, &t_arena, &g_arena, 10.0);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{});

    const file_path = try getFixturePath(alloc, "sphere.json");
    defer alloc.free(file_path);

    try fixture_mod.Fixture.matchSnapshot(alloc, io, file_path, &t_arena, &g_arena, solid, env);
}

// ============================================================================
// 2D Cross-Section Snapshot Fixtures
// ============================================================================

test "Snapshot Suite: Square (2D)" {
    const alloc = testing.allocator;
    const io = testing.io;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid = try generators.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, true);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{ .require_closed_shells = false, .check_twins = false });

    const file_path = try getFixturePath(alloc, "square.json");
    defer alloc.free(file_path);

    try fixture_mod.Fixture.matchSnapshot(alloc, io, file_path, &t_arena, &g_arena, solid, env);
}

test "Snapshot Suite: Circle (2D)" {
    const alloc = testing.allocator;
    const io = testing.io;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid = try generators.generateCircle(alloc, &t_arena, &g_arena, 5.0, 12);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{ .require_closed_shells = false, .check_twins = false });

    const file_path = try getFixturePath(alloc, "circle.json");
    defer alloc.free(file_path);

    try fixture_mod.Fixture.matchSnapshot(alloc, io, file_path, &t_arena, &g_arena, solid, env);
}

test "Snapshot Suite: Polygon (2D)" {
    const alloc = testing.allocator;
    const io = testing.io;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const pts = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 5, 10 } };
    const solid = try generators.generatePolygon(alloc, &t_arena, &g_arena, &pts);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{ .require_closed_shells = false, .check_twins = false });

    const file_path = try getFixturePath(alloc, "polygon.json");
    defer alloc.free(file_path);

    try fixture_mod.Fixture.matchSnapshot(alloc, io, file_path, &t_arena, &g_arena, solid, env);
}

test "Snapshot Suite: PolygonsEvenOdd (2D)" {
    const alloc = testing.allocator;
    const io = testing.io;
    const env = math_env.MathEnv{};

    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const hole = [_][2]f64{ .{ -5, -5 }, .{ 5, -5 }, .{ 5, 5 }, .{ -5, 5 } };

    var polys: std.ArrayListUnmanaged([]const [2]f64) = .empty;
    defer polys.deinit(alloc);

    try polys.append(alloc, &outer);
    try polys.append(alloc, &hole);

    const solid = try generators.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, polys.items);
    try verifier.validateSolid(alloc, &t_arena, &g_arena, env, solid, .{ .require_closed_shells = false, .check_twins = false });

    const file_path = try getFixturePath(alloc, "poly_even_odd.json");
    defer alloc.free(file_path);

    try fixture_mod.Fixture.matchSnapshot(alloc, io, file_path, &t_arena, &g_arena, solid, env);
}
