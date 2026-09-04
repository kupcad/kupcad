const std = @import("std");
const topo = @import("../topology.zig");
const geom = @import("../geometry.zig");
const math = @import("../math.zig");
const sweeps = @import("../sweeps.zig");
const modifiers = @import("modifiers.zig");
const types = @import("types.zig");

pub const BlendResult = struct {
    fillet_face: topo.FaceId,
    new_solid: topo.SolidId,
};

pub const BlendError = error{
    OutOfMemory,
    NonPlanarAdjacentFaces,
    DegenerateEdge,
    TopologyCorrupted,
};

/// Identifies the parent face of a given half-edge.
fn getFaceContainingHalfEdge(t_arena: *const topo.TopologyArena, he_id: topo.HalfEdgeId) topo.FaceId {
    return t_arena.loops.items[t_arena.half_edges.items[he_id].loop_id].face_id;
}

/// Rebuilds the solid's shell boundary list, dropping old faces and appending new ones.
fn replaceShellFaces(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    solid_id: topo.SolidId,
    remove_faces: []const topo.FaceId,
    add_faces: []const topo.FaceId,
) !void {
    const solid = t_arena.solids.items[solid_id];
    const shell_id = t_arena.solid_shells.items[solid.shells_start]; // Assuming single-shell body for now
    var shell = &t_arena.shells.items[shell_id];

    var updated_faces = std.ArrayListUnmanaged(topo.FaceId).empty;
    defer updated_faces.deinit(allocator);

    // Keep faces that are NOT in the remove list
    for (0..shell.faces_len) |f_off| {
        const f_id = t_arena.shell_faces.items[shell.faces_start + f_off];
        var keep = true;
        for (remove_faces) |r_id| {
            if (f_id == r_id) {
                keep = false;
                break;
            }
        }
        if (keep) try updated_faces.append(allocator, f_id);
    }

    // Append the newly created faces (the fillet)
    try updated_faces.appendSlice(allocator, add_faces);

    // Reallocate the shell's face span
    const new_start: u32 = @intCast(t_arena.shell_faces.items.len);
    try t_arena.shell_faces.appendSlice(allocator, updated_faces.items);

    shell.faces_start = new_start;
    shell.faces_len = @intCast(updated_faces.items.len);
}

/// Generates a constant-radius NURBS fillet surface along a given half-edge.
/// Currently evaluates planar adjacent faces to calculate precise dihedral tangency lines.
pub fn createConstantFilletSurface(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    he_id: topo.HalfEdgeId,
    radius: f64,
) BlendError!u32 {
    const he = t_arena.half_edges.items[he_id];
    if (he.twin == topo.NULL_ID) return error.DegenerateEdge;

    const twin = t_arena.half_edges.items[he.twin];

    const face_a = t_arena.faces.items[t_arena.loops.items[he.loop_id].face_id];
    const face_b = t_arena.faces.items[t_arena.loops.items[twin.loop_id].face_id];

    if (face_a.surface.surface_type != .plane or face_b.surface.surface_type != .plane) {
        return error.NonPlanarAdjacentFaces;
    }

    // 1. Extract Outward Face Normals
    const plane_a = g_arena.planes.items[face_a.surface.index];
    var n_a = math.normalize(math.cross(plane_a.u_axis, plane_a.v_axis));
    if (!face_a.forward) n_a = math.scale(n_a, -1.0);

    const plane_b = g_arena.planes.items[face_b.surface.index];
    var n_b = math.normalize(math.cross(plane_b.u_axis, plane_b.v_axis));
    if (!face_b.forward) n_b = math.scale(n_b, -1.0);

    // 2. Compute Edge Tangent (T) and Inward Face Vectors (vA, vB)
    const p_start = t_arena.vertices.items[he.start_vertex].point;
    const p_end = t_arena.vertices.items[twin.start_vertex].point;
    const tangent = math.normalize(math.sub(p_end, p_start));

    const v_a = math.normalize(math.cross(n_a, tangent)); // Points inward across Face A
    const v_b = math.normalize(math.cross(tangent, n_b)); // Points inward across Face B

    // 3. Compute Dihedral Offset Distance (d)
    const cos_theta = std.math.clamp(math.dot(n_a, n_b), -1.0, 1.0);
    const theta = std.math.acos(cos_theta);
    const d = radius * @tan(theta / 2.0);

    // 4. Calculate 3D Tangency Points at the Start of the Edge
    const pt_a = math.add(p_start, math.scale(v_a, d));
    const pt_b = math.add(p_start, math.scale(v_b, d));

    // 5. Project 3D Control Points into the Local 2D RMF Space
    const frames = try sweeps.generateRMF(allocator, g_arena, he.curve, 2);
    defer allocator.free(frames);
    const f0 = frames[0];

    // Local 2D coordinates: (X = Normal projection, Y = Binormal projection)
    const local_a = math.Vec2{ math.dot(math.sub(pt_a, f0.origin), f0.normal), math.dot(math.sub(pt_a, f0.origin), f0.binormal) };
    const local_corner = math.Vec2{ 0.0, 0.0 }; // P_start matches f0.origin perfectly
    const local_b = math.Vec2{ math.dot(math.sub(pt_b, f0.origin), f0.normal), math.dot(math.sub(pt_b, f0.origin), f0.binormal) };

    // 6. Construct Exact 2D NURBS Circular Arc
    const weight_mid = @cos(theta / 2.0);
    var arc_cps = [_]math.Vec4{
        .{ local_a[0], local_a[1], 0.0, 1.0 },
        .{ local_corner[0] * weight_mid, local_corner[1] * weight_mid, 0.0, weight_mid },
        .{ local_b[0], local_b[1], 0.0, 1.0 },
    };
    var arc_knots = [_]f64{ 0.0, 0.0, 0.0, 1.0, 1.0, 1.0 };

    const arc_profile = geom.NurbsCurve{
        .degree = 2,
        .knots = &arc_knots,
        .control_points = &arc_cps,
    };

    // 7. Loft the Profile along the Rail using the RMF
    const samples = 16;
    return sweeps.sweepProfileAlongCurve(allocator, g_arena, arc_profile, he.curve, samples);
}

/// Performs topological surgery to replace a sharp half-edge with a G1 continuous NURBS fillet.
pub fn applyEdgeBlend(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    he_id: topo.HalfEdgeId,
    radius: f64,
) BlendError!BlendResult {
    const he = t_arena.half_edges.items[he_id];
    if (he.twin == topo.NULL_ID) return error.DegenerateEdge;

    const twin = t_arena.half_edges.items[he.twin];
    const face_a_id = t_arena.loops.items[he.loop_id].face_id;
    const face_b_id = t_arena.loops.items[twin.loop_id].face_id;
    const face_a = t_arena.faces.items[face_a_id];
    const face_b = t_arena.faces.items[face_b_id];

    const surf_idx = try createConstantFilletSurface(allocator, t_arena, g_arena, he_id, radius);

    const plane_a = g_arena.planes.items[face_a.surface.index];
    var n_a = math.normalize(math.cross(plane_a.u_axis, plane_a.v_axis));
    if (!face_a.forward) n_a = math.scale(n_a, -1.0);

    const plane_b = g_arena.planes.items[face_b.surface.index];
    var n_b = math.normalize(math.cross(plane_b.u_axis, plane_b.v_axis));
    if (!face_b.forward) n_b = math.scale(n_b, -1.0);

    const cos_theta = std.math.clamp(math.dot(n_a, n_b), -1.0, 1.0);
    const d = radius * @tan(std.math.acos(cos_theta) / 2.0);

    const p_start = t_arena.vertices.items[he.start_vertex].point;
    const p_end = t_arena.vertices.items[twin.start_vertex].point;
    const tangent = math.normalize(math.sub(p_end, p_start));

    const v_a = math.normalize(math.cross(n_a, tangent));
    const v_b = math.normalize(math.cross(tangent, n_b));

    // Phase 6 Fix: Align segments to natural face boundaries
    const seg_a = types.Segment3D{
        .start = math.add(p_start, math.scale(v_a, d)),
        .end = math.add(p_end, math.scale(v_a, d)),
    };

    const seg_b = types.Segment3D{
        .start = math.add(p_end, math.scale(v_b, d)), // Reverse winding to match Face B twin
        .end = math.add(p_start, math.scale(v_b, d)),
    };

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    const new_fa = (try modifiers.sliceFaceWithSegment(allocator, t_arena, g_arena, face_a_id, seg_a, tol)) orelse return error.TopologyCorrupted;
    const new_fb = (try modifiers.sliceFaceWithSegment(allocator, t_arena, g_arena, face_b_id, seg_b, tol)) orelse return error.TopologyCorrupted;

    const fillet_face_id: u32 = @intCast(t_arena.faces.items.len);
    try t_arena.faces.append(allocator, .{
        .surface = .{ .index = @intCast(surf_idx), .surface_type = .nurbs },
        .forward = true,
        .loops_start = 0,
        .loops_len = 0,
    });

    const rail_a = findSharedHalfEdge(t_arena, face_a_id, new_fa) orelse return error.TopologyCorrupted;
    const rail_b = findSharedHalfEdge(t_arena, face_b_id, new_fb) orelse return error.TopologyCorrupted;

    const caps = try weaveFilletTopology(allocator, t_arena, g_arena, fillet_face_id, rail_a, rail_b);

    const v_corner_start = t_arena.half_edges.items[he_id].start_vertex;
    const v_corner_end = twin.start_vertex;

    const cap_array = [_]topo.HalfEdgeId{ caps.cap_start, caps.cap_end };

    try modifiers.trimOrthogonalCap(allocator, t_arena, solid_id, v_corner_start, cap_array);
    try modifiers.trimOrthogonalCap(allocator, t_arena, solid_id, v_corner_end, cap_array);

    try replaceShellFaces(allocator, t_arena, solid_id, &[_]topo.FaceId{}, &[_]topo.FaceId{fillet_face_id});

    return .{ .fillet_face = fillet_face_id, .new_solid = solid_id };
}

/// Crawls two faces to find their shared topological half-edge.
fn findSharedHalfEdge(
    t_arena: *const topo.TopologyArena,
    face_a: topo.FaceId,
    face_b: topo.FaceId,
) ?topo.HalfEdgeId {
    const f_a = t_arena.faces.items[face_a];

    for (0..f_a.loops_len) |l_off| {
        const loop = t_arena.loops.items[t_arena.face_loops.items[f_a.loops_start + l_off]];
        var curr = loop.first_half_edge;

        var safety: usize = 0;
        while (true) : (safety += 1) {
            if (safety > 10_000) return null;

            const he = t_arena.half_edges.items[curr];
            if (he.twin != topo.NULL_ID) {
                const twin_he = t_arena.half_edges.items[he.twin];
                const twin_face = t_arena.loops.items[twin_he.loop_id].face_id;
                if (twin_face == face_b) return curr;
            }

            curr = he.next;
            if (curr == loop.first_half_edge) break;
        }
    }
    return null;
}

/// Constructs the final 4-sided boundary loop for the fillet face.
fn weaveFilletTopology(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    fillet_face: topo.FaceId,
    rail_a: topo.HalfEdgeId,
    rail_b: topo.HalfEdgeId,
) !struct { cap_start: topo.HalfEdgeId, cap_end: topo.HalfEdgeId } {
    const he_a = t_arena.half_edges.items[rail_a];
    const he_b = t_arena.half_edges.items[rail_b];

    const v_a_start = he_a.start_vertex;
    const v_a_end = t_arena.half_edges.items[he_a.next].start_vertex;

    const v_b_start = he_b.start_vertex;
    const v_b_end = t_arena.half_edges.items[he_b.next].start_vertex;

    // Cap Start (connects Face A offset to Face B offset at p_start)
    const cap_start_idx: u24 = @intCast(g_arena.lines.items.len);
    try g_arena.lines.append(allocator, .{
        .start = t_arena.vertices.items[v_a_start].point,
        .end = t_arena.vertices.items[v_b_end].point,
    });

    // Cap End (connects Face B offset to Face A offset at p_end)
    const cap_end_idx: u24 = @intCast(g_arena.lines.items.len);
    try g_arena.lines.append(allocator, .{
        .start = t_arena.vertices.items[v_b_start].point,
        .end = t_arena.vertices.items[v_a_end].point,
    });

    const loop_id: u32 = @intCast(t_arena.loops.items.len);
    const start_he: u32 = @intCast(t_arena.half_edges.items.len);

    // 0: Rail A Twin
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_a_end,
        .twin = rail_a,
        .next = start_he + 1,
        .prev = start_he + 3,
        .loop_id = loop_id,
        .curve = he_a.curve,
        .forward = !he_a.forward,
    });
    t_arena.half_edges.items[rail_a].twin = start_he;

    // 1: Cap Start
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_a_start,
        .twin = topo.NULL_ID,
        .next = start_he + 2,
        .prev = start_he,
        .loop_id = loop_id,
        .curve = .{ .index = cap_start_idx, .curve_type = .line },
        .forward = true,
    });

    // 2: Rail B Twin
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_b_end,
        .twin = rail_b,
        .next = start_he + 3,
        .prev = start_he + 1,
        .loop_id = loop_id,
        .curve = he_b.curve,
        .forward = !he_b.forward,
    });
    t_arena.half_edges.items[rail_b].twin = start_he + 2;

    // 3: Cap End
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_b_start,
        .twin = topo.NULL_ID,
        .next = start_he,
        .prev = start_he + 2,
        .loop_id = loop_id,
        .curve = .{ .index = cap_end_idx, .curve_type = .line },
        .forward = true,
    });

    // Register loop
    try t_arena.loops.append(allocator, .{ .face_id = fillet_face, .first_half_edge = start_he });
    const fl_start: u32 = @intCast(t_arena.face_loops.items.len);
    try t_arena.face_loops.append(allocator, loop_id);

    t_arena.faces.items[fillet_face].loops_start = fl_start;
    t_arena.faces.items[fillet_face].loops_len = 1;

    return .{ .cap_start = start_he + 1, .cap_end = start_he + 3 };
}
