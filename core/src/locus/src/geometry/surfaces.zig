const std = @import("std");
const math = @import("../math.zig");
const curves = @import("curves.zig");

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
