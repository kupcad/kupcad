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
    const face_a = t_arena.faces.items[t_arena.loops.items[he.loop_id].face_id];
    const face_b = t_arena.faces.items[t_arena.loops.items[twin.loop_id].face_id];

    // 1. Generate the Surface and calculate Offset (d)
    const surf_idx = try createConstantFilletSurface(allocator, t_arena, g_arena, he_id, radius);

    const plane_a = g_arena.planes.items[face_a.surface.index];
    var n_a = math.normalize(math.cross(plane_a.u_axis, plane_a.v_axis));
    if (!face_a.forward) n_a = math.scale(n_a, -1.0);

    const plane_b = g_arena.planes.items[face_b.surface.index];
    var n_b = math.normalize(math.cross(plane_b.u_axis, plane_b.v_axis));
    if (!face_b.forward) n_b = math.scale(n_b, -1.0);

    const cos_theta = std.math.clamp(math.dot(n_a, n_b), -1.0, 1.0);
    const d = radius * @tan(std.math.acos(cos_theta) / 2.0);

    // 2. Compute 3D Tangency Segments
    const p_start = t_arena.vertices.items[he.start_vertex].point;
    const p_end = t_arena.vertices.items[twin.start_vertex].point;
    const tangent = math.normalize(math.sub(p_end, p_start));

    const v_a = math.normalize(math.cross(n_a, tangent));
    const v_b = math.normalize(math.cross(tangent, n_b));

    const seg_a = types.Segment3D{
        .start = math.add(p_start, math.scale(v_a, d)),
        .end = math.add(p_end, math.scale(v_a, d)),
    };

    const seg_b = types.Segment3D{
        .start = math.add(p_start, math.scale(v_b, d)),
        .end = math.add(p_end, math.scale(v_b, d)),
    };

    // 3. Slice Adjacent Faces (Phase 6.2 scaffold - Trimming)
    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    const new_fa = try modifiers.sliceFaceWithSegment(allocator, t_arena, g_arena, t_arena.loops.items[he.loop_id].face_id, seg_a, tol);
    const new_fb = try modifiers.sliceFaceWithSegment(allocator, t_arena, g_arena, t_arena.loops.items[twin.loop_id].face_id, seg_b, tol);
    _ = new_fa;
    _ = new_fb;

    // 4. Allocate the Fillet Face
    const fillet_face_id: u32 = @intCast(t_arena.faces.items.len);
    try t_arena.faces.append(allocator, .{
        .surface = .{ .index = @intCast(surf_idx), .surface_type = .nurbs },
        .forward = true,
        .loops_start = 0, // Pending cross-edge loop generation
        .loops_len = 0,
    });

    return .{ .fillet_face = fillet_face_id, .new_solid = solid_id };
}
