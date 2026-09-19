const std = @import("std");
const types = @import("types.zig");
const geom_types = @import("../geometry/types.zig");
const topo_arena = @import("arena.zig");

pub const EulerError = error{
    OutOfMemory,
    VerticesNotInSameLoop,
    NonManifoldEdge,
    InvalidHalfEdge,
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
    he_a_prev: types.HalfEdgeIndex, // Half-edge ending at v_a
    he_b_prev: types.HalfEdgeIndex, // Half-edge ending at v_b
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
