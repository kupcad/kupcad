const std = @import("std");
const types = @import("types.zig");
const arena = @import("arena.zig");
const MathEnv = @import("../math_env.zig").MathEnv;

pub const ValidationError = error{
    BrokenLinkedList,
    DanglingTwin,
    AsymmetricTwin,
    AntiParallelTwin,
    UnclosedLoop,
    EulerCharacteristicMismatch,
};

pub const Verifier = struct {
    /// Audits a specific solid for topological integrity without touching math coordinates.
    pub fn validateSolid(
        allocator: std.mem.Allocator,
        t_arena: *const arena.TopologyArena,
        solid_idx: types.SolidIndex,
    ) ValidationError!void {
        const solid = t_arena.solids.items[@intFromEnum(solid_idx)];

        for (0..solid.shells_len) |s_off| {
            const shell_idx = t_arena.solid_shells.items[solid.shells_start + s_off];
            try validateShell(allocator, t_arena, shell_idx);
        }
    }

    fn validateShell(
        allocator: std.mem.Allocator,
        t_arena: *const arena.TopologyArena,
        shell_idx: types.ShellIndex,
    ) ValidationError!void {
        const shell = t_arena.shells.items[@intFromEnum(shell_idx)];

        var visited_vertices = std.AutoHashMap(types.VertexIndex, void).init(allocator);
        defer visited_vertices.deinit();

        var he_count: usize = 0;
        const f_count: usize = shell.faces_len;
        var l_count: usize = 0;

        for (0..shell.faces_len) |f_off| {
            const face_idx = t_arena.shell_faces.items[shell.faces_start + f_off];
            const face = t_arena.faces.items[@intFromEnum(face_idx)];
            l_count += face.loops_len;

            for (0..face.loops_len) |l_off| {
                const loop_idx = t_arena.face_loops.items[face.loops_start + l_off];
                const loop = t_arena.loops.items[@intFromEnum(loop_idx)];

                var curr_he_idx = loop.first_half_edge;
                var steps: usize = 0;

                while (true) : (steps += 1) {
                    if (steps > 10_000) return error.UnclosedLoop;

                    const he = t_arena.half_edges.items[@intFromEnum(curr_he_idx)];
                    he_count += 1;

                    try visited_vertices.put(he.start_vertex, {});

                    // 1. Linked List Integrity
                    if (t_arena.half_edges.items[@intFromEnum(he.next)].prev != curr_he_idx) return error.BrokenLinkedList;
                    if (t_arena.half_edges.items[@intFromEnum(he.prev)].next != curr_he_idx) return error.BrokenLinkedList;

                    // 2. Twin Reciprocity & Orientation
                    if (he.twin != types.NULL_HALF_EDGE) {
                        const twin_he = t_arena.half_edges.items[@intFromEnum(he.twin)];
                        if (twin_he.twin != curr_he_idx) return error.AsymmetricTwin;

                        const next_he = t_arena.half_edges.items[@intFromEnum(he.next)];
                        if (twin_he.start_vertex != next_he.start_vertex) return error.AntiParallelTwin;
                    } else {
                        return error.DanglingTwin; // Requires completely closed 2-manifold shells
                    }

                    curr_he_idx = he.next;
                    if (curr_he_idx == loop.first_half_edge) break;
                }
            }
        }

        // 3. Euler-Poincaré Characteristic Check: V - E + F - (L - F) = 2
        const v = visited_vertices.count();
        const e = he_count / 2;
        const holes = @as(i32, @intCast(l_count)) - @as(i32, @intCast(f_count));
        const euler = @as(i32, @intCast(v)) - @as(i32, @intCast(e)) + @as(i32, @intCast(f_count)) - holes;

        // A strictly closed genus-0 shell must equal 2
        if (euler > 2 or @rem(euler, 2) != 0) {
            return error.EulerCharacteristicMismatch;
        }
    }
};
