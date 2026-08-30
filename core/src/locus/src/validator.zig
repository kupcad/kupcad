const std = @import("std");
const builtin = @import("builtin");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const booleans = @import("booleans.zig");

pub const ValidationError = error{
    // Topological Connectivity
    BrokenLinkedList,
    DanglingTwin,
    AsymmetricTwin,
    UnclosedLoop,
    LoopFaceMismatch,
    OpenBoundaryInClosedShell,

    // Geometric Integrity
    DegenerateEdge,
    VertexNotOnSurface,
    NaNOrInfCoordinate,

    // Global Manifold
    EulerCharacteristicMismatch,
    OutOfMemory,
};

pub const ValidatorConfig = struct {
    enable_checks: bool = (builtin.mode == .Debug),
    require_closed_shells: bool = true,
    check_euler: bool = true,
    check_twins: bool = true,
    check_linked_lists: bool = true,
    check_coincidence: bool = true,
};

pub const BRepSanitizer = struct {
    pub fn validateSolid(
        allocator: std.mem.Allocator,
        t_arena: *const topo.TopologyArena,
        g_arena: *const geom.GeometryArena,
        solid_id: topo.SolidId,
        tol: math.Tolerance,
        config: ValidatorConfig,
    ) ValidationError!void {
        if (!config.enable_checks) return;

        const solid = t_arena.solids.items[solid_id];
        for (0..solid.shells_len) |s_off| {
            const shell_id = t_arena.solid_shells.items[solid.shells_start + s_off];
            try validateShell(allocator, t_arena, g_arena, shell_id, tol, config);
        }
    }

    fn validateShell(
        allocator: std.mem.Allocator,
        t_arena: *const topo.TopologyArena,
        g_arena: *const geom.GeometryArena,
        shell_id: topo.ShellId,
        tol: math.Tolerance,
        config: ValidatorConfig,
    ) ValidationError!void {
        const shell = t_arena.shells.items[shell_id];

        var visited_vertices = std.AutoHashMap(topo.VertexId, void).init(allocator);
        defer visited_vertices.deinit();

        var he_count: usize = 0;
        const f_count: usize = shell.faces_len;

        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
            const face = t_arena.faces.items[face_id];

            for (0..face.loops_len) |l_off| {
                const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
                const loop = t_arena.loops.items[loop_id];

                if (loop.face_id != face_id) return error.LoopFaceMismatch;

                var curr_he_id = loop.first_half_edge;
                var steps: usize = 0;

                while (true) : (steps += 1) {
                    if (steps > 10_000) return error.UnclosedLoop;

                    const he = t_arena.half_edges.items[curr_he_id];
                    he_count += 1;

                    try visited_vertices.put(he.start_vertex, {});

                    // 1. Linked List Integrity
                    if (config.check_linked_lists) {
                        if (t_arena.half_edges.items[he.next].prev != curr_he_id) return error.BrokenLinkedList;
                        if (t_arena.half_edges.items[he.prev].next != curr_he_id) return error.BrokenLinkedList;
                        if (he.loop_id != loop_id) return error.LoopFaceMismatch;
                    }

                    // 2. Twin Reciprocity & Manifold Closure
                    if (config.check_twins) {
                        if (he.twin != topo.NULL_ID) {
                            if (he.twin >= t_arena.half_edges.items.len) return error.DanglingTwin;
                            const twin_he = t_arena.half_edges.items[he.twin];
                            if (twin_he.twin != curr_he_id) return error.AsymmetricTwin;
                        } else if (config.require_closed_shells) {
                            return error.OpenBoundaryInClosedShell;
                        }
                    }

                    const v_start = t_arena.vertices.items[he.start_vertex].point;

                    // 3. NaN/Inf Memory Corruption Check
                    if (std.math.isNan(v_start[0]) or std.math.isNan(v_start[1]) or std.math.isNan(v_start[2]) or
                        std.math.isInf(v_start[0]) or std.math.isInf(v_start[1]) or std.math.isInf(v_start[2]))
                    {
                        return error.NaNOrInfCoordinate;
                    }

                    // 4. Degenerate Geometry Check (Zero-length edges)[cite: 13]
                    if (he.curve.curve_type == .line) {
                        const next_he = t_arena.half_edges.items[he.next];
                        const v_end = t_arena.vertices.items[next_he.start_vertex].point;
                        if (math.distSq(v_start, v_end) < tol.squared) {
                            return error.DegenerateEdge;
                        }
                    }

                    // 5. Coincidence Check (Vertex rests exactly on Face Surface)[cite: 13]
                    if (config.check_coincidence) {
                        const proj_pt = booleans.projectPointToSurface(g_arena, face.surface, v_start);
                        if (math.distSq(v_start, proj_pt) > tol.squared * 4.0) {
                            return error.VertexNotOnSurface;
                        }
                    }

                    curr_he_id = he.next;
                    if (curr_he_id == loop.first_half_edge) break;
                }
            }
        }

        // 6. Euler-Poincaré Characteristic (V - E + F = 2 for Genus 0)
        if (config.check_euler and f_count > 0 and config.require_closed_shells) {
            const v = visited_vertices.count();
            const e = he_count / 2;
            const euler = @as(i32, @intCast(v)) - @as(i32, @intCast(e)) + @as(i32, @intCast(f_count));

            // Note: Genus > 0 (e.g., toruses or blocks with through-holes) will have Euler <= 0.
            // This strict check assumes simple Genus 0 manifold shells.
            if (euler != 2) {
                std.log.warn("Euler Violation: V={d}, E={d}, F={d} -> V-E+F = {d} (Expected 2)\n", .{
                    v, e, f_count, euler,
                });
                return error.EulerCharacteristicMismatch;
            }
        }
    }
};
