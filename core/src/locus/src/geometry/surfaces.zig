const std = @import("std");
const math = @import("../math.zig");
const curves = @import("curves.zig");
const geom_types = @import("types.zig");
const geom_arena = @import("arena.zig");

pub const Plane = struct {
    origin: math.Vec3,
    u_axis: math.Vec3,
    v_axis: math.Vec3,
};

pub const Sphere = struct {
    center: math.Vec3,
    radius: f64,
};

pub const Cylinder = struct {
    origin: math.Vec3,
    axis: math.Vec3,
    x_axis: math.Vec3,
    y_axis: math.Vec3,
    radius: f64,
};

pub const Cone = struct {
    origin: math.Vec3,
    axis: math.Vec3,
    x_axis: math.Vec3,
    y_axis: math.Vec3,
    radius: f64,
    half_angle: f64,
};

pub const Torus = struct {
    center: math.Vec3,
    axis: math.Vec3,
    x_axis: math.Vec3,
    y_axis: math.Vec3,
    major_radius: f64,
    minor_radius: f64,
};

pub const NurbsSurface = struct {
    degree_u: usize,
    degree_v: usize,
    knots_u: []const f64,
    knots_v: []const f64,
    num_cp_u: usize,
    num_cp_v: usize,
    // Stored as a flat array: row-major (u changes fastest)
    control_points: []const math.Vec4,

    pub fn evaluate(self: NurbsSurface, u: f64, v: f64) math.Vec3 {
        var pt = math.Vec4{ 0, 0, 0, 0 };
        for (0..self.num_cp_v) |j| {
            const njq = curves.coxDeBoor(j, self.degree_v, v, self.knots_v);
            if (njq < 1e-12) continue;

            for (0..self.num_cp_u) |i| {
                const nip = curves.coxDeBoor(i, self.degree_u, u, self.knots_u);
                if (nip < 1e-12) continue;

                const basis = nip * njq;
                const idx = j * self.num_cp_u + i;
                const cp = self.control_points[idx];

                pt[0] += basis * cp[0];
                pt[1] += basis * cp[1];
                pt[2] += basis * cp[2];
                pt[3] += basis * cp[3];
            }
        }
        if (pt[3] > 1e-12) {
            return .{ pt[0] / pt[3], pt[1] / pt[3], pt[2] / pt[3] };
        }
        return .{ pt[0], pt[1], pt[2] };
    }
};

pub fn projectPointToSurface(
    g_arena: *const geom_arena.GeometryArena,
    id: geom_types.SurfaceId,
    pt: math.Vec3,
) math.Vec3 {
    const idx = @intFromEnum(id.index);
    switch (id.surface_type) {
        .plane => {
            const p = g_arena.planes.items[idx];
            const u_ax = math.normalize(p.u_axis);
            const v_ax = math.normalize(p.v_axis);
            var n = math.cross(u_ax, v_ax);
            const n_len = math.mag(n);
            if (n_len < math.MATH_EPSILON) return pt;
            n = math.scale(n, 1.0 / n_len);
            const dist = math.dot(n, math.sub(pt, p.origin));
            return math.sub(pt, math.scale(n, dist));
        },
        .sphere => {
            const s = g_arena.spheres.items[idx];
            const v = math.sub(pt, s.center);
            const len = math.mag(v);
            if (len < math.MATH_EPSILON) return math.add(s.center, .{ s.radius, 0, 0 });
            return math.add(s.center, math.scale(v, s.radius / len));
        },
        .cylinder => {
            const c = g_arena.cylinders.items[idx];
            const axis = math.normalize(c.axis);
            const v = math.sub(pt, c.origin);
            const z_val = math.dot(v, axis);
            const proj_axis = math.add(c.origin, math.scale(axis, z_val));
            const radial = math.sub(pt, proj_axis);
            const rad_len = math.mag(radial);
            if (rad_len < math.MATH_EPSILON) {
                const x_ax = if (math.magSq(c.x_axis) > math.MATH_EPSILON) math.normalize(c.x_axis) else .{ 1, 0, 0 };
                return math.add(proj_axis, math.scale(x_ax, c.radius));
            }
            return math.add(proj_axis, math.scale(radial, c.radius / rad_len));
        },
        .cone => {
            const c = g_arena.cones.items[idx];
            const axis = math.normalize(c.axis);
            const v = math.sub(pt, c.origin);
            const z_val = math.dot(v, axis);
            const proj_axis = math.add(c.origin, math.scale(axis, z_val));
            const radial = math.sub(pt, proj_axis);
            const rad_len = math.mag(radial);
            const r_at_z = c.radius + z_val * @tan(c.half_angle);
            if (rad_len < math.MATH_EPSILON) {
                const x_ax = if (math.magSq(c.x_axis) > math.MATH_EPSILON) math.normalize(c.x_axis) else .{ 1, 0, 0 };
                return math.add(proj_axis, math.scale(x_ax, r_at_z));
            }
            return math.add(proj_axis, math.scale(radial, r_at_z / rad_len));
        },
        .torus => {
            const t = g_arena.toruses.items[idx];
            const axis = math.normalize(t.axis);
            const v = math.sub(pt, t.center);
            const z_val = math.dot(v, axis);
            const proj_plane = math.sub(v, math.scale(axis, z_val));
            const proj_len = math.mag(proj_plane);
            const x_ax = if (math.magSq(t.x_axis) > math.MATH_EPSILON) math.normalize(t.x_axis) else .{ 1, 0, 0 };
            const tube_center = if (proj_len < math.MATH_EPSILON)
                math.add(t.center, math.scale(x_ax, t.major_radius))
            else
                math.add(t.center, math.scale(proj_plane, t.major_radius / proj_len));
            const to_pt = math.sub(pt, tube_center);
            const to_pt_len = math.mag(to_pt);
            if (to_pt_len < math.MATH_EPSILON) return tube_center;
            return math.add(tube_center, math.scale(to_pt, t.minor_radius / to_pt_len));
        },
        .nurbs => {
            if (idx >= g_arena.nurbs_surfaces.items.len) return pt;
            const surf = &g_arena.nurbs_surfaces.items[idx];

            var best_uv = math.Vec2{ 0.5, 0.5 };
            var min_d2: f64 = std.math.inf(f64);
            const steps: usize = 8;
            const u_min = surf.knots_u[0];
            const u_max = surf.knots_u[surf.knots_u.len - 1];
            const v_min = surf.knots_v[0];
            const v_max = surf.knots_v[surf.knots_v.len - 1];
            const du = (u_max - u_min) / @as(f64, @floatFromInt(steps));
            const dv = (v_max - v_min) / @as(f64, @floatFromInt(steps));

            for (0..steps + 1) |i| {
                const u = u_min + @as(f64, @floatFromInt(i)) * du;
                for (0..steps + 1) |j| {
                    const v = v_min + @as(f64, @floatFromInt(j)) * dv;
                    const eval_pt = surf.evaluate(u, v);
                    const d2 = math.distSq(pt, eval_pt);
                    if (d2 < min_d2) {
                        min_d2 = d2;
                        best_uv = .{ u, v };
                    }
                }
            }
            return surf.evaluate(best_uv[0], best_uv[1]);
        },
    }
}
