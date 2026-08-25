const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");
const booleans = @import("booleans.zig");
const tessellate = @import("tessellate.zig");
const sweeps = @import("sweeps.zig");
const minkowski = @import("minkowski.zig");
const transforms = @import("transforms.zig");

// Note: GeometryHandle is just a u32 index into our solid array.
const GeometryHandle = usize;

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

fn extrudeImpl(base: GeometryHandle, vx: f64, vy: f64, vz: f64) ?GeometryHandle {
    // In a real implementation, `base` would be a FaceId or WireId.
    const solid_id = sweeps.extrudeFace(&g_topo_arena, &g_geom_arena, @as(topo.FaceId, @intCast(base)), .{ vx, vy, vz }) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn booleanImpl(a: GeometryHandle, b: GeometryHandle, op_type: u8) ?GeometryHandle {
    const op = switch (op_type) {
        0 => booleans.BooleanOp.union_op,
        1 => booleans.BooleanOp.difference,
        else => booleans.BooleanOp.intersection,
    };

    // Retrieve configuration (mocked here, ideally passed through the VM context)
    const mock_config = .{};

    const solid_id = booleans.computeBoolean(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(a)), @as(topo.SolidId, @intCast(b)), op, mock_config) catch return null;

    return @as(GeometryHandle, solid_id);
}

fn minkowskiImpl(a: GeometryHandle, b: GeometryHandle) ?GeometryHandle {
    const solid_id = minkowski.minkowskiSumConvex(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(a)), @as(topo.SolidId, @intCast(b))) catch return null;

    return @as(GeometryHandle, solid_id);
}

/// The static dispatch table matching `kernel.GeometryKernel`
pub const driver = struct {
    pub const cubeFn = cubeImpl;
    pub const extrudeFn = extrudeImpl;
    pub const booleanFn = booleanImpl;
    pub const minkowskiFn = minkowskiImpl;
    // ... complete the rest of the 37 methods by mapping them to locus modules ...
};
