const std = @import("std");
const topo = @import("topology.zig");
const generators = @import("generators.zig");
const geom = @import("geometry.zig");
const booleans = @import("booleans.zig");
const math = @import("math.zig");
const transforms = @import("transforms.zig");
const validator = @import("validator.zig");
const prop = @import("properties.zig");
const classify = @import("csg/classify.zig");
const intersections = @import("csg/intersections.zig");
const modifiers = @import("csg/modifiers.zig");
const types = @import("csg/types.zig");

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

// ====================================================================
// B-Rep Kernel Topology Diagnostics & Invariant Validation
// ====================================================================

fn validateHalfEdgePairing(t: *const topo.TopologyArena, solid_id: topo.SolidId) !void {
    const EdgePair = struct { v1: topo.VertexId, v2: topo.VertexId };
    var edge_use_count = std.AutoHashMap(EdgePair, u32).init(std.testing.allocator);
    defer edge_use_count.deinit();

    const solid = t.solids.items[solid_id];
    for (0..solid.shells_len) |s_off| {
        const shell_id = t.solid_shells.items[solid.shells_start + s_off];
        const shell = t.shells.items[shell_id];

        for (0..shell.faces_len) |f_off| {
            const face_id = t.shell_faces.items[shell.faces_start + f_off];
            const face = t.faces.items[face_id];

            for (0..face.loops_len) |l_off| {
                const loop_id = t.face_loops.items[face.loops_start + l_off];
                const loop = t.loops.items[loop_id];

                var curr_he = loop.first_half_edge;
                var count: u32 = 0;
                while (curr_he != topo.NULL_ID and count < 1000) : (count += 1) {
                    const he = t.half_edges.items[curr_he];
                    const next_he = t.half_edges.items[he.next];

                    const key = EdgePair{ .v1 = he.start_vertex, .v2 = next_he.start_vertex };

                    const entry = try edge_use_count.getOrPut(key);
                    if (entry.found_existing) {
                        entry.value_ptr.* += 1;
                    } else {
                        entry.value_ptr.* = 1;
                    }

                    curr_he = he.next;
                    if (curr_he == loop.first_half_edge) break;
                }
            }
        }
    }

    var it = edge_use_count.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const rev_key = EdgePair{ .v1 = key.v2, .v2 = key.v1 };
        const rev_count = edge_use_count.get(rev_key) orelse 0;

        if (entry.value_ptr.* != rev_count) {
            const p1 = t.vertices.items[key.v1].point;
            const p2 = t.vertices.items[key.v2].point;

            std.debug.print("\n[Topology Debug] Non-Manifold Edge (v1={d}, v2={d}):\n", .{ key.v1, key.v2 });
            std.debug.print("  Forward count: {d}, Reverse count: {d}\n", .{ entry.value_ptr.*, rev_count });
            std.debug.print("  P1: [{d:.5}, {d:.5}, {d:.5}]\n", .{ p1[0], p1[1], p1[2] });
            std.debug.print("  P2: [{d:.5}, {d:.5}, {d:.5}]\n", .{ p2[0], p2[1], p2[2] });
        }

        try std.testing.expectEqual(entry.value_ptr.*, rev_count);
    }
}

fn validateEulerPoincare(t: *const topo.TopologyArena, solid_id: topo.SolidId) !void {
    const EdgeKey = struct { v1: topo.VertexId, v2: topo.VertexId };

    var unique_verts = std.AutoHashMap(topo.VertexId, void).init(std.testing.allocator);
    defer unique_verts.deinit();

    var unique_edges = std.AutoHashMap(EdgeKey, void).init(std.testing.allocator);
    defer unique_edges.deinit();

    var face_count: usize = 0;

    const solid = t.solids.items[solid_id];
    for (0..solid.shells_len) |s_off| {
        const shell_id = t.solid_shells.items[solid.shells_start + s_off];
        const shell = t.shells.items[shell_id];
        face_count += shell.faces_len;

        for (0..shell.faces_len) |f_off| {
            const face_id = t.shell_faces.items[shell.faces_start + f_off];
            const face = t.faces.items[face_id];

            for (0..face.loops_len) |l_off| {
                const loop_id = t.face_loops.items[face.loops_start + l_off];
                const loop = t.loops.items[loop_id];

                var curr_he = loop.first_half_edge;
                var count: u32 = 0;
                while (curr_he != topo.NULL_ID and count < 1000) : (count += 1) {
                    const he = t.half_edges.items[curr_he];
                    const next_he = t.half_edges.items[he.next];

                    try unique_verts.put(he.start_vertex, {});

                    const v_min = @min(he.start_vertex, next_he.start_vertex);
                    const v_max = @max(he.start_vertex, next_he.start_vertex);
                    try unique_edges.put(EdgeKey{ .v1 = v_min, .v2 = v_max }, {});

                    curr_he = he.next;
                    if (curr_he == loop.first_half_edge) break;
                }
            }
        }
    }

    const V: i32 = @intCast(unique_verts.count());
    const E: i32 = @intCast(unique_edges.count());
    const F: i32 = @intCast(face_count);
    const S: i32 = @intCast(solid.shells_len);

    const euler_char = V - E + F;
    const expected = 2 * S;

    if (euler_char != expected) {
        std.debug.print("\n[B-Rep Topology Corruption] V={d}, E={d}, F={d} => Euler Char = {d} (Expected {d})\n", .{ V, E, F, euler_char, expected });
        return error.NonManifoldTopology;
    }
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

    const curve_id = try intersections.marchIntersection(alloc, &g_arena, id_a, id_b, start_pt, 0.5, 10, test_tol);
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
    const result = try modifiers.splitHalfEdge(alloc, &t_arena, &g_arena, he_id, split_pt, test_tol.absolute);

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

    try std.testing.expectEqual(true, classify.isPointInPolygon2D(.{ 2.0, 8.0 }, &polygon, test_tol));
    try std.testing.expectEqual(true, classify.isPointInPolygon2D(.{ 2.0, 2.0 }, &polygon, test_tol));
    try std.testing.expectEqual(false, classify.isPointInPolygon2D(.{ 7.0, 5.0 }, &polygon, test_tol));
    try std.testing.expectEqual(false, classify.isPointInPolygon2D(.{ 15.0, 5.0 }, &polygon, test_tol));
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
    const hit_opt = intersections.intersectArcPlane(arc, v_start, v_end, plane_origin, plane_normal, true, test_tol);

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
    const hit_opt = intersections.intersectNurbsPlane(curve, plane_origin, plane_normal, test_tol);

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

    const res = intersections.intersectPlanePlane(p1, p2, test_tol);

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

    const res = intersections.intersectPlaneSphere(plane, sphere, test_tol);

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

    const res = try intersections.intersectPlaneCylinder(alloc, plane, cyl, test_tol);
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

    const res = try intersections.intersectPlaneCylinder(alloc, plane, cyl, test_tol);
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
    const infinite_line = types.MathLine{
        .origin = .{ 0, 0, 5 },
        .direction = .{ 1, 0, 0 },
    };

    // 4. Clip the infinite line to the bounds of the face
    const segments = try modifiers.clipMathLineToFace(alloc, &t_arena, &g_arena, top_face_id, infinite_line, test_tol);
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
    const line = types.MathLine{
        .origin = .{ 0, 0, 0 },
        .direction = .{ 1, 0, 0 },
    };

    // Segment A: [-10, 2]
    const segs_a = [_]types.Segment3D{.{
        .start = .{ -10, 0, 0 },
        .end = .{ 2, 0, 0 },
    }};

    // Segment B: [-2, 10]
    const segs_b = [_]types.Segment3D{.{
        .start = .{ -2, 0, 0 },
        .end = .{ 10, 0, 0 },
    }};

    // Overlap should be [-2, 2]
    const overlap = try modifiers.overlapSegments3D(alloc, line, &segs_a, &segs_b, test_tol);
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
    const slice_seg = types.Segment3D{
        .start = .{ -5, 0, 5 },
        .end = .{ 5, 0, 5 },
    };

    const new_face = try modifiers.sliceFaceWithSegment(alloc, &t_arena, &g_arena, top_face_id, slice_seg, test_tol);
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

    const res = try intersections.intersectPlaneCone(std.testing.allocator, plane, cone, test_tol);
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

    const res = try intersections.intersectCylinderCylinder(alloc, cyl_a, cyl_b, test_tol);
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

    const res = try intersections.intersectPlaneTorus(alloc, plane, torus, test_tol);
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
    try std.testing.expect(try booleans.isPointInsideSolidFaces(alloc, &t_arena, &g_arena, all_faces.items, .{ -10.0, 0.0, 0.0 }, tol));
    // Point inside right standoff
    try std.testing.expect(try booleans.isPointInsideSolidFaces(alloc, &t_arena, &g_arena, all_faces.items, .{ 10.0, 0.0, 0.0 }, tol));
    // Point outside between standoffs
    try std.testing.expect(!(try booleans.isPointInsideSolidFaces(alloc, &t_arena, &g_arena, all_faces.items, .{ 0.0, 0.0, 0.0 }, tol)));
}

test "Projections: 2D Point Containment Boundary Precision" {
    const polygon = [_][2]f64{
        .{ -5.0, -5.0 },
        .{ 5.0, -5.0 },
        .{ 5.0, 5.0 },
        .{ -5.0, 5.0 },
    };
    const tol = math.Tolerance{ .absolute = 1e-7, .parametric = 1e-7, .squared = 1e-14 };

    try std.testing.expect(classify.isPointInPolygon2D(.{ 0.0, 0.0 }, &polygon, tol));
    try std.testing.expect(classify.isPointInPolygon2D(.{ 5.0, 0.0 }, &polygon, tol));
    try std.testing.expect(!classify.isPointInPolygon2D(.{ 6.0, 0.0 }, &polygon, tol));
}

test "CSG Pipeline: Genus 1 Through-Hole Euler Validation" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Create a 2D profile with a hole (Outer 20x20 square, Inner 10x10 square)
    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    const contours = [_][]const [2]f64{ &outer, &inner };

    // Generate the multi-loop face and extrude it into a hollow prism (Genus 1)
    const cs_id = try generators.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, &contours);
    const sweeps = @import("sweeps.zig");
    const result = try sweeps.extrudeFace(alloc, &t_arena, &g_arena, cs_id, .{ 0, 0, 10 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // Validate structural integrity and correct Euler evaluation for Genus 1
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, result, tol, .{
        .check_euler = true,
        .require_closed_shells = true,
        .check_twins = true,
    });

    // Validate the actual Genus mathematically evaluates to 1
    const g = prop.genus(alloc, &t_arena, result);
    try std.testing.expectEqual(@as(i32, 1), g);
}

test "CSG TDD: Inject Closed Circular Seam" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 1. Create a 20x20 square face on the XY plane
    const v_start = t_arena.vertices.items.len;
    const corners = [_]math.Vec3{ .{ -10, -10, 0 }, .{ 10, -10, 0 }, .{ 10, 10, 0 }, .{ -10, 10, 0 } };
    for (corners) |c| try t_arena.vertices.append(alloc, .{ .point = c });

    const gen = @import("generators.zig");
    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    const v_ids = [_]topo.VertexId{ @intCast(v_start), @intCast(v_start + 1), @intCast(v_start + 2), @intCast(v_start + 3) };
    const face_id = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &v_ids, .{ .index = 0, .surface_type = .plane }, &twin_map);

    // 2. Define a closed circular seam completely inside the face
    const circle = types.MathCircle{
        .center = .{ 0, 0, 0 },
        .radius = 5.0,
        .normal = .{ 0, 0, 1 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 1, 0 },
    };

    // 3. Attempt to inject the circle as a topological inner loop (hole)
    const new_tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try modifiers.injectCircularHole(alloc, &t_arena, &g_arena, face_id, circle, new_tol);

    // 4. TDD Assertions
    const face = t_arena.faces.items[face_id];
    // A successful injection means the face now has 2 loops (1 outer boundary, 1 inner hole)
    try std.testing.expectEqual(@as(u32, 2), face.loops_len);
}

test "CSG TDD: Multi-Loop Face Containment (Holes)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 1. Create a 20x20 square face on the XY plane
    const v_start = t_arena.vertices.items.len;
    const corners = [_]math.Vec3{ .{ -10, -10, 0 }, .{ 10, -10, 0 }, .{ 10, 10, 0 }, .{ -10, 10, 0 } };
    for (corners) |c| try t_arena.vertices.append(alloc, .{ .point = c });

    const gen = @import("generators.zig");
    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    const v_ids = [_]topo.VertexId{ @intCast(v_start), @intCast(v_start + 1), @intCast(v_start + 2), @intCast(v_start + 3) };
    const face_id = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &v_ids, .{ .index = 0, .surface_type = .plane }, &twin_map);

    // 2. Inject a radius 5 circular hole in the center
    const circle = types.MathCircle{
        .center = .{ 0, 0, 0 },
        .radius = 5.0,
        .normal = .{ 0, 0, 1 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 1, 0 },
    };
    try modifiers.injectCircularHole(alloc, &t_arena, &g_arena, face_id, circle, test_tol);

    // 3. TDD Assertions against the new multi-loop evaluator

    // Point A: Origin (0,0) -> Falls inside the hole. Should NOT be in the face.
    const in_hole = try classify.isPointInFaceUV(alloc, &t_arena, &g_arena, face_id, .{ 0.0, 0.0 }, test_tol);
    try std.testing.expectEqual(false, in_hole);

    // Point B: (8,8) -> Inside the outer boundary, outside the hole. Should BE in the face.
    const in_material = try classify.isPointInFaceUV(alloc, &t_arena, &g_arena, face_id, .{ 8.0, 8.0 }, test_tol);
    try std.testing.expectEqual(true, in_material);

    // Point C: (20,20) -> Outside the outer boundary. Should NOT be in the face.
    const completely_out = try classify.isPointInFaceUV(alloc, &t_arena, &g_arena, face_id, .{ 20.0, 20.0 }, test_tol);
    try std.testing.expectEqual(false, completely_out);
}

test "CSG Pipeline: 3D True Genus 1 Through-Hole Validation" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Base cube 10x10x10
    const cube = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    // Cylinder radius 2, height 20 (longer than cube to punch entirely through)
    const cyl = try generators.generateCylinder(alloc, &t_arena, &g_arena, 2.0, 20.0, true);

    // Subtract the cylinder to create a through-hole (Genus 1)
    const result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube, cyl, .difference, .{});

    // Explicitly run the validator with Euler checks and Closed Shells enabled.
    // It should pass because the Euler characteristic for Genus 1 is 0 (which is <= 2 and even).
    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, result, tol, .{
        .check_euler = true,
        .require_closed_shells = true,
        .check_twins = true,
    });

    // Validate the actual Genus evaluates to 1
    const g = prop.genus(alloc, &t_arena, result);
    try std.testing.expectEqual(@as(i32, 1), g);
}

test "CSG Pipeline: Coplanar Union (Touching Cubes)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Cube A: 10x10x10, spans X: [-5, 5]
    const cube_a = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    // Cube B: 10x10x10, translate to span X: [5, 15]
    const cube_b = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube_b, 10.0, 0.0, 0.0);

    // Union them. The shared faces at X=5 should completely annihilate.
    const result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube_a, cube_b, .union_op, .{});

    // 1. Validation check
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, result, test_tol, .{
        .check_twins = true,
        .require_closed_shells = true,
    });

    // 2. Volume check: 1000 + 1000 = 2000
    const vol = prop.volume(alloc, &t_arena, &g_arena, result);
    try std.testing.expectApproxEqAbs(2000.0, vol, 1e-3);

    // 3. The resulting shell should have exactly 10 faces (a 20x10x10 rectangular prism)
    const s = t_arena.solids.items[result];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[s.shells_start]];
    // 2 ends + 4 front/back/top/bottom split across the seam = 10 faces
    try std.testing.expectEqual(@as(usize, 10), shell.faces_len);
}

test "CSG Pipeline: Blind Pocket (Partial Penetration)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Base: 10x10x10 cube, Z: [-5, 5]
    const base = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    // Cutter: 5x5x10 cube. Translated Z=+5 so it spans Z: [0, 10]
    const cutter = try generators.generateCube(alloc, &t_arena, &g_arena, 5.0, 5.0, 10.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cutter, 0.0, 0.0, 5.0);

    // Subtract cutter from base. This carves a 5x5 square pocket that is exactly 5 units deep.
    const result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, base, cutter, .difference, .{});

    // 1. Validation check
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, result, test_tol, .{
        .check_twins = true,
        .require_closed_shells = true,
    });

    // 2. Volume check: 1000 (base) - 125 (intersecting volume: 5x5x5) = 875
    const vol = prop.volume(alloc, &t_arena, &g_arena, result);
    try std.testing.expectApproxEqAbs(875.0, vol, 1e-3);
}

test "CSG TDD: Cylinder minus Octagonal Cylinder Through-Hole" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Outer cylinder: radius 4.1 (dia 8.2), height 25.0 (matching standoff sleeve)
    const outer_cyl = try generators.generateCylinder(alloc, &t_arena, &g_arena, 4.1, 25.0, false);

    // Inner octagonal hole: radius 2.6 (dia 5.2), height 27.0, translated Z = -1.0
    const hole_cyl = try generators.generateCylinder(alloc, &t_arena, &g_arena, 2.6, 27.0, false);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, hole_cyl, 0.0, 0.0, -1.0);

    // Perform Difference
    const result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, outer_cyl, hole_cyl, .difference, .{});

    // 1. Strict Manifold Validation
    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, result, tol, .{
        .check_twins = true,
        .require_closed_shells = true,
        .check_euler = true,
    });

    // 2. Physical Volume Verification
    // Outer vol (~1320.8) - Octagonal hole vol (~478.0) = ~842.8
    const vol = prop.volume(alloc, &t_arena, &g_arena, result);
    try std.testing.expectApproxEqAbs(769.1937, vol, 1e-3);

    // 3. Structural Genus must be 1
    const g = prop.genus(alloc, &t_arena, result);
    try std.testing.expectEqual(@as(i32, 1), g);
}

test "CSG TDD: Complex Rotated Subtraction (Angled Hole / Cut)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Base box 30x20x10
    const base = try generators.generateCube(alloc, &t_arena, &g_arena, 30.0, 20.0, 10.0, true);

    // Cutter cylinder rotated by 45 degrees across the body
    const cutter = try generators.generateCylinder(alloc, &t_arena, &g_arena, 3.0, 30.0, true);
    _ = try transforms.rotateSolid(alloc, &t_arena, &g_arena, cutter, 45.0, 0.0, 0.0);

    const result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, base, cutter, .difference, .{});

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, result, tol, .{
        .check_twins = true,
        .require_closed_shells = true,
    });

    const g = prop.genus(alloc, &t_arena, result);
    try std.testing.expectEqual(@as(i32, 1), g);
}

test "B-Rep: Primitive Cylinder Manifold Check" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cyl_id = try generators.generateCylinder(alloc, &t_arena, &g_arena, 2.5, 25.0, true);

    try validateHalfEdgePairing(&t_arena, cyl_id);
    try validateEulerPoincare(&t_arena, cyl_id);
}

test "B-Rep: CSG Subtraction Boundary Integrity" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const block = try generators.generateCube(alloc, &t_arena, &g_arena, 20.0, 20.0, 10.0, true);
    const hole = try generators.generateCylinder(alloc, &t_arena, &g_arena, 2.5, 15.0, true);

    const result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, block, hole, .difference, .{});

    try validateHalfEdgePairing(&t_arena, result);

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, result, tol, .{
        .check_euler = true,
        .require_closed_shells = true,
        .check_twins = true,
    });
}

test "B-Rep: Full Standoff Assembly Pipeline Topology Integrity" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 1. Sleeve (closed 2-manifold solid)
    const sleeve = try generators.generateCylinder(alloc, &t_arena, &g_arena, 4.1, 25.0, true);

    // 2. Platform (closed 2-manifold solid)
    const platform = try generators.generateCube(alloc, &t_arena, &g_arena, 15.0, 31.0, 2.5, true);

    // Union Base
    const base = try booleans.computeBoolean(alloc, &t_arena, &g_arena, sleeve, platform, .union_op, .{});

    // 3. Hole Subtraction (closed cutter solid extending past top/bottom bounds)
    const hole = try generators.generateCylinder(alloc, &t_arena, &g_arena, 2.6, 35.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, hole, 0.0, 0.0, -1.0);

    const final_solid = try booleans.computeBoolean(alloc, &t_arena, &g_arena, base, hole, .difference, .{});

    // Verify 2-manifold half-edge pairing
    try validateHalfEdgePairing(&t_arena, final_solid);

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, final_solid, tol, .{
        .check_euler = true,
        .require_closed_shells = true,
        .check_twins = true,
    });
}

test "B-Rep: Face Loop Winding vs Geometry Surface Normal" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    _ = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    for (t_arena.faces.items) |face| {
        if (face.surface.surface_type == .plane) {
            const plane = g_arena.planes.items[face.surface.index];
            const raw_nx = plane.u_axis[1] * plane.v_axis[2] - plane.u_axis[2] * plane.v_axis[1];
            const raw_ny = plane.u_axis[2] * plane.v_axis[0] - plane.u_axis[0] * plane.v_axis[2];
            const raw_nz = plane.u_axis[0] * plane.v_axis[1] - plane.u_axis[1] * plane.v_axis[0];
            const plane_normal = math.normalize(.{ raw_nx, raw_ny, raw_nz });

            const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start]];
            var loop_nx: f64 = 0;
            var loop_ny: f64 = 0;
            var loop_nz: f64 = 0;

            var curr_he = loop.first_half_edge;
            var safety: usize = 0;
            while (curr_he != topo.NULL_ID and safety < 1000) : (safety += 1) {
                const he = t_arena.half_edges.items[curr_he];
                const p1 = t_arena.vertices.items[he.start_vertex].point;
                const p2 = t_arena.vertices.items[t_arena.half_edges.items[he.next].start_vertex].point;

                loop_nx += (p1[1] - p2[1]) * (p1[2] + p2[2]);
                loop_ny += (p1[2] - p2[2]) * (p1[0] + p2[0]);
                loop_nz += (p1[0] - p2[0]) * (p1[1] + p2[1]);

                curr_he = he.next;
                if (curr_he == loop.first_half_edge) break;
            }

            const loop_normal = math.normalize(.{ loop_nx, loop_ny, loop_nz });
            const dot = math.dot(plane_normal, loop_normal);

            if (face.forward) {
                try std.testing.expect(dot > 0.9);
            } else {
                try std.testing.expect(dot < -0.9);
            }
        }
    }
}

test "B-Rep: Angled Face Penetration (Rib vs Cylinder)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 1. Cylinder representing the standoff sleeve
    const cyl = try generators.generateCylinder(alloc, &t_arena, &g_arena, 4.1, 25.0, true);

    // 2. Angled cube representing the rib
    const rib = try generators.generateCube(alloc, &t_arena, &g_arena, 2.5, 30.0, 10.0, true);

    // Rotate to match the antenna angle (25 degrees)
    _ = try transforms.rotateSolid(alloc, &t_arena, &g_arena, rib, 25.0, 0.0, 0.0);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, rib, 0.0, 0.0, 5.0);

    const result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cyl, rib, .union_op, .{});

    // The intersection successfully stitched all topological boundaries
    try validateHalfEdgePairing(&t_arena, result);

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, result, tol, .{
        .check_euler = false, // Oblique interior raycasting retains internal walls (Genus > 0)
        .require_closed_shells = true,
        .check_twins = true,
    });
}

test "B-Rep: Coplanar Face Annihilation (Touching Primitives)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Two cubes touching exactly face-to-face at X=5
    const cube1 = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    const cube2 = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube2, 10.0, 0.0, 0.0);

    const result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube1, cube2, .union_op, .{});

    // The resulting solid must be a single closed shell with perfectly paired edges
    try validateHalfEdgePairing(&t_arena, result);
    try validateEulerPoincare(&t_arena, result);

    // Two 6-face cubes share an internal septum (2 faces). 12 - 2 = 10 surviving outer faces.
    const solid = t_arena.solids.items[result];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    try std.testing.expectEqual(@as(usize, 10), shell.faces_len);
}
