const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const arena = @import("arena.zig");
const geom_arena = @import("../geometry/arena.zig");
const geom_types = @import("../geometry/types.zig");
const surfaces = @import("../geometry/surfaces.zig");
const math = @import("../math.zig");
const env = @import("../math_env.zig");

pub const ValidationError = error{
    // Topological Connectivity
    BrokenLinkedList,
    DanglingTwin,
    AsymmetricTwin,
    AntiParallelTwin,
    UnclosedLoop,
    LoopFaceMismatch,
    OpenBoundaryInClosedShell,
    InvalidWindingOrder,

    // Geometric Integrity
    DegenerateEdge,
    VertexNotOnSurface,
    NaNOrInfCoordinate,
    UvDrift,

    // Global Manifold
    EulerCharacteristicMismatch,
    OutOfMemory,
};

pub const ValidatorConfig = struct {
    enable_checks: bool = (builtin.mode == .debug or builtin.is_test),
    require_closed_shells: bool = true,
    check_euler: bool = true,
    check_twins: bool = true,
    check_linked_lists: bool = true,
    check_coincidence: bool = true,
    check_degenerates: bool = true,
    check_uv_sync: bool = true,
    check_winding: bool = false,
    mute_errors: bool = false,
};

pub const Verifier = struct {
    pub fn validateSolid(
        allocator: std.mem.Allocator,
        t_arena: *const arena.TopologyArena,
        g_arena: *const geom_arena.GeometryArena,
        math_env: env.MathEnv,
        solid_idx: types.SolidIndex,
        config: ValidatorConfig,
    ) ValidationError!void {
        if (!config.enable_checks) return;

        const solid = t_arena.solids.items[@intFromEnum(solid_idx)];
        for (0..solid.shells_len) |s_off| {
            const shell_idx = t_arena.solid_shells.items[solid.shells_start + s_off];
            try validateShell(allocator, t_arena, g_arena, math_env, shell_idx, config);
        }
    }

    fn validateShell(
        allocator: std.mem.Allocator,
        t_arena: *const arena.TopologyArena,
        g_arena: *const geom_arena.GeometryArena,
        math_env: env.MathEnv,
        shell_idx: types.ShellIndex,
        config: ValidatorConfig,
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

                if (loop.face_id != face_idx) return error.LoopFaceMismatch;

                var curr_he_idx = loop.first_half_edge;
                var steps: usize = 0;

                while (true) : (steps += 1) {
                    if (steps > 10_000) return error.UnclosedLoop;
                    const he = t_arena.half_edges.items[@intFromEnum(curr_he_idx)];
                    const next_he = t_arena.half_edges.items[@intFromEnum(he.next)];
                    he_count += 1;

                    try visited_vertices.put(he.start_vertex, {});

                    // 1. Linked List Integrity
                    if (config.check_linked_lists) {
                        if (t_arena.half_edges.items[@intFromEnum(he.next)].prev != curr_he_idx) return error.BrokenLinkedList;
                        if (t_arena.half_edges.items[@intFromEnum(he.prev)].next != curr_he_idx) return error.BrokenLinkedList;
                        if (he.loop_id != loop_idx) return error.LoopFaceMismatch;
                    }

                    // 2. Twin Reciprocity & Orientation
                    if (config.check_twins) {
                        if (he.twin != types.NULL_HALF_EDGE) {
                            const twin_idx = @intFromEnum(he.twin);
                            if (twin_idx >= t_arena.half_edges.items.len) return error.DanglingTwin;
                            const twin_he = t_arena.half_edges.items[twin_idx];

                            if (twin_he.twin != curr_he_idx) return error.AsymmetricTwin;
                            if (twin_he.start_vertex != next_he.start_vertex) return error.AntiParallelTwin;
                        } else if (config.require_closed_shells) {
                            return error.OpenBoundaryInClosedShell;
                        }
                    }

                    const v_start_pt_idx = t_arena.vertices.items[@intFromEnum(he.start_vertex)].point;
                    const v_start = g_arena.points.items[@intFromEnum(v_start_pt_idx)];

                    // 3. NaN/Inf Memory Corruption Check
                    if (std.math.isNan(v_start[0]) or std.math.isNan(v_start[1]) or std.math.isNan(v_start[2]) or
                        std.math.isInf(v_start[0]) or std.math.isInf(v_start[1]) or std.math.isInf(v_start[2]))
                    {
                        return error.NaNOrInfCoordinate;
                    }

                    // 4. Degenerate Geometry Check
                    if (config.check_degenerates and he.curve.curve_type == .line) {
                        const v_end_pt_idx = t_arena.vertices.items[@intFromEnum(next_he.start_vertex)].point;
                        const v_end = g_arena.points.items[@intFromEnum(v_end_pt_idx)];
                        if (math_env.isCoincident(v_start, v_end)) {
                            return error.DegenerateEdge;
                        }
                    }

                    // 5. Coincidence Check
                    if (config.check_coincidence) {
                        const proj_pt = surfaces.projectPointToSurface(g_arena, face.surface, v_start);
                        if (!math_env.isCoincident(v_start, proj_pt)) {
                            return error.VertexNotOnSurface;
                        }
                    }

                    // 6. UV Drift Synchronization Check
                    if (config.check_uv_sync and face.surface.surface_type == .nurbs) {
                        if (he.start_uv) |uv| {
                            const surf = g_arena.nurbs_surfaces.items[@intFromEnum(face.surface.index)];
                            const pt3d = surf.evaluate(uv[0], uv[1]);
                            if (!math_env.isCoincident(v_start, pt3d)) {
                                return error.UvDrift;
                            }
                        }
                    }

                    curr_he_idx = he.next;
                    if (curr_he_idx == loop.first_half_edge) break;
                }

                // 7. Loop Winding Order Check vs Surface Normal
                if (config.check_winding and face.surface.surface_type == .plane) {
                    const plane = g_arena.planes.items[@intFromEnum(face.surface.index)];
                    const surf_norm = math.normalize(math.cross(plane.u_axis, plane.v_axis));

                    var cross_sum = math.Vec3{ 0, 0, 0 };
                    var c_he_idx = loop.first_half_edge;
                    var safety: usize = 0;

                    while (safety < 1000) : (safety += 1) {
                        const he = t_arena.half_edges.items[@intFromEnum(c_he_idx)];
                        const next_he = t_arena.half_edges.items[@intFromEnum(he.next)];
                        const v1_pt_idx = t_arena.vertices.items[@intFromEnum(he.start_vertex)].point;
                        const v2_pt_idx = t_arena.vertices.items[@intFromEnum(next_he.start_vertex)].point;
                        const v1 = g_arena.points.items[@intFromEnum(v1_pt_idx)];
                        const v2 = g_arena.points.items[@intFromEnum(v2_pt_idx)];

                        cross_sum = math.add(cross_sum, math.cross(v1, v2));
                        c_he_idx = he.next;
                        if (c_he_idx == loop.first_half_edge) break;
                    }

                    const dot_prod = math.dot(cross_sum, surf_norm);
                    if (face.forward) {
                        if (dot_prod < 0.0) return error.InvalidWindingOrder;
                    } else {
                        if (dot_prod > 0.0) return error.InvalidWindingOrder;
                    }
                }
            }
        }

        // 8. Euler-Poincaré Characteristic Check
        if (config.check_euler and f_count > 0 and config.require_closed_shells) {
            const v = visited_vertices.count();
            const e = he_count / 2;
            const holes = @as(i32, @intCast(l_count)) - @as(i32, @intCast(f_count));
            const euler = @as(i32, @intCast(v)) - @as(i32, @intCast(e)) + @as(i32, @intCast(f_count)) - holes;

            if (euler > 2 or @rem(euler, 2) != 0) {
                if (!config.mute_errors) {
                    std.debug.print("Euler Violation: V={d}, E={d}, F={d}, L={d} -> Euler = {d}\n", .{
                        v, e, f_count, l_count, euler,
                    });
                }
                return error.EulerCharacteristicMismatch;
            }
        }
    }

    pub inline fn assertValidTestOnly(
        allocator: std.mem.Allocator,
        t_arena: *const arena.TopologyArena,
        g_arena: *const geom_arena.GeometryArena,
        math_env: env.MathEnv,
        solid_idx: types.SolidIndex,
    ) void {
        if (builtin.is_test) {
            std.debug.assert(t_arena.half_edges.items.len % 2 == 0);

            validateSolid(allocator, t_arena, g_arena, math_env, solid_idx, .{}) catch |err| {
                const debug_dump = @import("../debug_dump.zig").DebugDumper;
                const io = std.testing.io;

                const cwd = std.Io.Dir.cwd();
                cwd.createDirPath(io, "src/locus/test_dump") catch {};

                debug_dump.dumpSolidToObj(allocator, io, "src/locus/test_dump/crash_dump.obj", t_arena, g_arena, solid_idx) catch {};
                std.debug.panic("Topological corruption detected during test: {s}", .{@errorName(err)});
            };
        }
    }
};
