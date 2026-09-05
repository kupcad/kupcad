const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const gen = @import("generators.zig");
const booleans = @import("booleans.zig");
const transforms = @import("transforms.zig");
const prop = @import("properties.zig");
const tessellate = @import("tessellate.zig");
const validator = @import("validator.zig");

const test_tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

test "Stress: Chained CSG Booleans (10 Sequential Subtractions)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Base block: 100x100x10 cube (Vol = 100,000)
    var current_solid = try gen.generateCube(alloc, &t_arena, &g_arena, 100.0, 100.0, 10.0, true);

    // Sequentially carve 10 5x5 through-slots spaced 8 units apart
    var x_offset: f64 = -36.0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const cutter = try gen.generateCube(alloc, &t_arena, &g_arena, 5.0, 80.0, 20.0, true);
        _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cutter, x_offset, 0.0, 0.0);

        current_solid = try booleans.computeBoolean(
            alloc,
            &t_arena,
            &g_arena,
            current_solid,
            cutter,
            .difference,
        );
        x_offset += 8.0;
    }

    // 1. Manifold Validation
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, current_solid, test_tol, .{
        .check_twins = true,
        .require_closed_shells = true,
    });

    // 2. Volume Check: 100,000 - 10*(5 * 80 * 10) = 100,000 - 40,000 = 60,000
    const vol = prop.volume(alloc, &t_arena, &g_arena, current_solid);
    try std.testing.expectApproxEqAbs(60000.0, vol, 1e-3);

    // 3. Genus Check: 10 independent through-holes -> Genus = 10
    const g = prop.genus(alloc, &t_arena, current_solid);
    try std.testing.expectEqual(@as(i32, 10), g);
}

test "Stress: High-Genus Perforated Plate Grid (3x3 Matrix)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Plate: 30x30x4 (Vol = 3,600)
    var plate = try gen.generateCube(alloc, &t_arena, &g_arena, 30.0, 30.0, 4.0, true);

    // Carve a 3x3 matrix of 4x4 square holes (9 holes total)
    const positions = [_][2]f64{
        .{ -8.0, -8.0 }, .{ 0.0, -8.0 }, .{ 8.0, -8.0 },
        .{ -8.0, 0.0 },  .{ 0.0, 0.0 },  .{ 8.0, 0.0 },
        .{ -8.0, 8.0 },  .{ 0.0, 8.0 },  .{ 8.0, 8.0 },
    };

    for (positions) |pos| {
        const hole = try gen.generateCube(alloc, &t_arena, &g_arena, 4.0, 4.0, 10.0, true);
        _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, hole, pos[0], pos[1], 0.0);
        plate = try booleans.computeBoolean(
            alloc,
            &t_arena,
            &g_arena,
            plate,
            hole,
            .difference,
        );
    }

    // Volume Check: 3,600 - 9*(4 * 4 * 4) = 3,600 - 576 = 3,024
    const vol = prop.volume(alloc, &t_arena, &g_arena, plate);
    try std.testing.expectApproxEqAbs(3024.0, vol, 1e-3);

    // Genus Check: 9 through-holes -> Genus = 9
    const g = prop.genus(alloc, &t_arena, plate);
    try std.testing.expectEqual(@as(i32, 9), g);
}

test "Stress: Non-Uniform Scaling & Oblique CSG Cutting" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Base Cube: 10x10x10 centered at origin (Vol = 1,000)
    const cube = try gen.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    // Anisotropic scale: X*2.0, Y*0.5, Z*3.0 -> Dimensions: 20x5x30 (Vol = 3,000)
    _ = try transforms.scaleSolid(alloc, &t_arena, &g_arena, cube, 2.0, 0.5, 3.0);

    // Subtraction cutter: 10x10x40 translated to cut a corner
    const cutter = try gen.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 40.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cutter, 10.0, 0.0, 0.0);

    const result = try booleans.computeBoolean(
        alloc,
        &t_arena,
        &g_arena,
        cube,
        cutter,
        .difference,
    );

    // Subtracted volume is 5 (overlapping X) * 5 (full Y) * 30 (full Z) = 750
    // Expected Net Volume = 3,000 - 750 = 2,250
    const vol = prop.volume(alloc, &t_arena, &g_arena, result);
    try std.testing.expectApproxEqAbs(2250.0, vol, 1e-3);
}

test "Stress: Concentric Hollow Shell Void (Internal Cavity)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Outer Cube: 20x20x20 centered (Vol = 8,000)
    const outer = try gen.generateCube(alloc, &t_arena, &g_arena, 20.0, 20.0, 20.0, true);

    // Inner Cube: 10x10x10 centered (Vol = 1,000)
    const inner = try gen.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    // Subtracting an enclosed inner cube forms an internal void shell (2 total shells)
    const hollow_box = try booleans.computeBoolean(
        alloc,
        &t_arena,
        &g_arena,
        outer,
        inner,
        .difference,
    );

    // Net Volume = 8,000 - 1,000 = 7,000
    const vol = prop.volume(alloc, &t_arena, &g_arena, hollow_box);
    try std.testing.expectApproxEqAbs(7000.0, vol, 1e-3);

    // Surface area = Outer (6 * 400) + Inner (6 * 100) = 2,400 + 600 = 3,000
    const sa = prop.surfaceArea(alloc, &t_arena, &g_arena, hollow_box);
    try std.testing.expectApproxEqAbs(3000.0, sa, 1e-3);
}
