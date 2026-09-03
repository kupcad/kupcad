const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const gen = @import("generators.zig");
const tessellate = @import("tessellate.zig");

// Helper to calculate the 3D surface area of the generated mesh
fn calculateMeshArea(mesh: *const tessellate.Mesh) f64 {
    var total_area: f64 = 0.0;
    for (mesh.triangles.items) |tri| {
        const p0 = mesh.vertices.items[tri[0]];
        const p1 = mesh.vertices.items[tri[1]];
        const p2 = mesh.vertices.items[tri[2]];

        const v1x = p1[0] - p0[0];
        const v1y = p1[1] - p0[1];
        const v1z = p1[2] - p0[2];

        const v2x = p2[0] - p0[0];
        const v2y = p2[1] - p0[1];
        const v2z = p2[2] - p0[2];

        const cx = v1y * v2z - v1z * v2y;
        const cy = v1z * v2x - v1x * v2z;
        const cz = v1x * v2y - v1y * v2x;

        total_area += 0.5 * @sqrt(cx * cx + cy * cy + cz * cz);
    }
    return total_area;
}

test "Tessellate: Delaunay Triangulator (Simple Convex Polygon)" {
    const alloc = std.testing.allocator;
    var poly = std.ArrayListUnmanaged(math.Vec2).empty;
    defer poly.deinit(alloc);
    try poly.appendSlice(alloc, &[_]math.Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } });

    var tris: std.ArrayListUnmanaged([3]u32) = .empty;
    defer tris.deinit(alloc);

    try tessellate.delaunayTriangulate(alloc, &poly, &tris);

    // Remove super triangle manually for the test evaluation
    var count: usize = 0;
    for (tris.items) |tri| {
        if (tri[0] < 4 and tri[1] < 4 and tri[2] < 4) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Tessellate: Concave Polygon (L-Shape)" {
    // Tests if the winding filter correctly culls ghost triangles in the concave "armpit"
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const l_shape = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 5 }, .{ 5, 5 }, .{ 5, 10 }, .{ 0, 10 } };
    const contours = [_][]const [2]f64{&l_shape};
    const cs_id = try gen.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, &contours);

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, cs_id, &mesh, .{});

    // Area = (10 * 5) + (5 * 5) = 75
    try std.testing.expectApproxEqAbs(75.0, calculateMeshArea(&mesh), 1e-4);
}

test "Tessellate: Collinear Boundary Vertices" {
    // Tests if Bowyer-Watson and Jitter gracefully handle vertices that lie perfectly flat along an edge.
    // CSG booleans frequently slice edges, creating collinear vertices.
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const collinear_poly = [_][2]f64{
        .{ 0, 0 }, .{ 5, 0 }, .{ 10, 0 }, // Collinear bottom edge
        .{ 10, 10 }, .{ 5, 10 }, .{ 0, 10 }, // Collinear top edge
    };
    const contours = [_][]const [2]f64{&collinear_poly};
    const cs_id = try gen.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, &contours);

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, cs_id, &mesh, .{});

    // Outer bounding box is 10x10. Area = 100.
    try std.testing.expectApproxEqAbs(100.0, calculateMeshArea(&mesh), 1e-4);
}

test "Tessellate: Single Hole Constraints" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    const contours = [_][]const [2]f64{ &outer, &inner };

    const cs_id = try gen.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, &contours);

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, cs_id, &mesh, .{});

    // 400 - 100 = 300
    try std.testing.expectApproxEqAbs(300.0, calculateMeshArea(&mesh), 1e-4);
}

test "Tessellate: Multiple Holes" {
    // Tests if the edge recovery and winding rule scale to multiple isolated internal constraints
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const outer = [_][2]f64{ .{ 0, 0 }, .{ 30, 0 }, .{ 30, 20 }, .{ 0, 20 } };
    const hole1 = [_][2]f64{ .{ 5, 5 }, .{ 5, 15 }, .{ 10, 15 }, .{ 10, 5 } };
    const hole2 = [_][2]f64{ .{ 20, 5 }, .{ 20, 15 }, .{ 25, 15 }, .{ 25, 5 } };

    const contours = [_][]const [2]f64{ &outer, &hole1, &hole2 };

    const cs_id = try gen.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, &contours);

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, cs_id, &mesh, .{});

    // Outer area = 600. Hole 1 = 50. Hole 2 = 50. Net = 500.
    try std.testing.expectApproxEqAbs(500.0, calculateMeshArea(&mesh), 1e-4);
}

test "Tessellate: Deduplication of Coincident Vertices (Seam Simulation)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Provide a square where the middle two vertices are perfectly identical
    // to simulate a split edge from a coplanar boolean union
    const defect_poly = [_][2]f64{
        .{ 0, 0 },   .{ 5, 0 },  .{ 5, 0 }, .{ 10, 0 }, // Bottom edge with duplicate
        .{ 10, 10 }, .{ 0, 10 },
    };
    const contours = [_][]const [2]f64{&defect_poly};
    const cs_id = try gen.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, &contours);

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, cs_id, &mesh, .{});

    // Outer bounding box is 10x10. Deduplication must merge (5,0) and successfully mesh.
    try std.testing.expectApproxEqAbs(100.0, calculateMeshArea(&mesh), 1e-4);
}

test "Tessellate: Degenerate Zero-Area Hole Constraints" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    // A completely flat, degenerate zero-area line as a hole
    const inner = [_][2]f64{ .{ -2, 0 }, .{ 2, 0 }, .{ 2, 0 }, .{ -2, 0 } };
    const contours = [_][]const [2]f64{ &outer, &inner };

    const cs_id = try gen.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, &contours);

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, cs_id, &mesh, .{});

    // 400 - 0 = 400
    try std.testing.expectApproxEqAbs(400.0, calculateMeshArea(&mesh), 1e-4);
}

test "Tessellate: Negative Coordinate Parity (Double Inversion Check)" {
    // Validates that the projection parity (area2d < 0.0) correctly handles
    // faces that exist entirely in negative space without accidentally flipping normals.
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 10x10x10 cube, Z: [-10, 0]
    const cube = try gen.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, false);

    // Shift the cube deep into negative coordinates
    const transforms = @import("transforms.zig");
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube, -500.0, -500.0, -500.0);

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, cube, &mesh, .{});

    // Surface area of a 10x10x10 cube is always 600, regardless of position or coordinate signs
    try std.testing.expectApproxEqAbs(600.0, calculateMeshArea(&mesh), 1e-4);
}

test "Tessellate: Complex Star-Shaped Hole" {
    // Tests boundary recovery against a highly non-convex hole where Delaunay diagonals
    // will severely intersect the physical boundary constraints.
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const outer = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 20 }, .{ 0, 20 } }; // Area: 400

    // 4-pointed star hole
    const star = [_][2]f64{
        .{ 10, 5 }, // Bottom point
        .{ 12, 9 }, // Inner bottom-right
        .{ 16, 10 }, // Right point
        .{ 12, 11 }, // Inner top-right
        .{ 10, 15 }, // Top point
        .{ 8, 11 }, // Inner top-left
        .{ 4, 10 }, // Left point
        .{ 8, 9 }, // Inner bottom-left
    };
    // Star Area can be calculated via Shoelace:
    // (10*9 - 5*12) + (12*10 - 9*16) + (16*11 - 10*12) + (12*15 - 11*10) + (10*11 - 15*8) + (8*10 - 11*4) + (4*9 - 10*8) + (8*5 - 9*10)
    // 30 - 24 + 56 + 70 - 10 + 36 - 44 - 50 = 64 / 2 = 32

    const contours = [_][]const [2]f64{ &outer, &star };
    const cs_id = try gen.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, &contours);

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, cs_id, &mesh, .{});

    // Outer (400) - Star (32) = 368
    try std.testing.expectApproxEqAbs(368.0, calculateMeshArea(&mesh), 1e-4);
}

test "Tessellate: Micro-Slit Hole (Precision Stress Test)" {
    // Tests if the eigen determinants and boundary recovery can handle near-zero area holes
    // without stalling the optimization loops.
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const outer = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } }; // Area: 100

    // A slit that is 8 units wide but only 0.001 units tall
    const slit = [_][2]f64{ .{ 1, 5 }, .{ 9, 5 }, .{ 9, 5.001 }, .{ 1, 5.001 } }; // Area: 0.008

    const contours = [_][]const [2]f64{ &outer, &slit };
    const cs_id = try gen.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, &contours);

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, cs_id, &mesh, .{});

    // Outer (100) - Slit (0.008) = 99.992
    try std.testing.expectApproxEqAbs(99.992, calculateMeshArea(&mesh), 1e-4);
}
