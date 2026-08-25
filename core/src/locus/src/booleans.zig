const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const BooleanOp = enum { union_op, difference, intersection };
pub const FaceClassification = enum { inside, outside, same, opposite };

pub const BooleanError = error{
    OutOfMemory,
    DidNotConverge,
};

/// Snaps a 3D point exactly onto the intersection curve of two surfaces.
fn snapToIntersection(
    g_arena: *const geom.GeometryArena,
    id_a: geom.SurfaceId,
    id_b: geom.SurfaceId,
    guess: math.Vec3,
    tolerance: f64,
) ?math.Vec3 {
    var pt = guess;
    for (0..10) |_| {
        // Project onto A via centralized dispatcher
        const uv_a = g_arena.surfaceProject(id_a, pt);
        const pt_a = g_arena.surfaceSubs(id_a, uv_a[0], uv_a[1]);

        // Project onto B via centralized dispatcher
        const uv_b = g_arena.surfaceProject(id_b, pt_a);
        const pt_b = g_arena.surfaceSubs(id_b, uv_b[0], uv_b[1]);

        if (math.distSq(pt, pt_b) < tolerance * tolerance) {
            return pt_b;
        }
        pt = pt_b;
    }
    return null;
}

/// Computes the intersection curve between two surfaces using the Marching Algorithm.
pub fn marchIntersection(
    allocator: std.mem.Allocator,
    g_arena: *geom.GeometryArena,
    surf_a_id: geom.SurfaceId,
    surf_b_id: geom.SurfaceId,
    start_pt: math.Vec3,
    step_size: f64,
    max_steps: u32,
    tolerance: f64,
) BooleanError!geom.CurveId {
    var points: std.ArrayListUnmanaged(math.Vec3) = .empty;
    defer points.deinit(allocator);

    var current_pt = start_pt;
    try points.append(allocator, current_pt);

    for (0..max_steps) |_| {
        // 1. Get exact parameters via dispatch
        const uv_a = g_arena.surfaceProject(surf_a_id, current_pt);
        const uv_b = g_arena.surfaceProject(surf_b_id, current_pt);

        // 2. Evaluate normals via dispatch
        const normal_a = g_arena.surfaceNormal(surf_a_id, uv_a[0], uv_a[1]);
        const normal_b = g_arena.surfaceNormal(surf_b_id, uv_b[0], uv_b[1]);

        // 3. Tangent of intersection
        const tangent = math.normalize(math.cross(normal_a, normal_b));
        if (math.magSq(tangent) < math.MATH_EPSILON) break;

        // 4. Step forward
        const next_guess = math.add(current_pt, math.scale(tangent, step_size));

        // 5. Snap back to intersection seam
        current_pt = snapToIntersection(g_arena, surf_a_id, surf_b_id, next_guess, tolerance) orelse return error.DidNotConverge;

        try points.append(allocator, current_pt);

        if (points.items.len > 3 and math.distSq(current_pt, start_pt) < tolerance * tolerance) {
            break;
        }
    }

    // Dummy return, but wrapped in the new packed struct ID type
    return geom.CurveId{ .index = @intCast(g_arena.lines.items.len), .curve_type = .line };
}

/// Determines if a face from Solid A is inside, outside, or coplanar to Solid B.
fn classifyFace(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    face_id: topo.FaceId,
    target_solid_id: topo.SolidId,
) FaceClassification {
    _ = allocator;
    const face = t_arena.faces.items[face_id];

    // 1. Calculate a sample point on the face.
    // For a strict implementation, this should be the centroid.
    // Here we sample the very first vertex of the face.
    const first_wire = t_arena.wires.items[t_arena.face_wires.items[face.wires_start]];
    const first_edge = t_arena.edges.items[t_arena.wire_edges.items[first_wire.edges_start].edge];
    const sample_pt = t_arena.vertices.items[first_edge.front].point;

    // 2. We shift the sample point slightly along the face normal to avoid boundary ambiguity
    var normal = math.Vec3{ 0, 0, 1 };
    if (face.surface.surface_type == .plane) {
        const plane = g_arena.planes.items[face.surface.index];
        normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
        if (!face.forward) normal = math.scale(normal, -1.0);
    }

    // Shift slightly inward (against the normal) to test if the body of the face is inside
    const test_pt = math.sub(sample_pt, math.scale(normal, 1e-4));

    // 3. Fire the Raycaster!
    if (isPointInsideSolid(t_arena, g_arena, target_solid_id, test_pt)) {
        return .inside;
    }

    return .outside;
}

/// Scans the boundary edges of Solid A against the faces of Solid B.
/// If an edge pierces a face, it geometrically splits the edge.
fn splitIntersectingFaces(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_a: topo.SolidId,
    solid_b: topo.SolidId,
) !struct { faces_a: []topo.FaceId, faces_b: []topo.FaceId } {

    // (This is a simplified O(N^2) naive broadphase for the skeleton).
    const sa = t_arena.solids.items[solid_a];
    const sb = t_arena.solids.items[solid_b];

    // Iterate through all faces of Solid B (the cutting planes)
    for (0..sb.shells_len) |sb_off| {
        const shell_b = t_arena.shells.items[t_arena.solid_shells.items[sb.shells_start + sb_off]];
        for (0..shell_b.faces_len) |fb_off| {
            const face_b = t_arena.faces.items[t_arena.shell_faces.items[shell_b.faces_start + fb_off]];

            // For now, assume cutting faces are planes
            if (face_b.surface.surface_type != .plane) continue;
            const plane_b = g_arena.planes.items[face_b.surface.index];

            // Iterate through all edges of Solid A (the target edges)
            for (0..sa.shells_len) |sa_off| {
                const shell_a = t_arena.shells.items[t_arena.solid_shells.items[sa.shells_start + sa_off]];
                for (0..shell_a.faces_len) |fa_off| {
                    const face_a = t_arena.faces.items[t_arena.shell_faces.items[shell_a.faces_start + fa_off]];
                    for (0..face_a.wires_len) |wa_off| {
                        const wire_a = t_arena.wires.items[t_arena.face_wires.items[face_a.wires_start + wa_off]];
                        for (0..wire_a.edges_len) |ea_off| {
                            const edge_id = t_arena.wire_edges.items[wire_a.edges_start + ea_off].edge;
                            const edge = t_arena.edges.items[edge_id];

                            if (edge.curve.curve_type != .line) continue;
                            const line = g_arena.lines.items[edge.curve.index];

                            // Evaluate intersection
                            const normal = math.cross(plane_b.u_axis, plane_b.v_axis);
                            if (intersectLinePlane(line.start, line.end, plane_b.origin, normal)) |hit_pt| {
                                // Split the edge!
                                _ = try splitEdgeTopologically(allocator, t_arena, g_arena, edge_id, hit_pt);
                            }
                        }
                    }
                }
            }
        }
    }

    return .{ .faces_a = &[_]topo.FaceId{}, .faces_b = &[_]topo.FaceId{} };
}

/// Computes the exact 3D intersection point between a Line and a Plane.
/// Returns null if they are parallel or the intersection is outside the line segment.
fn intersectLinePlane(
    line_start: math.Vec3,
    line_end: math.Vec3,
    plane_origin: math.Vec3,
    plane_normal: math.Vec3,
) ?math.Vec3 {
    const dir = math.sub(line_end, line_start);
    const denominator = math.dot(dir, plane_normal);

    // If denominator is near 0, the line is parallel to the plane
    if (@abs(denominator) < math.MATH_EPSILON) return null;

    const p0l0 = math.sub(plane_origin, line_start);
    const t = math.dot(p0l0, plane_normal) / denominator;

    // Check if the intersection happens strictly within the line segment bounds
    if (t > math.MATH_EPSILON and t < (1.0 - math.MATH_EPSILON)) {
        return math.add(line_start, math.scale(dir, t));
    }
    return null;
}

/// Scans all wires in the topology arena. If a wire contains `old_edge`, it builds a
/// brand new edge sequence at the end of the array, replacing the split edge with `e1` and `e2`
/// while preserving the correct topological winding order.
fn replaceEdgeInAllWires(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    old_edge: topo.EdgeId,
    e1: topo.EdgeId,
    e2: topo.EdgeId,
) !void {
    // Iterate through all active wires by reference so we can mutate them
    for (t_arena.wires.items) |*wire| {
        var contains_edge = false;

        // Check if this wire contains the edge we just split
        for (0..wire.edges_len) |i| {
            if (t_arena.wire_edges.items[wire.edges_start + i].edge == old_edge) {
                contains_edge = true;
                break;
            }
        }

        if (!contains_edge) continue;

        // The wire needs reweaving. We append a new sequence to the end of wire_edges
        // to avoid shifting memory and corrupting the indices of other wires.
        const new_start: u32 = @intCast(t_arena.wire_edges.items.len);
        var new_len: u32 = 0;

        for (0..wire.edges_len) |i| {
            const d_edge = t_arena.wire_edges.items[wire.edges_start + i];

            if (d_edge.edge == old_edge) {
                // We must respect the original winding order of the split edge!
                if (d_edge.forward) {
                    try t_arena.wire_edges.append(allocator, .{ .edge = e1, .forward = true });
                    try t_arena.wire_edges.append(allocator, .{ .edge = e2, .forward = true });
                } else {
                    // If traversed backward, we hit the second segment (e2) BEFORE the first (e1)
                    try t_arena.wire_edges.append(allocator, .{ .edge = e2, .forward = false });
                    try t_arena.wire_edges.append(allocator, .{ .edge = e1, .forward = false });
                }
                new_len += 2;
            } else {
                try t_arena.wire_edges.append(allocator, d_edge);
                new_len += 1;
            }
        }

        // Point the wire to the newly appended memory segment
        wire.edges_start = new_start;
        wire.edges_len = new_len;
    }
}

/// Splits a single topological edge at a given 3D point and dynamically re-weaves the graph.
/// Returns the new VertexId and the two new EdgeIds.
pub fn splitEdgeTopologically(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    edge_id: topo.EdgeId,
    split_pt: math.Vec3,
) !struct { v_mid: topo.VertexId, e1: topo.EdgeId, e2: topo.EdgeId } {
    const orig_edge = t_arena.edges.items[edge_id];

    // 1. Create the new Vertex
    const v_mid_id: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.append(allocator, .{ .point = split_pt });

    // 2. Create the two new Geometric Lines
    const p_front = t_arena.vertices.items[orig_edge.front].point;
    const p_back = t_arena.vertices.items[orig_edge.back].point;

    const l1_idx: u24 = @intCast(g_arena.lines.items.len);
    try g_arena.lines.append(allocator, .{ .start = p_front, .end = split_pt });

    const l2_idx: u24 = @intCast(g_arena.lines.items.len);
    try g_arena.lines.append(allocator, .{ .start = split_pt, .end = p_back });

    // 3. Create the two new Topological Edges
    const e1_id: u32 = @intCast(t_arena.edges.items.len);
    try t_arena.edges.append(allocator, .{
        .front = orig_edge.front,
        .back = v_mid_id,
        .curve = .{ .index = l1_idx, .curve_type = .line },
    });

    const e2_id: u32 = @intCast(t_arena.edges.items.len);
    try t_arena.edges.append(allocator, .{
        .front = v_mid_id,
        .back = orig_edge.back,
        .curve = .{ .index = l2_idx, .curve_type = .line },
    });

    // 4. Update the global graph!
    try replaceEdgeInAllWires(allocator, t_arena, edge_id, e1_id, e2_id);

    return .{ .v_mid = v_mid_id, .e1 = e1_id, .e2 = e2_id };
}

/// Splits a face in two by drawing a new edge between v1 and v2 on its boundary.
/// Modifies the original face and returns the ID of the newly generated sub-face.
pub fn splitFaceTopologically(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    face_id: topo.FaceId,
    v1_id: topo.VertexId,
    v2_id: topo.VertexId,
) !topo.FaceId {
    const orig_face = t_arena.faces.items[face_id];
    // For simplicity in this skeleton, we assume the face only has 1 outer wire.
    const orig_wire_id = t_arena.face_wires.items[orig_face.wires_start];
    const orig_wire = t_arena.wires.items[orig_wire_id];

    // 1. Create the bridging geometric line and topological edge
    const p1 = t_arena.vertices.items[v1_id].point;
    const p2 = t_arena.vertices.items[v2_id].point;

    const line_idx: u24 = @intCast(g_arena.lines.items.len);
    try g_arena.lines.append(allocator, .{ .start = p1, .end = p2 });

    const split_edge_id: u32 = @intCast(t_arena.edges.items.len);
    try t_arena.edges.append(allocator, .{
        .front = v1_id,
        .back = v2_id,
        .curve = .{ .index = line_idx, .curve_type = .line },
    });

    // 2. Traverse the original wire to separate edges into Loop A and Loop B
    var edges_a: std.ArrayListUnmanaged(topo.DirectedEdge) = .empty;
    defer edges_a.deinit(allocator);
    var edges_b: std.ArrayListUnmanaged(topo.DirectedEdge) = .empty;
    defer edges_b.deinit(allocator);

    var current_loop = &edges_a;
    var found_v1 = false;
    var found_v2 = false;

    for (0..orig_wire.edges_len) |i| {
        const d_edge = t_arena.wire_edges.items[orig_wire.edges_start + i];
        const edge = t_arena.edges.items[d_edge.edge];

        // Check if this edge emits from one of our split points
        const start_v = if (d_edge.forward) edge.front else edge.back;

        if (start_v == v1_id) {
            found_v1 = true;
            current_loop = &edges_b; // Switch accumulation to Loop B
        } else if (start_v == v2_id) {
            found_v2 = true;
            current_loop = &edges_a; // Switch accumulation back to Loop A
        }

        try current_loop.append(allocator, d_edge);
    }

    if (!found_v1 or !found_v2) return error.InvalidFace; // Vertices weren't on the boundary!

    // 3. Close both loops with the new split edge
    // Loop A needs the edge going from v2 -> v1 (backward)
    try edges_a.append(allocator, .{ .edge = split_edge_id, .forward = false });
    // Loop B needs the edge going from v1 -> v2 (forward)
    try edges_b.append(allocator, .{ .edge = split_edge_id, .forward = true });

    // 4. Construct the new Wires in the arena
    const w_a_start: u32 = @intCast(t_arena.wire_edges.items.len);
    try t_arena.wire_edges.appendSlice(allocator, edges_a.items);

    // We overwrite the original wire to point to the new Loop A
    t_arena.wires.items[orig_wire_id].edges_start = w_a_start;
    t_arena.wires.items[orig_wire_id].edges_len = @intCast(edges_a.items.len);

    const w_b_start: u32 = @intCast(t_arena.wire_edges.items.len);
    try t_arena.wire_edges.appendSlice(allocator, edges_b.items);

    const new_wire_id: u32 = @intCast(t_arena.wires.items.len);
    try t_arena.wires.append(allocator, .{ .edges_start = w_b_start, .edges_len = @intCast(edges_b.items.len) });

    // 5. Construct the new Sub-Face (Loop B)
    const new_f_wires_start: u32 = @intCast(t_arena.face_wires.items.len);
    try t_arena.face_wires.append(allocator, new_wire_id);

    const new_face_id: u32 = @intCast(t_arena.faces.items.len);
    try t_arena.faces.append(allocator, .{
        .surface = orig_face.surface, // Both faces share the same geometric plane!
        .forward = orig_face.forward,
        .wires_start = new_f_wires_start,
        .wires_len = 1,
    });

    return new_face_id;
}

/// Computes the intersection distance (t) between a Ray and a Plane.
/// Returns null if parallel or if the intersection is behind the ray origin.
fn rayIntersectPlane(
    ray_origin: math.Vec3,
    ray_dir: math.Vec3,
    plane_origin: math.Vec3,
    plane_normal: math.Vec3,
) ?f64 {
    const denom = math.dot(ray_dir, plane_normal);

    // If denominator is near zero, ray is parallel to the plane
    if (@abs(denom) < math.MATH_EPSILON) return null;

    const p0l0 = math.sub(plane_origin, ray_origin);
    const t = math.dot(p0l0, plane_normal) / denom;

    // Only return positive hits (in front of the ray)
    if (t > math.MATH_EPSILON) {
        return t;
    }
    return null;
}

/// Determines if a 3D point is strictly inside a Solid using the Even-Odd Raycast rule.
pub fn isPointInsideSolid(
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    solid_id: topo.SolidId,
    pt: math.Vec3,
) bool {
    const ray_dir = math.Vec3{ 1.0, 0.0, 0.0 }; // Cast ray along +X axis
    var hit_count: u32 = 0;

    const solid = t_arena.solids.items[solid_id];

    for (0..solid.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
            const face = t_arena.faces.items[face_id];

            // For now, assume all faces are planes
            if (face.surface.surface_type != .plane) continue;
            const plane = g_arena.planes.items[face.surface.index];
            const normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));

            if (rayIntersectPlane(pt, ray_dir, plane.origin, normal)) |t| {
                const hit_pt = math.add(pt, math.scale(ray_dir, t));

                // --- Point-in-Polygon Check (Simplified Bounding Box for Skeleton) ---
                // In a production kernel, we project hit_pt into the 2D UV space of the plane
                // and run a 2D winding number check against the face's wires.
                // For this DOD skeleton, we do a quick AABB bounds check on the face's vertices.
                var min_b = math.Vec3{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
                var max_b = math.Vec3{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };

                for (0..face.wires_len) |w_off| {
                    const wire = t_arena.wires.items[t_arena.face_wires.items[face.wires_start + w_off]];
                    for (0..wire.edges_len) |e_off| {
                        const edge = t_arena.edges.items[t_arena.wire_edges.items[wire.edges_start + e_off].edge];
                        for ([_]topo.VertexId{ edge.front, edge.back }) |v_id| {
                            const v_pt = t_arena.vertices.items[v_id].point;
                            min_b[0] = @min(min_b[0], v_pt[0]);
                            min_b[1] = @min(min_b[1], v_pt[1]);
                            min_b[2] = @min(min_b[2], v_pt[2]);
                            max_b[0] = @max(max_b[0], v_pt[0]);
                            max_b[1] = @max(max_b[1], v_pt[1]);
                            max_b[2] = @max(max_b[2], v_pt[2]);
                        }
                    }
                }

                // Add slight epsilon padding to AABB for robustness
                const eps = 1e-4;
                if (hit_pt[0] >= min_b[0] - eps and hit_pt[0] <= max_b[0] + eps and
                    hit_pt[1] >= min_b[1] - eps and hit_pt[1] <= max_b[1] + eps and
                    hit_pt[2] >= min_b[2] - eps and hit_pt[2] <= max_b[2] + eps)
                {
                    hit_count += 1;
                }
            }
        }
    }

    return (hit_count % 2) != 0;
}

/// The Holy Grail: Computes the Boolean CSG operation between two solids.
pub fn computeBoolean(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_a: topo.SolidId,
    solid_b: topo.SolidId,
    op: BooleanOp,
    config: anytype,
) BooleanError!topo.SolidId {
    _ = config;

    // 1. & 2. Intersection and Splitting
    // This generates the raw pool of faces we will select from.
    const split_result = splitIntersectingFaces(allocator, t_arena, g_arena, solid_a, solid_b) catch return error.OutOfMemory;
    _ = split_result;

    var selected_faces: std.ArrayListUnmanaged(topo.FaceId) = .empty;
    defer selected_faces.deinit(allocator);

    // Note: To make this function compile and testable immediately,
    // we will iterate over the original faces of A and B,
    // pretending they were returned by the `splitIntersectingFaces` step.

    // --- Phase 3 & 4: Classification and Selection ---

    // Process Solid A's Faces
    const sa = t_arena.solids.items[solid_a];
    for (0..sa.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[sa.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];

            const class = classifyFace(allocator, t_arena, g_arena, face_id, solid_b);

            const keep = switch (op) {
                .union_op => class == .outside or class == .same,
                .difference => class == .outside or class == .opposite,
                .intersection => class == .inside or class == .same,
            };

            if (keep) {
                try selected_faces.append(allocator, face_id);
            }
        }
    }

    // Process Solid B's Faces
    const sb = t_arena.solids.items[solid_b];
    for (0..sb.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[sb.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];

            const class = classifyFace(allocator, t_arena, g_arena, face_id, solid_a);

            const keep = switch (op) {
                .union_op => class == .outside,
                .difference => class == .inside, // Note: We would also need to flip the normal here!
                .intersection => class == .inside,
            };

            if (keep) {
                // For Difference, B's faces must be inverted so the normals face outward from the void.
                if (op == .difference) {
                    var flipped_face = t_arena.faces.items[face_id];
                    flipped_face.forward = !flipped_face.forward;

                    const new_face_id: u32 = @intCast(t_arena.faces.items.len);
                    try t_arena.faces.append(allocator, flipped_face);
                    try selected_faces.append(allocator, new_face_id);
                } else {
                    try selected_faces.append(allocator, face_id);
                }
            }
        }
    }

    // --- Phase 5: Re-assembly ---
    // Package the selected faces into a brand new Solid

    const shell_start: u32 = @intCast(t_arena.shells.items.len);
    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);

    try t_arena.shell_faces.appendSlice(allocator, selected_faces.items);
    try t_arena.shells.append(allocator, .{
        .faces_start = sh_faces_start,
        .faces_len = @intCast(selected_faces.items.len),
    });

    const new_solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);

    try t_arena.solid_shells.append(allocator, shell_start);
    try t_arena.solids.append(allocator, .{
        .shells_start = so_shells_start,
        .shells_len = 1,
    });

    return new_solid_id;
}
