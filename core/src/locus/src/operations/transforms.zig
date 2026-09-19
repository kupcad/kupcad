const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const geom_types = @import("../geometry/types.zig");
const MathEnv = @import("../math_env.zig").MathEnv;
const math = @import("../math.zig");
const booleans = @import("booleans.zig");

pub const TransformError = error{OutOfMemory};

fn collectSolidGeometry(
    allocator: std.mem.Allocator,
    t_arena: *const topo_arena.TopologyArena,
    solid_id: topo_types.SolidIndex,
    vertices: *std.AutoHashMap(topo_types.VertexIndex, void),
    planes: *std.AutoHashMap(geom_types.SurfaceIndex, void),
) !void {
    _ = allocator;
    _ = t_arena;
    _ = solid_id;
    _ = vertices;
    _ = planes;
    // TODO: Traverse graph and populate maps
}

pub fn transformMatrixSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
    mat: [12]f64,
    env: MathEnv,
) TransformError!topo_types.SolidIndex {
    _ = env;

    // 1. Deep Clone from Source to Dest
    const cloned_solid_idx = try booleans.deepCloneSolid(allocator, dest_t, dest_g, src_t, src_g, solid_id);

    // 2. Collect unique geometry indices from the newly cloned solid
    var v_map = std.AutoHashMap(topo_types.VertexIndex, void).init(allocator);
    defer v_map.deinit();
    var p_map = std.AutoHashMap(geom_types.SurfaceIndex, void).init(allocator);
    defer p_map.deinit();

    try collectSolidGeometry(allocator, dest_t, cloned_solid_idx, &v_map, &p_map);

    const applyMat = struct {
        fn apply(pt: math.Vec3, m: [12]f64) math.Vec3 {
            return .{
                pt[0] * m[0] + pt[1] * m[1] + pt[2] * m[2] + m[3],
                pt[0] * m[4] + pt[1] * m[5] + pt[2] * m[6] + m[7],
                pt[0] * m[8] + pt[1] * m[9] + pt[2] * m[10] + m[11],
            };
        }
        fn applyDir(vec: math.Vec3, m: [12]f64) math.Vec3 {
            return math.normalize(.{
                vec[0] * m[0] + vec[1] * m[1] + vec[2] * m[2],
                vec[0] * m[4] + vec[1] * m[5] + vec[2] * m[6],
                vec[0] * m[8] + vec[1] * m[9] + vec[2] * m[10],
            });
        }
    };

    // 3. Mutate only the freshly cloned coordinates in the destination arena
    var v_it = v_map.keyIterator();
    while (v_it.next()) |v| {
        const v_idx = @intFromEnum(v.*);
        const pt_idx = @intFromEnum(dest_t.vertices.items[v_idx].point);
        dest_g.points.items[pt_idx] = applyMat.apply(dest_g.points.items[pt_idx], mat);
    }

    var p_it = p_map.keyIterator();
    while (p_it.next()) |p| {
        const p_idx = @intFromEnum(p.*);
        dest_g.planes.items[p_idx].origin = applyMat.apply(dest_g.planes.items[p_idx].origin, mat);
        dest_g.planes.items[p_idx].u_axis = applyMat.applyDir(dest_g.planes.items[p_idx].u_axis, mat);
        dest_g.planes.items[p_idx].v_axis = applyMat.applyDir(dest_g.planes.items[p_idx].v_axis, mat);
    }

    return cloned_solid_idx;
}

pub fn translateSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
    tx: f64,
    ty: f64,
    tz: f64,
    env: MathEnv,
) TransformError!topo_types.SolidIndex {
    const mat = [12]f64{ 1, 0, 0, tx, 0, 1, 0, ty, 0, 0, 1, tz };
    return transformMatrixSolid(allocator, dest_t, dest_g, src_t, src_g, solid_id, mat, env);
}

pub fn rotateSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
    rx: f64,
    ry: f64,
    rz: f64,
    env: MathEnv,
) TransformError!topo_types.SolidIndex {
    _ = rx;
    _ = ry;
    _ = rz;
    // TODO: Build rotation matrix and route to transformMatrixSolid
    const mat = [12]f64{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    return transformMatrixSolid(allocator, dest_t, dest_g, src_t, src_g, solid_id, mat, env);
}

pub fn scaleSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
    sx: f64,
    sy: f64,
    sz: f64,
    env: MathEnv,
) TransformError!topo_types.SolidIndex {
    const mat = [12]f64{ sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, sz, 0 };
    return transformMatrixSolid(allocator, dest_t, dest_g, src_t, src_g, solid_id, mat, env);
}

pub fn mirrorSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
    nx: f64,
    ny: f64,
    nz: f64,
    env: MathEnv,
) TransformError!topo_types.SolidIndex {
    _ = nx;
    _ = ny;
    _ = nz;
    // TODO: Build reflection matrix, route to transformMatrixSolid, then invert topology chirality
    const mat = [12]f64{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    return transformMatrixSolid(allocator, dest_t, dest_g, src_t, src_g, solid_id, mat, env);
}
