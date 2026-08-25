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

/// Splits the faces of both solids along their intersection curves.
/// Returns a list of the newly generated sub-faces for each solid.
fn splitIntersectingFaces(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_a: topo.SolidId,
    solid_b: topo.SolidId,
) !struct { faces_a: []topo.FaceId, faces_b: []topo.FaceId } {
    _ = allocator;
    _ = t_arena;
    _ = g_arena;
    _ = solid_a;
    _ = solid_b;
    // STUB: In a real implementation, this loops through A's faces and B's faces,
    // runs `marchIntersection`, and splits the topology.
    // For now, we return empty arrays to satisfy the pipeline structure.
    return .{ .faces_a = &[_]topo.FaceId{}, .faces_b = &[_]topo.FaceId{} };
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
