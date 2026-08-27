const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");
const booleans = @import("booleans.zig");
const tessellate = @import("tessellate.zig");
const sweeps = @import("sweeps.zig");
const minkowski = @import("minkowski.zig");
const transforms = @import("transforms.zig");
const locus_slicing = @import("slicing.zig");
const math = @import("math.zig");

pub const FfiMesh = struct {
    vertex_ptr: [*]const f32,
    vertex_len: usize,
    index_ptr: [*]const u32,
    index_len: usize,
};

pub const GeometryHandle = usize;

pub const BoundingBox = struct {
    min: [3]f64,
    max: [3]f64,
};

var g_allocator: std.mem.Allocator = undefined;
var g_topo_arena: topo.TopologyArena = undefined;
var g_geom_arena: geom.GeometryArena = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
    g_topo_arena = topo.TopologyArena.init(allocator);
    g_geom_arena = geom.GeometryArena.init(allocator);
}

pub fn deinit() void {
    g_topo_arena.deinit(g_allocator);
    g_geom_arena.deinit(g_allocator);
}

fn cubeImpl(x: f64, y: f64, z: f64, center: bool) ?GeometryHandle {
    const solid_id = generators.generateCube(g_allocator, &g_topo_arena, &g_geom_arena, x, y, z, center) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn cylinderImpl(radius: f64, height: f64, center: bool) ?GeometryHandle {
    const solid_id = generators.generateCylinder(g_allocator, &g_topo_arena, &g_geom_arena, radius, height, center) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn sphereImpl(radius: f64) ?GeometryHandle {
    const solid_id = generators.generateSphere(g_allocator, &g_topo_arena, &g_geom_arena, radius) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn extrudeImpl(base: GeometryHandle, vx: f64, vy: f64, vz: f64) ?GeometryHandle {
    const solid_id = sweeps.extrudeFace(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.FaceId, @intCast(base)), .{ vx, vy, vz }) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn translateImpl(shape: GeometryHandle, x: f64, y: f64, z: f64) ?GeometryHandle {
    const solid_id = transforms.translateSolid(
        g_allocator,
        &g_topo_arena,
        &g_geom_arena,
        @as(topo.SolidId, @intCast(shape)),
        x,
        y,
        z,
    ) catch return null;

    return @as(GeometryHandle, solid_id);
}

fn transformMatrixImpl(shape: GeometryHandle, mat: [12]f64) ?GeometryHandle {
    const solid_id = transforms.transformMatrixSolid(
        g_allocator,
        &g_topo_arena,
        &g_geom_arena,
        @as(topo.SolidId, @intCast(shape)),
        mat,
    ) catch return null;

    return @as(GeometryHandle, solid_id);
}

fn booleanImpl(a: GeometryHandle, b: GeometryHandle, op_type: u8) ?GeometryHandle {
    const op = switch (op_type) {
        0 => booleans.BooleanOp.union_op,
        1 => booleans.BooleanOp.difference,
        else => booleans.BooleanOp.intersection,
    };
    const mock_config = .{};
    const solid_id = booleans.computeBoolean(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(a)), @as(topo.SolidId, @intCast(b)), op, mock_config) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn minkowskiImpl(a: GeometryHandle, b: GeometryHandle) ?GeometryHandle {
    const solid_id = minkowski.minkowskiSumConvex(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(a)), @as(topo.SolidId, @intCast(b))) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn containsPointImpl(shape: GeometryHandle, pt: [3]f64) bool {
    return booleans.isPointInsideSolid(&g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), pt);
}

fn boundingBoxImpl(shape: GeometryHandle) ?BoundingBox {
    var min = [_]f64{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var max = [_]f64{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    var found = false;

    const solid_id: topo.SolidId = @intCast(shape);
    if (solid_id >= g_topo_arena.solids.items.len) return null;

    const s = g_topo_arena.solids.items[solid_id];
    for (0..s.shells_len) |s_off| {
        const shell = g_topo_arena.shells.items[g_topo_arena.solid_shells.items[s.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face = g_topo_arena.faces.items[g_topo_arena.shell_faces.items[shell.faces_start + f_off]];
            for (0..face.loops_len) |l_off| {
                const loop = g_topo_arena.loops.items[g_topo_arena.face_loops.items[face.loops_start + l_off]];
                var curr_he = loop.first_half_edge;
                while (true) {
                    const he = g_topo_arena.half_edges.items[curr_he];
                    const pt = g_topo_arena.vertices.items[he.start_vertex].point;
                    for (0..3) |i| {
                        if (pt[i] < min[i]) min[i] = pt[i];
                        if (pt[i] > max[i]) max[i] = pt[i];
                    }
                    found = true;
                    curr_he = he.next;
                    if (curr_he == loop.first_half_edge) break;
                }
            }
        }
    }
    if (!found) return null;
    return BoundingBox{ .min = min, .max = max };
}

fn volumeImpl(shape: GeometryHandle) f64 {
    var mesh = tessellate.Mesh{};
    const mock_config = .{};
    tessellate.tessellateSolid(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), &mesh, mock_config) catch return 0.0;
    defer mesh.deinit(g_allocator);

    var vol: f64 = 0.0;
    for (mesh.triangles.items) |t| {
        const p0 = mesh.vertices.items[t[0]];
        const p1 = mesh.vertices.items[t[1]];
        const p2 = mesh.vertices.items[t[2]];

        const cross_x = p1[1] * p2[2] - p1[2] * p2[1];
        const cross_y = p1[2] * p2[0] - p1[0] * p2[2];
        const cross_z = p1[0] * p2[1] - p1[1] * p2[0];

        vol += (p0[0] * cross_x + p0[1] * cross_y + p0[2] * cross_z) / 6.0;
    }
    return @abs(vol);
}

fn surfaceAreaImpl(shape: GeometryHandle) f64 {
    var mesh = tessellate.Mesh{};
    const mock_config = .{};
    tessellate.tessellateSolid(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), &mesh, mock_config) catch return 0.0;
    defer mesh.deinit(g_allocator);

    var area: f64 = 0.0;
    for (mesh.triangles.items) |t| {
        const p0 = mesh.vertices.items[t[0]];
        const p1 = mesh.vertices.items[t[1]];
        const p2 = mesh.vertices.items[t[2]];

        const v1x = p1[0] - p0[0];
        const v1y = p1[1] - p0[1];
        const v1z = p1[2] - p0[2];

        const v2x = p2[0] - p0[0];
        const v2y = p2[1] - p0[1];
        const v2z = p2[2] - p0[2];

        const cx = v1y * v2z - v1z * v2y;
        const cy = v1z * v2x - v1x * v2z;
        const cz = v1x * v2y - v1y * v2x;

        area += 0.5 * @sqrt(cx * cx + cy * cy + cz * cz);
    }
    return area;
}

fn getMeshImpl(shape: GeometryHandle) ?FfiMesh {
    var mesh = tessellate.Mesh{};
    const mock_config = .{};

    tessellate.tessellateSolid(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), &mesh, mock_config) catch return null;
    defer mesh.deinit(g_allocator);

    return FfiMesh{
        .vertex_ptr = undefined,
        .vertex_len = mesh.vertices.items.len * 3,
        .index_ptr = undefined,
        .index_len = mesh.triangles.items.len * 3,
    };
}

fn trimByPlaneImpl(shape: GeometryHandle, nx: f64, ny: f64, nz: f64, offset: f64) ?GeometryHandle {
    const solid_id = locus_slicing.trimByPlane(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), nx, ny, nz, offset) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn squareImpl(x: f64, y: f64, center: bool) ?GeometryHandle {
    const solid_id = generators.generateSquare(g_allocator, &g_topo_arena, &g_geom_arena, x, y, center) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn polyhedronImpl(allocator: std.mem.Allocator, pts: []const [3]f64, faces: []const [3]u32) ?GeometryHandle {
    const solid_id = generators.buildPolyhedron(allocator, &g_topo_arena, &g_geom_arena, pts, faces) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn revolveImpl(cs: GeometryHandle, segments: i32, degrees: f64) ?GeometryHandle {
    const solid_id = sweeps.revolveFace(g_allocator, &g_topo_arena, &g_geom_arena, &g_topo_arena, // Test mock uses the same arena for 2D and 3D
        @as(topo.FaceId, @intCast(cs)), // <-- Cast to FaceId instead of SolidId
        @as(u32, @intCast(segments)), degrees) catch return null;
    return @as(GeometryHandle, solid_id);
}

pub const driver = struct {
    pub const cubeFn = cubeImpl;
    pub const cylinderFn = cylinderImpl;
    pub const sphereFn = sphereImpl;
    pub const extrudeFn = extrudeImpl;
    pub const translateFn = translateImpl;
    pub const transformMatrixFn = transformMatrixImpl;
    pub const booleanFn = booleanImpl;
    pub const minkowskiFn = minkowskiImpl;
    pub const containsPointFn = containsPointImpl;
    pub const boundingBoxFn = boundingBoxImpl;
    pub const volumeFn = volumeImpl;
    pub const surfaceAreaFn = surfaceAreaImpl;
    pub const getMeshFn = getMeshImpl;
    pub const trimByPlaneFn = trimByPlaneImpl;
    pub const squareFn = squareImpl;
    pub const polyhedronFn = polyhedronImpl;
    pub const revolveFn = revolveImpl;
};
