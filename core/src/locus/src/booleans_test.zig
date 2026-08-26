const std = @import("std");
const topo = @import("topology.zig");
const generators = @import("generators.zig");
const geom = @import("geometry.zig");
const booleans = @import("booleans.zig");
const math = @import("math.zig");
const transforms = @import("transforms.zig");

test "March Intersection (Perpendicular Cylinders)" {
    const alloc = std.testing.allocator;
    const cyl_a = geom.Cylinder{
        .origin = .{ 0, 0, 0 },
        .axis = .{ 0, 0, 1 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 1, 0 },
        .radius = 5.0,
    };

    const cyl_b = geom.Cylinder{
        .origin = .{ 0, 0, 0 },
        .axis = .{ 0, 1, 0 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 0, 1 },
        .radius = 5.0,
    };

    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try g_arena.cylinders.append(alloc, cyl_a);
    try g_arena.cylinders.append(alloc, cyl_b);

    const start_pt = math.Vec3{ 5.0, 0.0, 0.0 };

    const id_a = geom.SurfaceId{ .index = 0, .surface_type = .cylinder };
    const id_b = geom.SurfaceId{ .index = 1, .surface_type = .cylinder };

    const curve_id = try booleans.marchIntersection(alloc, &g_arena, id_a, id_b, start_pt, 0.5, 10, 1e-5);
    try std.testing.expectEqual(@as(u32, 0), curve_id.index);
}

test "CSG Pipeline: High-Level Operations (Stubbed)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube1 = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    const cube2 = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube2, 20, 0, 0);

    const union_result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube1, cube2, .union_op, .{});

    const union_shell = t_arena.shells.items[t_arena.solid_shells.items[t_arena.solids.items[union_result].shells_start]];
    try std.testing.expectEqual(@as(usize, 12), union_shell.faces_len);
}

test "CSG: Half-Edge Splitting" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const v0: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 0, 0 } });

    const v1: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.append(alloc, .{ .point = .{ 10, 0, 0 } });
    _ = v1; // Marking unused explicitly since we test the graph rather than v1 directly.

    const l_idx: u24 = @intCast(g_arena.lines.items.len);
    try g_arena.lines.append(alloc, .{ .start = .{ 0, 0, 0 }, .end = .{ 10, 0, 0 } });

    const loop_id: u32 = 0;
    const he_id: u32 = @intCast(t_arena.half_edges.items.len);
    try t_arena.half_edges.append(alloc, .{
        .start_vertex = v0,
        .twin = topo.NULL_ID,
        .next = he_id,
        .prev = he_id,
        .loop_id = loop_id,
        .curve = .{ .index = l_idx, .curve_type = .line },
        .forward = true,
    });

    const split_pt = math.Vec3{ 5, 0, 0 };
    const result = try booleans.splitHalfEdge(alloc, &t_arena, &g_arena, he_id, split_pt);

    try std.testing.expectEqual(@as(usize, 3), t_arena.vertices.items.len);
    try std.testing.expectEqual(v0, t_arena.half_edges.items[he_id].start_vertex);
    try std.testing.expectEqual(result.v_mid, t_arena.half_edges.items[result.he_new].start_vertex);
}

test "CSG: Point-in-Solid Raycaster" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    const pt_inside = math.Vec3{ 0.0, 0.0, 0.0 };
    const is_in = booleans.isPointInsideSolid(&t_arena, &g_arena, cube_id, pt_inside);
    try std.testing.expectEqual(true, is_in);

    const pt_outside = math.Vec3{ 20.0, 20.0, 20.0 };
    const is_out = booleans.isPointInsideSolid(&t_arena, &g_arena, cube_id, pt_outside);
    try std.testing.expectEqual(false, is_out);
}

test "CSG: 2D Point-in-Polygon Algorithm" {
    const polygon = [_][2]f64{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 5.0, 5.0 },
        .{ 10.0, 10.0 },
        .{ 0.0, 10.0 },
    };

    try std.testing.expectEqual(true, booleans.isPointInPolygon2D(.{ 2.0, 8.0 }, &polygon));
    try std.testing.expectEqual(true, booleans.isPointInPolygon2D(.{ 2.0, 2.0 }, &polygon));
    try std.testing.expectEqual(false, booleans.isPointInPolygon2D(.{ 7.0, 5.0 }, &polygon));
    try std.testing.expectEqual(false, booleans.isPointInPolygon2D(.{ 15.0, 5.0 }, &polygon));
}

test "Curve Math: Arc vs Plane Intersection" {
    // 1. Define an Arc on the XY plane (Radius 5, Center 0,0,0)
    const arc = geom.CircleArc{
        .center = .{ 0, 0, 0 },
        .radius = 5.0,
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 1, 0 },
    };

    // Define the boundary vertices of the half-edge (a full semi-circle)
    const v_start = math.Vec3{ 5, 0, 0 };
    const v_end = math.Vec3{ -5, 0, 0 };

    // 2. Define a Plane at X = 3, facing positive X
    const plane_origin = math.Vec3{ 3, 0, 0 };
    const plane_normal = math.Vec3{ 1, 0, 0 };

    // 3. Perform Intersection
    const hit_opt = booleans.intersectArcPlane(arc, v_start, v_end, plane_origin, plane_normal, true);

    try std.testing.expect(hit_opt != null);
    const hit = hit_opt.?;

    // If R=5 and X=3, then Y must be 4 (3-4-5 right triangle!)
    try std.testing.expectApproxEqAbs(3.0, hit[0], math.MATH_EPSILON);
    try std.testing.expectApproxEqAbs(4.0, @abs(hit[1]), math.MATH_EPSILON);
    try std.testing.expectApproxEqAbs(0.0, hit[2], math.MATH_EPSILON);
}

test "Curve Math: NURBS vs Plane Intersection" {
    // 1. Define a simple 3-point quadratic NURBS curve (a parabola)
    const knots = [_]f64{ 0.0, 0.0, 0.0, 1.0, 1.0, 1.0 };
    const control_points = [_]math.Vec4{
        .{ 0.0, 0.0, 0.0, 1.0 }, // Start at Z=0
        .{ 0.0, 0.0, 10.0, 1.0 }, // Pulled up to Z=10
        .{ 10.0, 0.0, 0.0, 1.0 }, // End at X=10, Z=0
    };
    const curve = geom.NurbsCurve{
        .degree = 2,
        .knots = &knots,
        .control_points = &control_points,
    };

    // 2. Define a horizontal Plane at Z = 2.5
    const plane_origin = math.Vec3{ 0, 0, 2.5 };
    const plane_normal = math.Vec3{ 0, 0, 1 };

    // 3. Perform Intersection (Binary Search)
    const hit_opt = booleans.intersectNurbsPlane(curve, plane_origin, plane_normal);

    try std.testing.expect(hit_opt != null);
    const hit = hit_opt.?;

    // Verify it cleanly hit the Z=2.5 plane
    try std.testing.expectApproxEqAbs(2.5, hit[2], 1e-4);
}

