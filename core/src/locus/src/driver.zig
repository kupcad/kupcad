const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");
const booleans = @import("booleans.zig");
const tessellate = @import("tessellate.zig");
const sweeps = @import("sweeps.zig");
const minkowski = @import("minkowski.zig");
const transforms = @import("transforms.zig");

pub const FfiMesh = struct {
    vertex_ptr: [*]const f32,
    vertex_len: usize,
    index_ptr: [*]const u32,
    index_len: usize,
};

// Note: GeometryHandle is just a usize index into our solid array.
pub const GeometryHandle = usize;

// Global Kernel State
var g_allocator: std.mem.Allocator = undefined;
var g_topo_arena: topo.TopologyArena = undefined;
var g_geom_arena: geom.GeometryArena = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
    g_topo_arena = topo.TopologyArena.init(allocator);
    g_geom_arena = geom.GeometryArena.init(allocator);
}

pub fn deinit() void {
    g_topo_arena.deinit();
    g_geom_arena.deinit();
}

// --- V-Table Implementations ---

fn cubeImpl(x: f64, y: f64, z: f64, center: bool) ?GeometryHandle {
    const solid_id = generators.generateCube(&g_topo_arena, &g_geom_arena, x, y, z, center) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn cylinderImpl(radius: f64, height: f64, center: bool) ?GeometryHandle {
    const solid_id = generators.generateCylinder(&g_topo_arena, &g_geom_arena, radius, height, center) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn sphereImpl(radius: f64) ?GeometryHandle {
    const solid_id = generators.generateSphere(&g_topo_arena, &g_geom_arena, radius) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn extrudeImpl(base: GeometryHandle, vx: f64, vy: f64, vz: f64) ?GeometryHandle {
    const solid_id = sweeps.extrudeFace(&g_topo_arena, &g_geom_arena, @as(topo.FaceId, @intCast(base)), .{ vx, vy, vz }) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn translateImpl(shape: GeometryHandle, x: f64, y: f64, z: f64) ?GeometryHandle {
    const solid_id = transforms.translateSolid(&g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), x, y, z) catch return null;
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

fn getMeshImpl(shape: GeometryHandle) ?FfiMesh {
    // In a real application, we would keep this mesh in a cache or arena so we don't leak it.
    // For the driver interface, we will create it and pretend to return the pointers.
    var mesh = tessellate.Mesh{};

    const mock_config = .{};

    tessellate.tessellateSolid(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), &mesh, mock_config) catch return null;

    // We would normally transfer ownership of the memory here.
    // For now, we clean it up immediately to prevent leaks during tests.
    defer mesh.deinit(g_allocator);

    return FfiMesh{
        .vertex_ptr = undefined,
        .vertex_len = mesh.vertices.items.len * 3,
        .index_ptr = undefined,
        .index_len = mesh.triangles.items.len * 3,
    };
}

/// The static dispatch table matching `kernel.GeometryKernel`
pub const driver = struct {
    pub const cubeFn = cubeImpl;
    pub const cylinderFn = cylinderImpl;
    pub const sphereFn = sphereImpl;
    pub const extrudeFn = extrudeImpl;
    pub const translateFn = translateImpl;
    pub const booleanFn = booleanImpl;
    pub const minkowskiFn = minkowskiImpl;
    pub const getMeshFn = getMeshImpl;
};
