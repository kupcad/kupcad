const std = @import("std");
const math = @import("../math.zig");

pub const Line = struct {
    start: math.Vec3,
    end: math.Vec3,
};

pub const Line2D = struct {
    start: math.Vec2,
    end: math.Vec2,
};

pub const CircleArc = struct {
    center: math.Vec3,
    radius: f64,
    x_axis: math.Vec3,
    y_axis: math.Vec3,
};

pub const NurbsCurve = struct {
    degree: usize,
    knots: []const f64,
    // 4D homogeneous coordinates: { x*w, y*w, z*w, w }
    control_points: []const math.Vec4,

    pub fn evaluate(self: NurbsCurve, u: f64) math.Vec3 {
        var pt = math.Vec4{ 0, 0, 0, 0 };
        for (self.control_points, 0..) |cp, i| {
            const nip = coxDeBoor(i, self.degree, u, self.knots);
            pt[0] += nip * cp[0];
            pt[1] += nip * cp[1];
            pt[2] += nip * cp[2];
            pt[3] += nip * cp[3];
        }
        if (pt[3] > 1e-12) {
            return .{ pt[0] / pt[3], pt[1] / pt[3], pt[2] / pt[3] };
        }
        return .{ pt[0], pt[1], pt[2] };
    }
};

pub const NurbsCurve2D = struct {
    degree: usize,
    knots: []const f64,
    // 3D homogeneous coordinates for 2D points: { x*w, y*w, w }
    control_points: []const math.Vec3,

    pub fn evaluate(self: NurbsCurve2D, u: f64) math.Vec2 {
        var pt = math.Vec3{ 0, 0, 0 };
        for (self.control_points, 0..) |cp, i| {
            const nip = coxDeBoor(i, self.degree, u, self.knots);
            pt[0] += nip * cp[0];
            pt[1] += nip * cp[1];
            pt[2] += nip * cp[2];
        }
        if (pt[2] > 1e-12) {
            return .{ pt[0] / pt[2], pt[1] / pt[2] };
        }
        return .{ pt[0], pt[1] };
    }
};

pub fn coxDeBoor(i: usize, p: usize, u: f64, knots: []const f64) f64 {
    if (p == 0) {
        if (u == knots[knots.len - 1] and u == knots[i + 1] and knots[i] != knots[i + 1]) {
            return 1.0;
        }
        if (u >= knots[i] and u < knots[i + 1]) {
            return 1.0;
        }
        return 0.0;
    }

    const denom1 = knots[i + p] - knots[i];
    const term1 = if (denom1 > 1e-12) ((u - knots[i]) / denom1) * coxDeBoor(i, p - 1, u, knots) else 0.0;

    const denom2 = knots[i + p + 1] - knots[i + 1];
    const term2 = if (denom2 > 1e-12) ((knots[i + p + 1] - u) / denom2) * coxDeBoor(i + 1, p - 1, u, knots) else 0.0;

    return term1 + term2;
}
