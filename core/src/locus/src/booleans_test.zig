const std = @import("std");
const topo = @import("topology.zig");
const generators = @import("generators.zig");
const geom = @import("geometry.zig");
const booleans = @import("booleans.zig");
const math = @import("math.zig");
const transforms = @import("transforms.zig");

const test_tol = math.Tolerance{
    .absolute = 1e-5,
    .squared = 1e-10,
    .parametric = 1e-5,
};

fn makeTestCubeFaces(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    center: math.Vec3,
    size: f64,
) ![]topo.FaceId {
    const hs = size / 2.0;
    const v_start = t_arena.vertices.items.len;

    const corners = [_]math.Vec3{
        .{ center[0] - hs, center[1] - hs, center[2] - hs },
        .{ center[0] + hs, center[1] - hs, center[2] - hs },
        .{ center[0] + hs, center[1] + hs, center[2] - hs },
        .{ center[0] - hs, center[1] + hs, center[2] - hs },
        .{ center[0] - hs, center[1] - hs, center[2] + hs },
        .{ center[0] + hs, center[1] - hs, center[2] + hs },
        .{ center[0] + hs, center[1] + hs, center[2] + hs },
        .{ center[0] - hs, center[1] + hs, center[2] + hs },
    };

    for (corners) |c| {
        try t_arena.vertices.append(allocator, .{ .point = c });
    }

    const quads = [_][4]usize{
        .{ 0, 3, 2, 1 }, // -Z
        .{ 4, 5, 6, 7 }, // +Z
        .{ 0, 1, 5, 4 }, // -Y
        .{ 2, 3, 7, 6 }, // +Y
        .{ 0, 4, 7, 3 }, // -X
        .{ 1, 2, 6, 5 }, // +X
    };

    const normals = [_]math.Vec3{
        .{ 0, 0, -1 },
        .{ 0, 0, 1 },
        .{ 0, -1, 0 },
        .{ 0, 1, 0 },
        .{ -1, 0, 0 },
        .{ 1, 0, 0 },
    };

    var created_faces: std.ArrayListUnmanaged(topo.FaceId) = .empty;

    for (quads, normals) |quad, n| {
        const plane_idx: u24 = @intCast(g_arena.planes.items.len);
        var u_ax = math.Vec3{ 1, 0, 0 };
        if (@abs(n[0]) > 0.9) u_ax = .{ 0, 1, 0 };
        const v_ax = math.normalize(math.cross(n, u_ax));
        u_ax = math.normalize(math.cross(v_ax, n));

        try g_arena.planes.append(allocator, .{
            .origin = t_arena.vertices.items[v_start + quad[0]].point,
            .u_axis = u_ax,
            .v_axis = v_ax,
        });

        const loop_id: u32 = @intCast(t_arena.loops.items.len);
        const he_start: u32 = @intCast(t_arena.half_edges.items.len);

        for (0..4) |i| {
            const v0 = @as(u32, @intCast(v_start + quad[i]));
            const next_he = he_start + @as(u32, @intCast((i + 1) % 4));
            const prev_he = he_start + @as(u32, @intCast((i + 3) % 4));

            try t_arena.half_edges.append(allocator, .{
                .start_vertex = v0,
                .twin = topo.NULL_ID,
                .next = next_he,
                .prev = prev_he,
                .loop_id = loop_id,
                .curve = .{ .index = 0, .curve_type = .line },
                .forward = true,
            });
        }

        const face_id: u32 = @intCast(t_arena.faces.items.len);
        try t_arena.loops.append(allocator, .{ .face_id = face_id, .first_half_edge = he_start });

        const fl_start: u32 = @intCast(t_arena.face_loops.items.len);
        try t_arena.face_loops.append(allocator, loop_id);

        try t_arena.faces.append(allocator, .{
            .surface = .{ .index = plane_idx, .surface_type = .plane },
            .forward = true,
            .loops_start = fl_start,
            .loops_len = 1,
        });

        try created_faces.append(allocator, face_id);
    }

    return created_faces.toOwnedSlice(allocator);
}

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

    const curve_id = try booleans.marchIntersection(alloc, &g_arena, id_a, id_b, start_pt, 0.5, 10, test_tol);
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

    try std.testing.expectEqual(true, booleans.isPointInPolygon2D(.{ 2.0, 8.0 }, &polygon, test_tol));
    try std.testing.expectEqual(true, booleans.isPointInPolygon2D(.{ 2.0, 2.0 }, &polygon, test_tol));
    try std.testing.expectEqual(false, booleans.isPointInPolygon2D(.{ 7.0, 5.0 }, &polygon, test_tol));
    try std.testing.expectEqual(false, booleans.isPointInPolygon2D(.{ 15.0, 5.0 }, &polygon, test_tol));
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
    const hit_opt = booleans.intersectArcPlane(arc, v_start, v_end, plane_origin, plane_normal, true, test_tol);

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
    const hit_opt = booleans.intersectNurbsPlane(curve, plane_origin, plane_normal, test_tol);

    try std.testing.expect(hit_opt != null);
    const hit = hit_opt.?;

    // Verify it cleanly hit the Z=2.5 plane
    try std.testing.expectApproxEqAbs(2.5, hit[2], 1e-4);
}

test "Exact SSI: Plane vs Plane (Perpendicular)" {
    // XY Plane
    const p1 = geom.Plane{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } };
    // XZ Plane
    const p2 = geom.Plane{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 0, 1 } };

    const res = booleans.intersectPlanePlane(p1, p2, test_tol);

    // The intersection of XY and XZ is the X-axis
    try std.testing.expect(res == .line);
    try std.testing.expectApproxEqAbs(1.0, @abs(res.line.direction[0]), 1e-9);
    try std.testing.expectApproxEqAbs(0.0, res.line.direction[1], 1e-9);
    try std.testing.expectApproxEqAbs(0.0, res.line.direction[2], 1e-9);
}

test "Exact SSI: Plane vs Sphere (Through Center)" {
    // XY Plane shifted to Z=5
    const plane = geom.Plane{ .origin = .{ 0, 0, 5 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } };
    // Sphere at Z=5, Radius 10
    const sphere = geom.Sphere{ .center = .{ 0, 0, 5 }, .radius = 10.0 };

    const res = booleans.intersectPlaneSphere(plane, sphere, test_tol);

    // Should be a perfect circle of radius 10 at Z=5
    try std.testing.expect(res == .circle);
    try std.testing.expectApproxEqAbs(10.0, res.circle.radius, 1e-9);
    try std.testing.expectApproxEqAbs(5.0, res.circle.center[2], 1e-9);
}

test "Sampler SSI: Plane vs Cylinder (Perpendicular Circle)" {
    const alloc = std.testing.allocator;
    const plane = geom.Plane{ .origin = .{ 0, 0, 10 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } };
    const cyl = geom.Cylinder{
        .origin = .{ 0, 0, 0 },
        .axis = .{ 0, 0, 1 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 1, 0 },
        .radius = 5.0,
    };

    const res = try booleans.intersectPlaneCylinder(alloc, plane, cyl, test_tol);
    try std.testing.expect(res == .circle);
    try std.testing.expectApproxEqAbs(5.0, res.circle.radius, 1e-9);
    try std.testing.expectApproxEqAbs(10.0, res.circle.center[2], 1e-9);
}

test "Sampler SSI: Plane vs Cylinder (Oblique Ellipse Sampled)" {
    const alloc = std.testing.allocator;
    // Angled plane at 45 degrees
    const plane = geom.Plane{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 1 } };
    const cyl = geom.Cylinder{
        .origin = .{ 0, 0, 0 },
        .axis = .{ 0, 0, 1 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 1, 0 },
        .radius = 5.0,
    };

    const res = try booleans.intersectPlaneCylinder(alloc, plane, cyl, test_tol);
    try std.testing.expect(res == .sampled);
    defer alloc.free(res.sampled);

    try std.testing.expect(res.sampled.len >= 64);
}

test "Phase 4: Face Line Clipping (Infinite Line to Finite Segment)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 1. Generate a 10x10x10 cube
    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // 2. Grab the top face (+Z plane)
    const solid = t_arena.solids.items[cube_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    const top_face_id = t_arena.shell_faces.items[shell.faces_start + 1]; // Face 1 is Z+

    // 3. Define an infinite line slicing diagonally across the top face at Y=0
    // The cube goes from X=-5 to X=5.
    const infinite_line = booleans.MathLine{
        .origin = .{ 0, 0, 5 },
        .direction = .{ 1, 0, 0 },
    };

    // 4. Clip the infinite line to the bounds of the face
    const segments = try booleans.clipMathLineToFace(alloc, &t_arena, &g_arena, top_face_id, infinite_line, test_tol);
    defer alloc.free(segments);

    // It should yield exactly one finite segment stretching from X=-5 to X=5
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expectApproxEqAbs(-5.0, segments[0].start[0], 1e-5);
    try std.testing.expectApproxEqAbs(5.0, segments[0].end[0], 1e-5);
}

test "Phase 4: 3D Segment Overlap and Topological Slicing" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 1. Line passing along X-axis
    const line = booleans.MathLine{
        .origin = .{ 0, 0, 0 },
        .direction = .{ 1, 0, 0 },
    };

    // Segment A: [-10, 2]
    const segs_a = [_]booleans.Segment3D{.{
        .start = .{ -10, 0, 0 },
        .end = .{ 2, 0, 0 },
    }};

    // Segment B: [-2, 10]
    const segs_b = [_]booleans.Segment3D{.{
        .start = .{ -2, 0, 0 },
        .end = .{ 10, 0, 0 },
    }};

    // Overlap should be [-2, 2]
    const overlap = try booleans.overlapSegments3D(alloc, line, &segs_a, &segs_b, test_tol);
    defer alloc.free(overlap);

    try std.testing.expectEqual(@as(usize, 1), overlap.len);
    try std.testing.expectApproxEqAbs(-2.0, overlap[0].start[0], 1e-5);
    try std.testing.expectApproxEqAbs(2.0, overlap[0].end[0], 1e-5);

    // 2. Test slicing a cube face with the overlapped segment
    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    const solid = t_arena.solids.items[cube_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    const top_face_id = t_arena.shell_faces.items[shell.faces_start + 1];

    // Slice top face (+Z) across Y=0 from X=-5 to X=5
    const slice_seg = booleans.Segment3D{
        .start = .{ -5, 0, 5 },
        .end = .{ 5, 0, 5 },
    };

    const new_face = try booleans.sliceFaceWithSegment(alloc, &t_arena, &g_arena, top_face_id, slice_seg, test_tol);
    try std.testing.expect(new_face != null);
}

test "Phase 5: Full 3D SSI Pipeline (Intersecting Cube Faces)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_a = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    const cube_b = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube_b, 5, 5, 5);

    const initial_faces_a = t_arena.faces.items.len;

    var faces_a: std.ArrayListUnmanaged(topo.FaceId) = .empty;
    defer faces_a.deinit(alloc);
    var faces_b: std.ArrayListUnmanaged(topo.FaceId) = .empty;
    defer faces_b.deinit(alloc);

    const s_a = t_arena.solids.items[cube_a];
    const sh_a = t_arena.shells.items[t_arena.solid_shells.items[s_a.shells_start]];
    for (0..sh_a.faces_len) |i| try faces_a.append(alloc, t_arena.shell_faces.items[sh_a.faces_start + i]);

    const s_b = t_arena.solids.items[cube_b];
    const sh_b = t_arena.shells.items[t_arena.solid_shells.items[s_b.shells_start]];
    for (0..sh_b.faces_len) |i| try faces_b.append(alloc, t_arena.shell_faces.items[sh_b.faces_start + i]);

    try booleans.intersectAndSplitFaces3D(alloc, &t_arena, &g_arena, cube_a, cube_b, &faces_a, &faces_b, test_tol);

    try std.testing.expect(t_arena.faces.items.len > initial_faces_a);
}

test "Exact SSI: Plane vs Cone (Apex Cut Rulings)" {
    const plane = geom.Plane{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 0, 1 } };
    const cone = geom.Cone{
        .origin = .{ 0, 0, 0 },
        .axis = .{ 0, 0, 1 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 1, 0 },
        .radius = 0.0,
        .half_angle = std.math.pi / 4.0,
    };

    const res = try booleans.intersectPlaneCone(std.testing.allocator, plane, cone, test_tol);
    try std.testing.expect(res == .two_lines);
}

test "Exact SSI: Cylinder vs Cylinder (Steinmetz Curves)" {
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

    const res = try booleans.intersectCylinderCylinder(alloc, cyl_a, cyl_b, test_tol);
    try std.testing.expect(res == .two_sampled);
    alloc.free(res.two_sampled[0]); // Indexed as array element 0
    alloc.free(res.two_sampled[1]); // Indexed as array element 1
}

test "Exact SSI: Plane vs Torus (Perpendicular Cut)" {
    const alloc = std.testing.allocator;
    const plane = geom.Plane{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } };
    const torus = geom.Torus{
        .center = .{ 0, 0, 0 },
        .axis = .{ 0, 0, 1 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 1, 0 },
        .major_radius = 10.0,
        .minor_radius = 3.0,
    };

    const res = try booleans.intersectPlaneTorus(alloc, plane, torus, test_tol);
    try std.testing.expect(res == .circle);
    try std.testing.expectApproxEqAbs(13.0, res.circle.radius, 1e-9);
}

test "Booleans: Point Inclusion for Multi-Body Boundaries" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const left_faces = try makeTestCubeFaces(alloc, &t_arena, &g_arena, .{ -10.0, 0.0, 0.0 }, 6.0);
    defer alloc.free(left_faces);

    const right_faces = try makeTestCubeFaces(alloc, &t_arena, &g_arena, .{ 10.0, 0.0, 0.0 }, 6.0);
    defer alloc.free(right_faces);

    var all_faces: std.ArrayListUnmanaged(topo.FaceId) = .empty;
    defer all_faces.deinit(alloc);
    try all_faces.appendSlice(alloc, left_faces);
    try all_faces.appendSlice(alloc, right_faces);

    const tol = math.Tolerance{ .absolute = 1e-7, .parametric = 1e-7, .squared = 1e-14 };

    // Point inside left standoff
    try std.testing.expect(booleans.isPointInsideSolidFaces(&t_arena, &g_arena, all_faces.items, .{ -10.0, 0.0, 0.0 }, tol));
    // Point inside right standoff
    try std.testing.expect(booleans.isPointInsideSolidFaces(&t_arena, &g_arena, all_faces.items, .{ 10.0, 0.0, 0.0 }, tol));
    // Point outside between standoffs
    try std.testing.expect(!booleans.isPointInsideSolidFaces(&t_arena, &g_arena, all_faces.items, .{ 0.0, 0.0, 0.0 }, tol));
}

test "Projections: 2D Point Containment Boundary Precision" {
    const polygon = [_][2]f64{
        .{ -5.0, -5.0 },
        .{ 5.0, -5.0 },
        .{ 5.0, 5.0 },
        .{ -5.0, 5.0 },
    };
    const tol = math.Tolerance{ .absolute = 1e-7, .parametric = 1e-7, .squared = 1e-14 };

    try std.testing.expect(booleans.isPointInPolygon2D(.{ 0.0, 0.0 }, &polygon, tol));
    try std.testing.expect(booleans.isPointInPolygon2D(.{ 5.0, 0.0 }, &polygon, tol));
    try std.testing.expect(!booleans.isPointInPolygon2D(.{ 6.0, 0.0 }, &polygon, tol));
}
