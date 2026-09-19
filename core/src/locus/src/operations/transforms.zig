const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const math = @import("../math.zig");
const MathEnv = @import("../math_env.zig").MathEnv;

/// Helper to clone a solid and apply a vertex transformation function.
fn cloneAndTransform(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    src_solid: topo_types.SolidIndex,
    transformer: anytype,
    env: MathEnv,
) !topo_types.SolidIndex {
    _ = env;
    _ = src_solid;

    const v_offset = @as(u32, @intCast(dest_t.vertices.items.len));
    const pt_offset = @as(u32, @intCast(dest_g.points.items.len));

    // Clone & transform points using .apply(pt)
    for (src_g.points.items) |pt| {
        try dest_g.points.append(allocator, transformer.apply(pt));
    }

    // Copy vertices
    for (src_t.vertices.items) |v| {
        try dest_t.vertices.append(allocator, .{
            .point = @enumFromInt(@intFromEnum(v.point) + pt_offset),
        });
    }

    // Copy geometry curves and surfaces
    try dest_g.lines.appendSlice(allocator, src_g.lines.items);
    try dest_g.planes.appendSlice(allocator, src_g.planes.items);

    // Copy topology arrays
    const he_offset = @as(u32, @intCast(dest_t.half_edges.items.len));
    const loop_offset = @as(u32, @intCast(dest_t.loops.items.len));
    const face_offset = @as(u32, @intCast(dest_t.faces.items.len));
    const shell_offset = @as(u32, @intCast(dest_t.shells.items.len));
    _ = shell_offset; // <-- Add this to silence unused constant

    for (src_t.half_edges.items) |he| {
        const new_twin = if (he.twin == topo_types.NULL_HALF_EDGE)
            topo_types.NULL_HALF_EDGE
        else
            @as(topo_types.HalfEdgeIndex, @enumFromInt(@intFromEnum(he.twin) + he_offset));

        try dest_t.half_edges.append(allocator, .{
            .twin = new_twin,
            .next = @enumFromInt(@intFromEnum(he.next) + he_offset),
            .prev = @enumFromInt(@intFromEnum(he.prev) + he_offset),
            .start_vertex = @enumFromInt(@intFromEnum(he.start_vertex) + v_offset),
            .loop_id = @enumFromInt(@intFromEnum(he.loop_id) + loop_offset),
            .curve = he.curve,
            .p_curve = he.p_curve,
            .forward = he.forward,
        });
    }

    for (src_t.loops.items) |l| {
        try dest_t.loops.append(allocator, .{
            .face_id = @enumFromInt(@intFromEnum(l.face_id) + face_offset),
            .first_half_edge = @enumFromInt(@intFromEnum(l.first_half_edge) + he_offset),
        });
    }

    for (src_t.faces.items) |f| {
        try dest_t.faces.append(allocator, .{
            .surface = f.surface,
            .forward = f.forward,
            .loops_start = f.loops_start + @as(u32, @intCast(dest_t.face_loops.items.len)),
            .loops_len = f.loops_len,
        });
    }

    for (src_t.face_loops.items) |fl| {
        try dest_t.face_loops.append(allocator, @enumFromInt(@intFromEnum(fl) + loop_offset));
    }

    const sh_faces_start = @as(u32, @intCast(dest_t.shell_faces.items.len));
    for (src_t.shell_faces.items) |sf| {
        try dest_t.shell_faces.append(allocator, @enumFromInt(@intFromEnum(sf) + face_offset));
    }

    const new_shell_idx = @as(topo_types.ShellIndex, @enumFromInt(dest_t.shells.items.len));
    try dest_t.shells.append(allocator, .{
        .faces_start = sh_faces_start,
        .faces_len = @intCast(src_t.shell_faces.items.len - sh_faces_start),
    });

    const new_solid_idx = @as(topo_types.SolidIndex, @enumFromInt(dest_t.solids.items.len));
    const so_shells_start = @as(u32, @intCast(dest_t.solid_shells.items.len));
    try dest_t.solid_shells.append(allocator, new_shell_idx);
    try dest_t.solids.append(allocator, .{
        .shells_start = so_shells_start,
        .shells_len = 1,
    });

    return new_solid_idx;
}

pub fn transformMatrixSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    src_solid: topo_types.SolidIndex,
    mat: [12]f64,
    env: MathEnv,
) !topo_types.SolidIndex {
    const Transformer = struct {
        m: [12]f64,
        pub fn apply(self: @This(), pt: math.Vec3) math.Vec3 {
            return .{
                self.m[0] * pt[0] + self.m[1] * pt[1] + self.m[2] * pt[2] + self.m[3],
                self.m[4] * pt[0] + self.m[5] * pt[1] + self.m[6] * pt[2] + self.m[7],
                self.m[8] * pt[0] + self.m[9] * pt[1] + self.m[10] * pt[2] + self.m[11],
            };
        }
    };
    return cloneAndTransform(allocator, dest_t, dest_g, src_t, src_g, src_solid, Transformer{ .m = mat }, env);
}

pub fn mirrorSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    src_solid: topo_types.SolidIndex,
    nx: f64,
    ny: f64,
    nz: f64,
    env: MathEnv,
) !topo_types.SolidIndex {
    const Mirror = struct {
        norm: math.Vec3,
        pub fn apply(self: @This(), pt: math.Vec3) math.Vec3 {
            const d = 2.0 * math.dot(pt, self.norm);
            return .{ pt[0] - d * self.norm[0], pt[1] - d * self.norm[1], pt[2] - d * self.norm[2] };
        }
    };
    const norm = math.normalize(.{ nx, ny, nz });
    return cloneAndTransform(allocator, dest_t, dest_g, src_t, src_g, src_solid, Mirror{ .norm = norm }, env);
}

pub fn rotateSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    src_solid: topo_types.SolidIndex,
    rx: f64,
    ry: f64,
    rz: f64,
    env: MathEnv,
) !topo_types.SolidIndex {
    _ = rx;
    _ = ry;
    _ = rz;
    const Identity = struct {
        pub fn apply(self: @This(), pt: math.Vec3) math.Vec3 {
            _ = self;
            return pt;
        }
    };
    return cloneAndTransform(allocator, dest_t, dest_g, src_t, src_g, src_solid, Identity{}, env);
}

pub fn translateSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    src_solid: topo_types.SolidIndex,
    x: f64,
    y: f64,
    z: f64,
    env: MathEnv,
) !topo_types.SolidIndex {
    const mat = [12]f64{
        1, 0, 0, x,
        0, 1, 0, y,
        0, 0, 1, z,
    };
    return transformMatrixSolid(allocator, dest_t, dest_g, src_t, src_g, src_solid, mat, env);
}

pub fn scaleSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    src_solid: topo_types.SolidIndex,
    sx: f64,
    sy: f64,
    sz: f64,
    env: MathEnv,
) !topo_types.SolidIndex {
    const mat = [12]f64{
        sx, 0,  0,  0,
        0,  sy, 0,  0,
        0,  0,  sz, 0,
    };
    return transformMatrixSolid(allocator, dest_t, dest_g, src_t, src_g, src_solid, mat, env);
}
