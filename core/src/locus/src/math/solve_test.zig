const std = @import("std");
const testing = std.testing;
const vec = @import("vec.zig");
const mat = @import("mat.zig");
const solve = @import("solve.zig");
const Vec3 = vec.Vec3;

test "solve.newtonScalar: the square root of two, and a flat function is singular" {
    const Sqrt = struct {
        fn f(_: void, t: f64) solve.Scalar {
            return .{ .f = t * t - 2.0, .df = 2.0 * t };
        }
    };
    const r = solve.newtonScalar({}, Sqrt.f, 1.0, .{ 0, 10 }, 1e-14, 1e-15, 50);
    try testing.expectEqual(solve.Outcome.converged, r.outcome);
    try testing.expectApproxEqAbs(@sqrt(2.0), r.t, 1e-14);

    const Flat = struct {
        fn f(_: void, _: f64) solve.Scalar {
            return .{ .f = 1.0, .df = 0.0 };
        }
    };
    try testing.expectEqual(solve.Outcome.singular, solve.newtonScalar({}, Flat.f, 1.0, .{ 0, 10 }, 1e-14, 1e-15, 50).outcome);

    const Slow = struct {
        fn f(_: void, t: f64) solve.Scalar {
            // f = (t − 3)³: Newton converges linearly; few steps don't reach 1e-14
            const d = t - 3.0;
            return .{ .f = d * d * d, .df = 3.0 * d * d };
        }
    };
    try testing.expectEqual(solve.Outcome.exhausted, solve.newtonScalar({}, Slow.f, 10.0, .{ 0, 100 }, 1e-30, 0, 3).outcome);
}

const Circle = struct {
    r: f64,
    fn sample(self: Circle, t: f64) solve.CurveSample {
        return .{
            .p = .{ self.r * @cos(t), self.r * @sin(t), 0 },
            .d1 = .{ -self.r * @sin(t), self.r * @cos(t), 0 },
            .d2 = .{ -self.r * @cos(t), -self.r * @sin(t), 0 },
        };
    }
};

test "solve.projectToCurve: the nearest point of a circle, wrapping around its seam" {
    const circle = Circle{ .r = 5 };
    const domain = solve.CurveDomain{ .range = .{ 0, 2 * std.math.pi }, .periodic = true };
    const r = solve.projectToCurve(circle, Circle.sample, .{ 10, 10, 3 }, 0.5, domain, 1e-12, 1e-12, 50);
    try testing.expectEqual(solve.Outcome.converged, r.outcome);
    try testing.expectApproxEqAbs(std.math.pi / 4.0, r.t, 1e-12);
    try testing.expectApproxEqAbs(@sqrt(200.0) - 5.0, @sqrt(r.distance * r.distance - 9.0), 1e-9);
    // A target near the seam from a start on the other side
    const s = solve.projectToCurve(circle, Circle.sample, .{ 5, -0.1, 0 }, 6.0, domain, 1e-12, 1e-12, 50);
    try testing.expectEqual(solve.Outcome.converged, s.outcome);
    try testing.expectApproxEqAbs(2 * std.math.pi + std.math.atan2(@as(f64, -0.1), @as(f64, 5)), s.t, 1e-9);
    // A target at the centre: every point is nearest, the tangent test (2) passes at once
    const c = solve.projectToCurve(circle, Circle.sample, .{ 0, 0, 0 }, 1.0, domain, 1e-12, 1e-12, 50);
    try testing.expectEqual(solve.Outcome.converged, c.outcome);
    try testing.expectApproxEqAbs(@as(f64, 5), c.distance, 1e-12);
}

const Sphere = struct {
    r: f64,
    fn sample(self: Sphere, u: f64, v: f64) solve.SurfaceSample {
        const cu = @cos(u);
        const su = @sin(u);
        const cv = @cos(v);
        const sv = @sin(v);
        return .{
            .p = .{ self.r * cv * cu, self.r * cv * su, self.r * sv },
            .du = .{ -self.r * cv * su, self.r * cv * cu, 0 },
            .dv = .{ -self.r * sv * cu, -self.r * sv * su, self.r * cv },
            .duu = .{ -self.r * cv * cu, -self.r * cv * su, 0 },
            .duv = .{ self.r * sv * su, -self.r * sv * cu, 0 },
            .dvv = .{ -self.r * cv * cu, -self.r * cv * su, -self.r * sv },
        };
    }
};

test "solve.projectToSurface: the nearest point of a sphere" {
    const sphere = Sphere{ .r = 2 };
    const domain = solve.SurfaceDomain{
        .u = .{ .range = .{ 0, 2 * std.math.pi }, .periodic = true },
        .v = .{ .range = .{ -std.math.pi / 2.0, std.math.pi / 2.0 } },
    };
    const target = Vec3{ 3, 3, 3 };
    const r = solve.projectToSurface(sphere, Sphere.sample, target, .{ 0.5, 0.5 }, domain, 1e-12, 1e-12, 50);
    try testing.expectEqual(solve.Outcome.converged, r.outcome);
    try testing.expectApproxEqAbs(std.math.pi / 4.0, r.uv[0], 1e-9);
    try testing.expectApproxEqAbs(std.math.atan(@as(f64, 1.0 / @sqrt(2.0))), r.uv[1], 1e-9);
    try testing.expectApproxEqAbs(@sqrt(27.0) - 2.0, r.distance, 1e-9);
}

test "solve.levenbergMarquardt: where a circle meets a line, and a circle fitted to points" {
    const Meet = struct {
        radius: f64,
        fn residuals(self: @This(), x: *const [2]f64, out: *[2]f64) void {
            out[0] = x[0] * x[0] + x[1] * x[1] - self.radius * self.radius;
            out[1] = x[1] - x[0];
        }
    };
    var xy = [2]f64{ 1.0, 0.5 };
    const r = solve.levenbergMarquardt(2, 2, Meet{ .radius = 5 }, Meet.residuals, &xy, 1e-10, 1e-14, 100);
    try testing.expectEqual(solve.Outcome.converged, r.outcome);
    try testing.expectApproxEqAbs(5.0 / @sqrt(2.0), xy[0], 1e-7);
    try testing.expectApproxEqAbs(5.0 / @sqrt(2.0), xy[1], 1e-7);

    // Six points on the circle of centre (3, −2), radius 4: fit (cx, cy, r) from a guess
    const Fit = struct {
        fn residuals(_: void, x: *const [3]f64, out: *[6]f64) void {
            for (0..6) |i| {
                const a = @as(f64, @floatFromInt(i)) * 1.0;
                const px = 3.0 + 4.0 * @cos(a);
                const py = -2.0 + 4.0 * @sin(a);
                out[i] = @sqrt((px - x[0]) * (px - x[0]) + (py - x[1]) * (py - x[1])) - x[2];
            }
        }
    };
    var guess = [3]f64{ 0, 0, 1 };
    const f = solve.levenbergMarquardt(3, 6, {}, Fit.residuals, &guess, 1e-9, 1e-12, 200);
    try testing.expectEqual(solve.Outcome.converged, f.outcome);
    try testing.expectApproxEqAbs(@as(f64, 3), guess[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -2), guess[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 4), guess[2], 1e-6);
}

test "solve.jacobiSymmetric3: known eigenvalues, ordered, with orthonormal vectors" {
    // A matrix with eigenvalues 1, 2, 3 (diagonal in a rotated frame)
    const m = mat.Mat3{ 2, 0, 1, 0, 2, 0, 1, 0, 2 }; // eigenvalues 1, 2, 3
    const e = solve.jacobiSymmetric3(&m, 1e-15, 32);
    try testing.expectApproxEqAbs(@as(f64, 1), e.values[0], 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 2), e.values[1], 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 3), e.values[2], 1e-14);
    for (e.vectors, e.values) |v, lambda| {
        try testing.expectApproxEqAbs(@as(f64, 1), vec.length(v), 1e-14);
        // M·v = λ·v
        const mv = mat.apply3(&m, v);
        for (0..3) |k| try testing.expectApproxEqAbs(lambda * v[k], mv[k], 1e-13);
    }
    try testing.expectApproxEqAbs(@as(f64, 0), vec.dot(e.vectors[0], e.vectors[1]), 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 0), vec.dot(e.vectors[1], e.vectors[2]), 1e-14);
}

test "solve.fitPlaneNormal: the plane z = x + y, and a line has none" {
    const pts = [_]Vec3{ .{ 0, 0, 0 }, .{ 10, 0, 10 }, .{ 0, 10, 10 }, .{ 10, 10, 20 } };
    const n = solve.fitPlaneNormal(&pts, 1e-12).?;
    const expected = vec.normalized(.{ 1, 1, -1 }).?;
    try testing.expectApproxEqAbs(@as(f64, 1), @abs(vec.dot(n, expected)), 1e-12);
    const line = [_]Vec3{ .{ 0, 0, 0 }, .{ 1, 1, 1 }, .{ 2, 2, 2 }, .{ 3, 3, 3 } };
    try testing.expectEqual(@as(?Vec3, null), solve.fitPlaneNormal(&line, 1e-12));
    try testing.expectEqual(@as(?Vec3, null), solve.fitPlaneNormal(pts[0..2], 1e-12));
}
