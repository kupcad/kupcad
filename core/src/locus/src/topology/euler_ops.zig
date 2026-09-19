const std = @import("std");
const types = @import("types.zig");
const geom_types = @import("../geometry/types.zig");
const topo_arena = @import("arena.zig");

pub const EulerError = error{
    OutOfMemory,
    VerticesNotInSameLoop,
    NonManifoldEdge,
    InvalidHalfEdge,
    InvalidLoopStructure,
};

pub const MevResult = struct {
    new_vertex: types.VertexIndex,
    he_out: types.HalfEdgeIndex,
    he_in: types.HalfEdgeIndex,
};

pub const MefResult = struct {
    new_face: types.FaceIndex,
    new_loop: types.LoopIndex,
    he_a: types.HalfEdgeIndex,
    he_b: types.HalfEdgeIndex,
};

pub const KemrResult = struct {
    new_loop: types.LoopIndex,
};

/// MEV (Make Edge, Vertex): Attaches a new vertex and double half-edge at v_start.
pub fn mev(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    v_start: types.VertexIndex,
    point_idx: geom_types.PointIndex,
    curve_id: geom_types.CurveId,
    target_loop: types.LoopIndex,
) EulerError!MevResult {
    const new_v_idx = @as(types.VertexIndex, @enumFromInt(@as(u32, @intCast(t_arena.vertices.items.len))));
    try t_arena.vertices.append(allocator, .{ .point = point_idx });

    const he_out_idx = @as(types.HalfEdgeIndex, @enumFromInt(@as(u32, @intCast(t_arena.half_edges.items.len))));
    const he_in_idx = @as(types.HalfEdgeIndex, @enumFromInt(@as(u32, @intCast(t_arena.half_edges.items.len + 1))));

    // HE Out: v_start -> new_v
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_start,
        .twin = he_in_idx,
        .next = he_in_idx,
        .prev = types.NULL_HALF_EDGE,
        .loop_id = target_loop,
        .curve = curve_id,
        .forward = true,
    });

    // HE In: new_v -> v_start
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = new_v_idx,
        .twin = he_out_idx,
        .next = types.NULL_HALF_EDGE,
        .prev = he_out_idx,
        .loop_id = target_loop,
        .curve = curve_id,
        .forward = false,
    });

    return MevResult{
        .new_vertex = new_v_idx,
        .he_out = he_out_idx,
        .he_in = he_in_idx,
    };
}

/// MEF (Make Edge, Face): Connects v_a and v_b in target_loop, splitting it into two faces.
pub fn mef(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    target_loop: types.LoopIndex,
    he_a_prev: types.HalfEdgeIndex,
    he_b_prev: types.HalfEdgeIndex,
    curve_id: geom_types.CurveId,
    surface_id: geom_types.SurfaceId,
) EulerError!MefResult {
    const parent_face_idx = t_arena.loops.items[@intFromEnum(target_loop)].face_id;

    const new_face_idx = @as(types.FaceIndex, @enumFromInt(@as(u32, @intCast(t_arena.faces.items.len))));
    const new_loop_idx = @as(types.LoopIndex, @enumFromInt(@as(u32, @intCast(t_arena.loops.items.len))));

    const he_a_idx = @as(types.HalfEdgeIndex, @enumFromInt(@as(u32, @intCast(t_arena.half_edges.items.len))));
    const he_b_idx = @as(types.HalfEdgeIndex, @enumFromInt(@as(u32, @intCast(t_arena.half_edges.items.len + 1))));

    const v_a = t_arena.half_edges.items[@intFromEnum(he_a_prev)].targetVertex(t_arena);
    const v_b = t_arena.half_edges.items[@intFromEnum(he_b_prev)].targetVertex(t_arena);

    const he_a_next_old = t_arena.half_edges.items[@intFromEnum(he_a_prev)].next;
    const he_b_next_old = t_arena.half_edges.items[@intFromEnum(he_b_prev)].next;

    // Insert HE A: v_a -> v_b
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_a,
        .twin = he_b_idx,
        .next = he_b_next_old,
        .prev = he_a_prev,
        .loop_id = new_loop_idx,
        .curve = curve_id,
        .forward = true,
    });

    // Insert HE B: v_b -> v_a
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_b,
        .twin = he_a_idx,
        .next = he_a_next_old,
        .prev = he_b_prev,
        .loop_id = target_loop,
        .curve = curve_id,
        .forward = false,
    });

    // Re-link previous half-edges
    t_arena.half_edges.items[@intFromEnum(he_a_prev)].next = he_a_idx;
    t_arena.half_edges.items[@intFromEnum(he_b_prev)].next = he_b_idx;

    // Create new Loop and Face
    try t_arena.loops.append(allocator, .{
        .face_id = new_face_idx,
        .first_half_edge = he_a_idx,
    });

    const fl_start = @as(u32, @intCast(t_arena.face_loops.items.len));
    try t_arena.face_loops.append(allocator, new_loop_idx);

    try t_arena.faces.append(allocator, .{
        .surface = surface_id,
        .forward = true,
        .loops_start = fl_start,
        .loops_len = 1,
    });

    // Update loop_id for all half-edges swept into the new face
    var curr = he_a_next_old;
    while (curr != he_b_idx) {
        const he_ptr = &t_arena.half_edges.items[@intFromEnum(curr)];
        he_ptr.loop_id = new_loop_idx;
        curr = he_ptr.next;
    }

    _ = parent_face_idx;
    return MefResult{
        .new_face = new_face_idx,
        .new_loop = new_loop_idx,
        .he_a = he_a_idx,
        .he_b = he_b_idx,
    };
}

/// KEF (Kill Edge, Face): Inverse of MEF. Collapses a dividing boundary edge (he_ab & twin),
/// merging face_b into face_a.
pub fn kef(
    t_arena: *topo_arena.TopologyArena,
    he_ab_idx: types.HalfEdgeIndex,
) EulerError!types.FaceIndex {
    const he_ab = t_arena.half_edges.items[@intFromEnum(he_ab_idx)];
    const he_ba_idx = he_ab.twin;
    if (he_ba_idx == types.NULL_HALF_EDGE) return error.NonManifoldEdge;
    const he_ba = t_arena.half_edges.items[@intFromEnum(he_ba_idx)];

    const loop_a_idx = he_ab.loop_id;
    const loop_b_idx = he_ba.loop_id;
    if (loop_a_idx == loop_b_idx) return error.InvalidLoopStructure;

    const face_a_idx = t_arena.loops.items[@intFromEnum(loop_a_idx)].face_id;

    // Unlink he_ab and he_ba from their loops
    const ab_prev = he_ab.prev;
    const ab_next = he_ab.next;
    const ba_prev = he_ba.prev;
    const ba_next = he_ba.next;

    t_arena.half_edges.items[@intFromEnum(ab_prev)].next = ba_next;
    t_arena.half_edges.items[@intFromEnum(ba_next)].prev = ab_prev;

    t_arena.half_edges.items[@intFromEnum(ba_prev)].next = ab_next;
    t_arena.half_edges.items[@intFromEnum(ab_next)].prev = ba_prev;

    // Point loop_a's first_half_edge to a surviving edge
    t_arena.loops.items[@intFromEnum(loop_a_idx)].first_half_edge = ab_next;

    // Reassign all half-edges from loop_b to loop_a
    var curr = ba_next;
    while (curr != ab_next) {
        const he_ptr = &t_arena.half_edges.items[@intFromEnum(curr)];
        he_ptr.loop_id = loop_a_idx;
        curr = he_ptr.next;
    }

    return face_a_idx;
}

/// KEV (Kill Edge, Vertex): Inverse of MEV. Collapses a dead-end edge pair (he_out & he_in)
/// terminating at a valence-1 vertex.
pub fn kev(
    t_arena: *topo_arena.TopologyArena,
    he_out_idx: types.HalfEdgeIndex,
) EulerError!void {
    const he_out = t_arena.half_edges.items[@intFromEnum(he_out_idx)];
    const he_in_idx = he_out.twin;
    if (he_in_idx == types.NULL_HALF_EDGE) return error.NonManifoldEdge;

    const he_in = t_arena.half_edges.items[@intFromEnum(he_in_idx)];
    const loop_idx = he_out.loop_id;

    const prev_he_idx = he_out.prev;
    const next_he_idx = he_in.next;

    // Re-link around the collapsed edge pair
    if (prev_he_idx != types.NULL_HALF_EDGE) {
        t_arena.half_edges.items[@intFromEnum(prev_he_idx)].next = next_he_idx;
    }
    if (next_he_idx != types.NULL_HALF_EDGE) {
        t_arena.half_edges.items[@intFromEnum(next_he_idx)].prev = prev_he_idx;
    }

    // Update loop starting edge if it pointed to a killed edge
    const loop_ptr = &t_arena.loops.items[@intFromEnum(loop_idx)];
    if (loop_ptr.first_half_edge == he_out_idx or loop_ptr.first_half_edge == he_in_idx) {
        loop_ptr.first_half_edge = next_he_idx;
    }
}

/// KEMR (Kill Edge, Make Ring/Loop): Removes a bridge edge (he_a & twin he_b)
/// that connects an outer loop to an inner hole, creating a distinct inner ring/hole loop.
pub fn kemr(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    he_a_idx: types.HalfEdgeIndex,
) EulerError!KemrResult {
    const he_a = t_arena.half_edges.items[@intFromEnum(he_a_idx)];
    const he_b_idx = he_a.twin;
    if (he_b_idx == types.NULL_HALF_EDGE) return error.NonManifoldEdge;
    const he_b = t_arena.half_edges.items[@intFromEnum(he_b_idx)];

    const orig_loop_idx = he_a.loop_id;
    const face_idx = t_arena.loops.items[@intFromEnum(orig_loop_idx)].face_id;

    const a_prev = he_a.prev;
    const a_next = he_a.next;
    const b_prev = he_b.prev;
    const b_next = he_b.next;

    // Unbridge the loop into two independent closed cycles
    t_arena.half_edges.items[@intFromEnum(a_prev)].next = b_next;
    t_arena.half_edges.items[@intFromEnum(b_next)].prev = a_prev;

    t_arena.half_edges.items[@intFromEnum(b_prev)].next = a_next;
    t_arena.half_edges.items[@intFromEnum(a_next)].prev = b_prev;

    // Instantiate new Loop for the inner ring
    const new_loop_idx = @as(types.LoopIndex, @enumFromInt(@as(u32, @intCast(t_arena.loops.items.len))));
    try t_arena.loops.append(allocator, .{
        .face_id = face_idx,
        .first_half_edge = a_next,
    });

    t_arena.loops.items[@intFromEnum(orig_loop_idx)].first_half_edge = b_next;

    // Reassign loop_id for the newly created ring cycle
    var curr = a_next;
    while (curr != b_prev) {
        const he_ptr = &t_arena.half_edges.items[@intFromEnum(curr)];
        he_ptr.loop_id = new_loop_idx;
        curr = he_ptr.next;
    }

    // Attach loop to parent face
    try t_arena.face_loops.append(allocator, new_loop_idx);
    t_arena.faces.items[@intFromEnum(face_idx)].loops_len += 1;

    return KemrResult{ .new_loop = new_loop_idx };
}
