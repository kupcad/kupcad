const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const generators = @import("generators.zig");
const transforms = @import("transforms.zig");
const booleans = @import("booleans.zig");

const HALF_SPACE_SIZE: f64 = 20000.0; // Massive bounding box

/// Generates a massive solid cube that entirely fills the negative half-space of a plane.
fn generateHalfSpace(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    nx: f64,
    ny: f64,
    nz: f64,
    offset: f64,
    flip: bool,
) !topo.SolidId {
    // 1. Generate a massive centered cube
    const cube_id = try generators.generateCube(allocator, t_arena, g_arena, HALF_SPACE_SIZE, HALF_SPACE_SIZE, HALF_SPACE_SIZE, true);

    // 2. Define the local coordinate basis for the plane
    var normal = math.normalize(.{ nx, ny, nz });
    if (flip) normal = math.scale(normal, -1.0);

    var x_axis = math.Vec3{ 1, 0, 0 };
    if (@abs(normal[2]) < 0.99) {
        x_axis = math.normalize(math.cross(normal, .{ 0, 0, 1 }));
    } else {
        x_axis = math.normalize(math.cross(normal, .{ 1, 0, 0 }));
    }
    const y_axis = math.normalize(math.cross(normal, x_axis));

    // 3. Calculate Translation
    // The plane is at distance `offset` along the normal from the origin.
    const p0 = math.scale(math.normalize(.{ nx, ny, nz }), offset);

    // Shift the cube so its top face (Z = +SIZE/2) lies exactly on the plane,
    // meaning the entire body of the cube extends downward into the -Z direction.
    const shift_down = math.scale(normal, -(HALF_SPACE_SIZE / 2.0));
    const translation = math.add(p0, shift_down);

    // 4. Construct 4x4 Affine Matrix (Row-Major)
    const mat = [12]f64{
        x_axis[0], y_axis[0], normal[0], translation[0],
        x_axis[1], y_axis[1], normal[1], translation[1],
        x_axis[2], y_axis[2], normal[2], translation[2],
    };

    // 5. Snap the cube into place
    return try transforms.transformMatrixSolid(allocator, t_arena, g_arena, cube_id, mat);
}

/// Trims a solid by an infinite plane, keeping the material on the OPPOSITE side of the normal.
pub fn trimByPlane(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    target_solid: topo.SolidId,
    nx: f64,
    ny: f64,
    nz: f64,
    offset: f64,
) !topo.SolidId {
    const half_space = try generateHalfSpace(allocator, t_arena, g_arena, nx, ny, nz, offset, false);
    return try booleans.computeBoolean(allocator, t_arena, g_arena, target_solid, half_space, .intersection, .{});
}

pub const SolidPair = struct {
    first: topo.SolidId,
    second: topo.SolidId,
};

/// Splits a solid entirely in two along an infinite plane.
pub fn splitByPlane(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    target_solid: topo.SolidId,
    nx: f64,
    ny: f64,
    nz: f64,
    offset: f64,
) !SolidPair {
    // We generate TWO half spaces facing opposite directions
    const space_neg = try generateHalfSpace(allocator, t_arena, g_arena, nx, ny, nz, offset, false);
    const space_pos = try generateHalfSpace(allocator, t_arena, g_arena, nx, ny, nz, offset, true);

    // To prevent graph corruption, we don't destroy the original yet. We just extract two intersections.
    const solid_neg = try booleans.computeBoolean(allocator, t_arena, g_arena, target_solid, space_neg, .intersection, .{});
    const solid_pos = try booleans.computeBoolean(allocator, t_arena, g_arena, target_solid, space_pos, .intersection, .{});

    return .{ .first = solid_pos, .second = solid_neg };
}
