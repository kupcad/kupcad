const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");

pub const IntersectionSeed = struct {
    t: f64,
    u: f64,
    v: f64,
};

pub const SurfaceSeed = struct {
    u_a: f64,
    v_a: f64,
    u_b: f64,
    v_b: f64,
};

pub const AABB = struct {
    min: math.Vec3,
    max: math.Vec3,

    pub fn empty() AABB {
        return .{
            .min = .{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) },
            .max = .{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) },
        };
    }

    pub fn expand(self: *AABB, pt: math.Vec3) void {
        self.min[0] = @min(self.min[0], pt[0]);
        self.min[1] = @min(self.min[1], pt[1]);
        self.min[2] = @min(self.min[2], pt[2]);
        self.max[0] = @max(self.max[0], pt[0]);
        self.max[1] = @max(self.max[1], pt[1]);
        self.max[2] = @max(self.max[2], pt[2]);
    }

    pub fn intersects(self: AABB, other: AABB) bool {
        return (self.min[0] <= other.max[0] and self.max[0] >= other.min[0]) and
            (self.min[1] <= other.max[1] and self.max[1] >= other.min[1]) and
            (self.min[2] <= other.max[2] and self.max[2] >= other.min[2]);
    }
};

/// Scans parametric space to find overlapping AABBs, generating seeds for the LM solver.
pub fn generateCurveSurfaceSeeds(
    allocator: std.mem.Allocator,
    curve: *const geom.NurbsCurve,
    surface: *const geom.NurbsSurface,
    curve_spans: usize,
    surf_spans: usize,
) ![]IntersectionSeed {
    var seeds: std.ArrayList(IntersectionSeed) = .empty;
    errdefer seeds.deinit(allocator);

    const t_min = curve.knots[0];
    const t_max = curve.knots[curve.knots.len - 1];
    const dt = (t_max - t_min) / @as(f64, @floatFromInt(curve_spans));

    const u_min = surface.knots_u[0];
    const u_max = surface.knots_u[surface.knots_u.len - 1];
    const du = (u_max - u_min) / @as(f64, @floatFromInt(surf_spans));

    const v_min = surface.knots_v[0];
    const v_max = surface.knots_v[surface.knots_v.len - 1];
    const dv = (v_max - v_min) / @as(f64, @floatFromInt(surf_spans));

    for (0..curve_spans) |i| {
        const t_val = t_min + @as(f64, @floatFromInt(i)) * dt;
        var c_box = AABB.empty();
        c_box.expand(curve.evaluate(t_val));
        c_box.expand(curve.evaluate(t_val + dt * 0.5));
        c_box.expand(curve.evaluate(t_val + dt));

        for (0..surf_spans) |j| {
            const u_val = u_min + @as(f64, @floatFromInt(j)) * du;
            for (0..surf_spans) |k| {
                const v_val = v_min + @as(f64, @floatFromInt(k)) * dv;

                var s_box = AABB.empty();
                s_box.expand(surface.evaluate(u_val, v_val));
                s_box.expand(surface.evaluate(u_val + du, v_val));
                s_box.expand(surface.evaluate(u_val, v_val + dv));
                s_box.expand(surface.evaluate(u_val + du, v_val + dv));

                if (c_box.intersects(s_box)) {
                    // Explicitly pass the allocator to append
                    try seeds.append(allocator, .{
                        .t = t_val + dt * 0.5,
                        .u = u_val + du * 0.5,
                        .v = v_val + dv * 0.5,
                    });
                }
            }
        }
    }

    // Explicitly pass the allocator to toOwnedSlice
    return seeds.toOwnedSlice(allocator);
}

/// Scans parametric space to find overlapping AABBs between two NURBS surfaces.
pub fn generateSurfaceSurfaceSeeds(
    allocator: std.mem.Allocator,
    surf_a: *const geom.NurbsSurface,
    surf_b: *const geom.NurbsSurface,
    spans: usize,
) ![]SurfaceSeed {
    var seeds: std.ArrayListUnmanaged(SurfaceSeed) = .empty;
    errdefer seeds.deinit(allocator);

    const du_a = (surf_a.knots_u[surf_a.knots_u.len - 1] - surf_a.knots_u[0]) / @as(f64, @floatFromInt(spans));
    const dv_a = (surf_a.knots_v[surf_a.knots_v.len - 1] - surf_a.knots_v[0]) / @as(f64, @floatFromInt(spans));
    const du_b = (surf_b.knots_u[surf_b.knots_u.len - 1] - surf_b.knots_u[0]) / @as(f64, @floatFromInt(spans));
    const dv_b = (surf_b.knots_v[surf_b.knots_v.len - 1] - surf_b.knots_v[0]) / @as(f64, @floatFromInt(spans));

    for (0..spans) |ia| {
        const u_a = surf_a.knots_u[0] + @as(f64, @floatFromInt(ia)) * du_a;
        for (0..spans) |ja| {
            const v_a = surf_a.knots_v[0] + @as(f64, @floatFromInt(ja)) * dv_a;
            var box_a = AABB.empty();
            box_a.expand(surf_a.evaluate(u_a, v_a));
            box_a.expand(surf_a.evaluate(u_a + du_a, v_a));
            box_a.expand(surf_a.evaluate(u_a, v_a + dv_a));
            box_a.expand(surf_a.evaluate(u_a + du_a, v_a + dv_a));

            for (0..spans) |ib| {
                const u_b = surf_b.knots_u[0] + @as(f64, @floatFromInt(ib)) * du_b;
                for (0..spans) |jb| {
                    const v_b = surf_b.knots_v[0] + @as(f64, @floatFromInt(jb)) * dv_b;
                    var box_b = AABB.empty();
                    box_b.expand(surf_b.evaluate(u_b, v_b));
                    box_b.expand(surf_b.evaluate(u_b + du_b, v_b));
                    box_b.expand(surf_b.evaluate(u_b, v_b + dv_b));
                    box_b.expand(surf_b.evaluate(u_b + du_b, v_b + dv_b));

                    if (box_a.intersects(box_b)) {
                        try seeds.append(allocator, .{
                            .u_a = u_a + du_a * 0.5,
                            .v_a = v_a + dv_a * 0.5,
                            .u_b = u_b + du_b * 0.5,
                            .v_b = v_b + dv_b * 0.5,
                        });
                    }
                }
            }
        }
    }

    return seeds.toOwnedSlice(allocator);
}
