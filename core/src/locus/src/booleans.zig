const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const BooleanOp = enum { union_op, difference, intersection };

pub const BooleanError = error{
    OutOfMemory,
    DidNotConverge,
};

/// Snaps a 3D point exactly onto the intersection curve of two surfaces.
fn snapToIntersection(
    g_arena: *const geom.GeometryArena,
    id_a: geom.SurfaceId,
    id_b: geom.SurfaceId,
    guess: math.Vec3,
    tolerance: f64,
) ?math.Vec3 {
    var pt = guess;
    for (0..10) |_| {
        // Project onto A via centralized dispatcher
        const uv_a = g_arena.surfaceProject(id_a, pt);
        const pt_a = g_arena.surfaceSubs(id_a, uv_a[0], uv_a[1]);

        // Project onto B via centralized dispatcher
        const uv_b = g_arena.surfaceProject(id_b, pt_a);
        const pt_b = g_arena.surfaceSubs(id_b, uv_b[0], uv_b[1]);

        if (math.distSq(pt, pt_b) < tolerance * tolerance) {
            return pt_b;
        }
        pt = pt_b;
    }
    return null;
}

/// Computes the intersection curve between two surfaces using the Marching Algorithm.
pub fn marchIntersection(
    allocator: std.mem.Allocator,
    g_arena: *geom.GeometryArena,
    surf_a_id: geom.SurfaceId,
    surf_b_id: geom.SurfaceId,
    start_pt: math.Vec3,
    step_size: f64,
    max_steps: u32,
    tolerance: f64,
) BooleanError!geom.CurveId {
    var points: std.ArrayListUnmanaged(math.Vec3) = .empty;
    defer points.deinit(allocator);

    var current_pt = start_pt;
    try points.append(allocator, current_pt);

    for (0..max_steps) |_| {
        // 1. Get exact parameters via dispatch
        const uv_a = g_arena.surfaceProject(surf_a_id, current_pt);
        const uv_b = g_arena.surfaceProject(surf_b_id, current_pt);

        // 2. Evaluate normals via dispatch
        const normal_a = g_arena.surfaceNormal(surf_a_id, uv_a[0], uv_a[1]);
        const normal_b = g_arena.surfaceNormal(surf_b_id, uv_b[0], uv_b[1]);

        // 3. Tangent of intersection
        const tangent = math.normalize(math.cross(normal_a, normal_b));
        if (math.magSq(tangent) < math.MATH_EPSILON) break;

        // 4. Step forward
        const next_guess = math.add(current_pt, math.scale(tangent, step_size));

        // 5. Snap back to intersection seam
        current_pt = snapToIntersection(g_arena, surf_a_id, surf_b_id, next_guess, tolerance) orelse return error.DidNotConverge;

        try points.append(allocator, current_pt);

        if (points.items.len > 3 and math.distSq(current_pt, start_pt) < tolerance * tolerance) {
            break;
        }
    }

    // Dummy return, but wrapped in the new packed struct ID type
    return geom.CurveId{ .index = @intCast(g_arena.lines.items.len), .curve_type = .line };
}

pub fn computeBoolean(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_a: topo.SolidId,
    solid_b: topo.SolidId,
    op: BooleanOp,
    config: anytype,
) BooleanError!topo.SolidId {
    _ = allocator;
    _ = t_arena;
    _ = g_arena;
    _ = solid_b;
    _ = op;
    _ = config;
    return solid_a;
}
