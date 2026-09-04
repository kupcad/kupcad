const std = @import("std");
const eigen = @import("eigen.zig");

const IntersectContext = struct {
    circle_radius: f64,
};
const Linear1DContext = struct {};
const Linear2DContext = struct {};

fn evaluate1D(ctx: *Linear1DContext, x: []const f64, fvec: []f64) i32 {
    _ = ctx;
    // System: x - 5 = 0
    fvec[0] = x[0] - 5.0;
    return 0;
}

fn evaluateLinear2D(ctx: *Linear2DContext, x: []const f64, fvec: []f64) i32 {
    _ = ctx;
    // System:
    // x + y = 3
    // x - y = 1
    // Solution: x = 2, y = 1
    fvec[0] = (x[0] + x[1]) - 3.0;
    fvec[1] = (x[0] - x[1]) - 1.0;
    return 0;
}

fn evaluateIntersection(ctx: *IntersectContext, x: []const f64, fvec: []f64) i32 {
    const px = x[0];
    const py = x[1];

    // Residual 0: Circle equation: x^2 + y^2 - r^2 = 0
    fvec[0] = (px * px + py * py) - (ctx.circle_radius * ctx.circle_radius);

    // Residual 1: Line equation: y - x = 0
    fvec[1] = py - px;

    return 0; // 0 indicates success to Eigen
}

test "Levenberg-Marquardt: Non-Linear Circle/Line Intersection" {
    var ctx = IntersectContext{ .circle_radius = 2.0 };
    var vars = [_]f64{ 0.5, 0.1 };

    const status = eigen.minimizeNonLinear(
        IntersectContext,
        2, // num_residuals
        &vars,
        &ctx,
        evaluateIntersection,
        1e-6, // tolerance
        400, // max iterations
    );

    if (!status.isSuccess()) {
        std.debug.print("\n[Circle/Line Test] Solver Failed! Status: {s}, Final Vars: {any}\n", .{ @tagName(status), vars });
    }
    try std.testing.expect(status.isSuccess());

    const expected = @sqrt(2.0);
    try std.testing.expectApproxEqAbs(expected, vars[0], 1e-5);
    try std.testing.expectApproxEqAbs(expected, vars[1], 1e-5);
}

test "Levenberg-Marquardt: 1D Linear Root (Sanity Check)" {
    var ctx = Linear1DContext{};
    var vars = [_]f64{0.0};

    const status = eigen.minimizeNonLinear(Linear1DContext, 1, &vars, &ctx, evaluate1D, 1e-6, 100);

    if (!status.isSuccess()) {
        std.debug.print("\n[1D Test] Solver Failed! Status: {s}, Final Vars: {any}\n", .{ @tagName(status), vars });
    }
    try std.testing.expect(status.isSuccess());
    try std.testing.expectApproxEqAbs(5.0, vars[0], 1e-5);
}

test "Levenberg-Marquardt: 2D Linear System (Sanity Check)" {
    var ctx = Linear2DContext{};
    var vars = [_]f64{ 0.0, 0.0 };

    const status = eigen.minimizeNonLinear(Linear2DContext, 2, &vars, &ctx, evaluateLinear2D, 1e-6, 100);

    if (!status.isSuccess()) {
        std.debug.print("\n[2D Test] Solver Failed! Status: {s}, Final Vars: {any}\n", .{ @tagName(status), vars });
    }
    try std.testing.expect(status.isSuccess());
    try std.testing.expectApproxEqAbs(2.0, vars[0], 1e-5);
    try std.testing.expectApproxEqAbs(1.0, vars[1], 1e-5);
}
