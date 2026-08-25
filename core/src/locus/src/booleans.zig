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
/// (This will eventually use Raycasting + Winding numbers).
fn classifyFace(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    face_id: topo.FaceId,
    target_solid_id: topo.SolidId,
) FaceClassification {
    _ = allocator;
    _ = t_arena;
    _ = g_arena;
    _ = face_id;
    _ = target_solid_id;
    // STUB: Defaulting to outside so the compiler passes.
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

/// Splits a single topological edge at a given 3D point.
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

    // Note: To fully apply this split, we would now scan `t_arena.wire_edges`
    // for `orig_edge` and replace it with `e1_id` and `e2_id`.

    return .{ .v_mid = v_mid_id, .e1 = e1_id, .e2 = e2_id };
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
