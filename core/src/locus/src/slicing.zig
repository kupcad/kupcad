const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const generators = @import("generators.zig");
const transforms = @import("transforms.zig");
const booleans = @import("booleans.zig");
const tessellate = @import("tessellate.zig");

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

/// Slices a 2-manifold triangle mesh exactly at Z = z_height, producing closed 2D loop contours.
pub fn sliceMeshToContours(allocator: std.mem.Allocator, mesh: *const tessellate.Mesh, z_height: f64) ![][]const [2]f64 {
    var segments = std.ArrayListUnmanaged([2][2]f64).empty;
    defer segments.deinit(allocator);

    for (mesh.triangles.items) |tri| {
        const p0 = mesh.vertices.items[tri[0]];
        const p1 = mesh.vertices.items[tri[1]];
        const p2 = mesh.vertices.items[tri[2]];

        var hit_pts = std.ArrayListUnmanaged([2]f64).empty;
        defer hit_pts.deinit(allocator);

        const edges = [_][2]math.Vec3{ .{ p0, p1 }, .{ p1, p2 }, .{ p2, p0 } };
        for (edges) |edge| {
            const z0 = edge[0][2];
            const z1 = edge[1][2];

            if ((z0 > z_height and z1 < z_height) or (z0 < z_height and z1 > z_height)) {
                const t = (z_height - z0) / (z1 - z0);
                const hx = edge[0][0] + t * (edge[1][0] - edge[0][0]);
                const hy = edge[0][1] + t * (edge[1][1] - edge[0][1]);
                try hit_pts.append(allocator, .{ hx, hy });
            } else if (z0 == z_height and z1 == z_height) {
                try hit_pts.append(allocator, .{ edge[0][0], edge[0][1] });
                try hit_pts.append(allocator, .{ edge[1][0], edge[1][1] });
            } else if (z0 == z_height) {
                try hit_pts.append(allocator, .{ edge[0][0], edge[0][1] });
            }
        }

        if (hit_pts.items.len >= 2) {
            var unique_pts = std.ArrayListUnmanaged([2]f64).empty;
            defer unique_pts.deinit(allocator);
            for (hit_pts.items) |pt| {
                var found = false;
                for (unique_pts.items) |u| {
                    if (@abs(u[0] - pt[0]) < 1e-5 and @abs(u[1] - pt[1]) < 1e-5) {
                        found = true;
                        break;
                    }
                }
                if (!found) try unique_pts.append(allocator, pt);
            }
            if (unique_pts.items.len == 2) {
                try segments.append(allocator, .{ unique_pts.items[0], unique_pts.items[1] });
            }
        }
    }

    var contours = std.ArrayListUnmanaged([]const [2]f64).empty;
    var used = try allocator.alloc(bool, segments.items.len);
    defer allocator.free(used);
    @memset(used, false);

    for (0..segments.items.len) |i| {
        if (used[i]) continue;
        used[i] = true;

        var loop = std.ArrayListUnmanaged([2]f64).empty;
        try loop.append(allocator, segments.items[i][0]);
        var current_pt = segments.items[i][1];

        while (true) {
            if (@abs(current_pt[0] - loop.items[0][0]) < 1e-4 and @abs(current_pt[1] - loop.items[0][1]) < 1e-4) {
                break; // Closed loop
            }
            try loop.append(allocator, current_pt);

            var found = false;
            for (0..segments.items.len) |j| {
                if (used[j]) continue;
                const seg = segments.items[j];

                if (@abs(seg[0][0] - current_pt[0]) < 1e-4 and @abs(seg[0][1] - current_pt[1]) < 1e-4) {
                    current_pt = seg[1];
                    used[j] = true;
                    found = true;
                    break;
                } else if (@abs(seg[1][0] - current_pt[0]) < 1e-4 and @abs(seg[1][1] - current_pt[1]) < 1e-4) {
                    current_pt = seg[0];
                    used[j] = true;
                    found = true;
                    break;
                }
            }
            if (!found) break; // Dead end
        }
        if (loop.items.len >= 3) {
            try contours.append(allocator, try loop.toOwnedSlice(allocator));
        } else {
            loop.deinit(allocator);
        }
    }

    return try contours.toOwnedSlice(allocator);
}
