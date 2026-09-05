const std = @import("std");
const topo = @import("../topology.zig");
const geom = @import("../geometry.zig");
const math = @import("../math.zig");

pub const HealingConfig = struct {
    mute_errors: bool = false,
};

fn getFace(t: *const topo.TopologyArena, he_id: topo.HalfEdgeId) topo.FaceId {
    return t.loops.items[t.half_edges.items[he_id].loop_id].face_id;
}

// Backwards compatible default wrapper
pub fn healSolid(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    tol: math.Tolerance,
) !void {
    try healSolidEx(allocator, t_arena, g_arena, solid_id, tol, .{});
}

// Extended configurable endpoint
pub fn healSolidEx(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    tol: math.Tolerance,
    config: HealingConfig,
) !void {
    const solid = t_arena.solids.items[solid_id];
    for (0..solid.shells_len) |s_off| {
        const shell_id = t_arena.solid_shells.items[solid.shells_start + s_off];
        try healShell(allocator, t_arena, g_arena, shell_id, tol, config);
    }
}

fn healShell(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    shell_id: topo.ShellId,
    tol: math.Tolerance,
    config: HealingConfig,
) !void {
    var shell = &t_arena.shells.items[shell_id];

    var shell_faces = std.ArrayListUnmanaged(topo.FaceId).empty;
    defer shell_faces.deinit(allocator);
    for (0..shell.faces_len) |f_off| {
        try shell_faces.append(allocator, t_arena.shell_faces.items[shell.faces_start + f_off]);
    }

    var visited = std.AutoHashMap(topo.FaceId, void).init(allocator);
    defer visited.deinit();

    var final_faces = std.ArrayListUnmanaged(topo.FaceId).empty;
    defer final_faces.deinit(allocator);

    for (shell_faces.items) |start_face_id| {
        if (visited.contains(start_face_id)) continue;

        const start_face = t_arena.faces.items[start_face_id];

        if (start_face.surface.surface_type != .plane or start_face.loops_len == 0) {
            try final_faces.append(allocator, start_face_id);
            try visited.put(start_face_id, {});
            continue;
        }

        var island = std.ArrayListUnmanaged(topo.FaceId).empty;
        defer island.deinit(allocator);

        var island_set = std.AutoHashMap(topo.FaceId, void).init(allocator);
        defer island_set.deinit();

        var queue = std.ArrayListUnmanaged(topo.FaceId).empty;
        defer queue.deinit(allocator);

        try queue.append(allocator, start_face_id);
        try visited.put(start_face_id, {});
        try island_set.put(start_face_id, {});
        try island.append(allocator, start_face_id);

        const plane_a = g_arena.planes.items[start_face.surface.index];
        var n_a = math.normalize(math.cross(plane_a.u_axis, plane_a.v_axis));
        if (!start_face.forward) n_a = math.scale(n_a, -1.0);

        while (queue.items.len > 0) {
            const curr_face_id = queue.items[queue.items.len - 1];
            queue.shrinkRetainingCapacity(queue.items.len - 1);

            const curr_face = t_arena.faces.items[curr_face_id];

            for (0..curr_face.loops_len) |l_off| {
                const loop_id = t_arena.face_loops.items[curr_face.loops_start + l_off];
                const loop = t_arena.loops.items[loop_id];
                var curr_he = loop.first_half_edge;
                var safety: usize = 0;

                while (true) : (safety += 1) {
                    if (safety > topo.MAX_EDGE_ITERS) return error.TopologyCorrupted;
                    const he = t_arena.half_edges.items[curr_he];

                    if (he.twin != topo.NULL_ID) {
                        const adj_face_id = getFace(t_arena, he.twin);
                        if (!visited.contains(adj_face_id)) {
                            const adj_face = t_arena.faces.items[adj_face_id];
                            if (adj_face.surface.surface_type == .plane and adj_face.loops_len > 0) {
                                const plane_b = g_arena.planes.items[adj_face.surface.index];
                                var n_b = math.normalize(math.cross(plane_b.u_axis, plane_b.v_axis));
                                if (!adj_face.forward) n_b = math.scale(n_b, -1.0);

                                if (math.dot(n_a, n_b) > 1.0 - tol.parametric) {
                                    const depth = math.dot(n_a, math.sub(plane_b.origin, plane_a.origin));
                                    if (@abs(depth) < tol.absolute * 10.0) {
                                        try queue.append(allocator, adj_face_id);
                                        try visited.put(adj_face_id, {});
                                        try island_set.put(adj_face_id, {});
                                        try island.append(allocator, adj_face_id);
                                    }
                                }
                            }
                        }
                    }
                    curr_he = he.next;
                    if (curr_he == loop.first_half_edge) break;
                }
            }
        }

        if (island.items.len == 1) {
            try final_faces.append(allocator, start_face_id);
            continue;
        }

        // Graceful Fallback: If floating-point errors from a Boolean cut produced an unclosed loop,
        // abort the coplanar merge for this island to protect the stability of the larger Solid.
        const new_face_id = extractIslandBoundary(allocator, t_arena, island.items, &island_set) catch |err| {
            if (!config.mute_errors) {
                std.log.warn("Healing aborted on Island {d}: {s}", .{ start_face_id, @errorName(err) });
            }
            try final_faces.appendSlice(allocator, island.items);
            continue;
        };

        try final_faces.append(allocator, new_face_id);
    }

    const new_start: u32 = @intCast(t_arena.shell_faces.items.len);
    try t_arena.shell_faces.appendSlice(allocator, final_faces.items);
    shell.faces_start = new_start;
    shell.faces_len = @intCast(final_faces.items.len);
}

fn isBoundaryEdge(t: *const topo.TopologyArena, he_id: topo.HalfEdgeId, island_set: *const std.AutoHashMap(topo.FaceId, void)) bool {
    const he = t.half_edges.items[he_id];
    if (he.twin == topo.NULL_ID) return true;
    const twin_face = getFace(t, he.twin);
    return !island_set.contains(twin_face);
}

pub fn extractIslandBoundary(
    allocator: std.mem.Allocator,
    t: *topo.TopologyArena,
    island: []const topo.FaceId,
    island_set: *const std.AutoHashMap(topo.FaceId, void),
) !topo.FaceId {
    var boundary_edges = std.ArrayListUnmanaged(topo.HalfEdgeId).empty;
    defer boundary_edges.deinit(allocator);

    var internal_seams = std.ArrayListUnmanaged(topo.HalfEdgeId).empty;
    defer internal_seams.deinit(allocator);

    var start_v_map = std.AutoHashMap(topo.VertexId, std.ArrayListUnmanaged(topo.HalfEdgeId)).init(allocator);
    defer {
        var it = start_v_map.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        start_v_map.deinit();
    }

    // 1. Isolate edge classification
    for (island) |f_id| {
        const face = t.faces.items[f_id];
        for (0..face.loops_len) |l_off| {
            const loop_id = t.face_loops.items[face.loops_start + l_off];
            const loop = t.loops.items[loop_id];
            var curr = loop.first_half_edge;
            var safety: usize = 0;
            while (true) : (safety += 1) {
                if (safety > topo.MAX_EDGE_ITERS) return error.TopologyCorrupted;

                if (isBoundaryEdge(t, curr, island_set)) {
                    try boundary_edges.append(allocator, curr);
                    const he = t.half_edges.items[curr];

                    var res = try start_v_map.getOrPut(he.start_vertex);
                    if (!res.found_existing) res.value_ptr.* = .empty;
                    try res.value_ptr.append(allocator, curr);
                } else {
                    try internal_seams.append(allocator, curr);
                }

                curr = t.half_edges.items[curr].next;
                if (curr == loop.first_half_edge) break;
            }
        }
    }

    var next_map = std.AutoHashMap(topo.HalfEdgeId, topo.HalfEdgeId).init(allocator);
    defer next_map.deinit();

    // 2. Map virtual connections
    for (boundary_edges.items) |he_id| {
        const he = t.half_edges.items[he_id];
        const end_v = t.half_edges.items[he.next].start_vertex;

        const list = start_v_map.getPtr(end_v) orelse return error.TopologyCorrupted;

        // Strict Manifold Invariant: A valid boundary loop must have exactly ONE
        // outgoing boundary edge per vertex. >1 is a Bowtie, 0 is a Dangling Tail.
        if (list.items.len != 1) return error.TopologyCorrupted;

        const next_bnd = list.items[0];
        try next_map.put(he_id, next_bnd);
    }

    // 3. TRANSACTIONAL VALIDATION PHASE (No mutations yet)
    var visited_bounds = std.AutoHashMap(topo.HalfEdgeId, void).init(allocator);
    defer visited_bounds.deinit();

    var temp_loops = std.ArrayListUnmanaged(topo.HalfEdgeId).empty;
    defer temp_loops.deinit(allocator);

    for (boundary_edges.items) |he_id| {
        if (visited_bounds.contains(he_id)) continue;
        try temp_loops.append(allocator, he_id);

        var curr = he_id;
        var safety: usize = 0;
        while (true) : (safety += 1) {
            if (safety > topo.MAX_EDGE_ITERS) return error.TopologyCorrupted;
            try visited_bounds.put(curr, {});

            curr = next_map.get(curr) orelse return error.TopologyCorrupted;
            if (curr == he_id) break;
        }
    }

    // If the virtual map failed to cleanly consume every single boundary edge into closed loops,
    // we abort immediately. The graph remains 100% untouched and safe!
    if (visited_bounds.count() != boundary_edges.items.len) {
        return error.TopologyCorrupted;
    }

    // 4. SAFE MUTATION PHASE
    var it = next_map.iterator();
    while (it.next()) |entry| {
        const he = entry.key_ptr.*;
        const nx = entry.value_ptr.*;
        t.half_edges.items[he].next = nx;
        t.half_edges.items[nx].prev = he;
    }

    for (internal_seams.items) |seam_id| {
        t.half_edges.items[seam_id].twin = topo.NULL_ID;
    }

    const target_face_id = island[0];
    var new_loops = std.ArrayListUnmanaged(topo.LoopId).empty;
    defer new_loops.deinit(allocator);

    for (temp_loops.items) |first_he| {
        const loop_id: u32 = @intCast(t.loops.items.len);
        try t.loops.append(allocator, .{ .face_id = target_face_id, .first_half_edge = first_he });
        try new_loops.append(allocator, loop_id);

        var curr = first_he;
        while (true) {
            t.half_edges.items[curr].loop_id = loop_id;
            curr = next_map.get(curr).?;
            if (curr == first_he) break;
        }
    }

    const new_fl_start: u32 = @intCast(t.face_loops.items.len);
    try t.face_loops.appendSlice(allocator, new_loops.items);
    t.faces.items[target_face_id].loops_start = new_fl_start;
    t.faces.items[target_face_id].loops_len = @intCast(new_loops.items.len);

    return target_face_id;
}
