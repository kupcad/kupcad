const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const types = @import("types.zig");
const nurbs = @import("nurbs.zig");
const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;

const H: f64 = 1e-6;
/// The step for second differences: rounding error grows as 1/H², truncation as H².
const H2: f64 = 1e-4;

fn expectVec(expected: Vec3, actual: Vec3, tol: f64) !void {
    for (0..3) |k| try testing.expectApproxEqAbs(expected[k], actual[k], tol);
}

test "findSpan and basisFuns: the book's example (Ex 2.3), and the end of the domain" {
    // U = {0,0,0,1,2,3,4,4,5,5,5}, p = 2, n = 7: at u = 5/2 the span is 4 and the basis
    // functions N_{2,2}, N_{3,2}, N_{4,2} are 1/8, 6/8, 1/8
    const knots = [_]f64{ 0, 0, 0, 1, 2, 3, 4, 4, 5, 5, 5 };
    const span = nurbs.findSpan(7, 2, 2.5, &knots);
    try testing.expectEqual(@as(usize, 4), span);
    var basis: nurbs.Basis = undefined;
    nurbs.basisFuns(span, 2.5, 2, &knots, &basis);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 8.0), basis[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 6.0 / 8.0), basis[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 8.0), basis[2], 1e-15);
    // u = U[n+1] = 5 gives the last span n, not past it; u = U[p] the first
    try testing.expectEqual(@as(usize, 7), nurbs.findSpan(7, 2, 5, &knots));
    try testing.expectEqual(@as(usize, 2), nurbs.findSpan(7, 2, 0, &knots));
    try testing.expectEqual(@as(usize, 7), nurbs.findSpan(7, 2, 4, &knots)); // at a double knot: the span after it
    // The basis functions sum to one everywhere
    var u: f64 = 0;
    while (u <= 5) : (u += 0.37) {
        const s = nurbs.findSpan(7, 2, u, &knots);
        nurbs.basisFuns(s, u, 2, &knots, &basis);
        try testing.expectApproxEqAbs(@as(f64, 1), basis[0] + basis[1] + basis[2], 1e-14);
    }
}

test "dersBasisFuns: derivatives match the basis functions' differences and sum to zero" {
    const knots = [_]f64{ 0, 0, 0, 0, 1, 2, 3, 4, 5, 5, 5, 5 };
    const p: usize = 3;
    const n: usize = 7;
    var u: f64 = 0.3;
    while (u < 5) : (u += 0.61) {
        const span = nurbs.findSpan(n, p, u, &knots);
        var ders: nurbs.BasisDers = undefined;
        nurbs.dersBasisFuns(span, u, p, 2, &knots, &ders);
        var plus: nurbs.Basis = undefined;
        var minus: nurbs.Basis = undefined;
        nurbs.basisFuns(span, u + H, p, &knots, &plus);
        nurbs.basisFuns(span, u - H, p, &knots, &minus);
        var sum1: f64 = 0;
        var sum2: f64 = 0;
        for (0..p + 1) |j| {
            try testing.expectApproxEqAbs(ders[0][j], (plus[j] + minus[j]) / 2.0, 1e-9);
            try testing.expectApproxEqAbs((plus[j] - minus[j]) / (2.0 * H), ders[1][j], 1e-6);
            try testing.expectApproxEqAbs((plus[j] - 2.0 * ders[0][j] + minus[j]) / (H * H), ders[2][j], 1e-3);
            sum1 += ders[1][j];
            sum2 += ders[2][j];
        }
        try testing.expectApproxEqAbs(@as(f64, 0), sum1, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0), sum2, 1e-9);
    }
}

test "circleArc: the nine-point full circle (Ex 7.2) lies on the circle and derivatives match" {
    var arc = try nurbs.circleArc(testing.allocator, .{ 1, 2, 3 }, vec.X3, vec.Y3, 5, 0, types.TWO_PI);
    defer arc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 9), arc.points.len);
    try testing.expectEqual(@as(usize, 12), arc.knots.len);
    try testing.expect(arc.view().isValid());
    // The middle weights are cos 45°
    try testing.expectApproxEqAbs(@sqrt(2.0) / 2.0, arc.points[1][3], 1e-15);
    try testing.expectEqual(@as(f64, 1), arc.points[2][3]);
    const c = arc.view();
    var t: f64 = 0.05;
    while (t < types.TWO_PI) : (t += 0.1) {
        const p = c.eval(t);
        try testing.expectApproxEqAbs(@as(f64, 5), vec.distance(p, .{ 1, 2, 3 }), 1e-12);
        const s = c.sample(t);
        try expectVec(p, s.p, 1e-12);
        // The tangent is perpendicular to the radius and turns counter-clockwise
        try testing.expectApproxEqAbs(@as(f64, 0), vec.dot(s.d1, vec.sub(p, .{ 1, 2, 3 })), 1e-9);
        try testing.expect(vec.dot(vec.cross(vec.sub(p, .{ 1, 2, 3 }), s.d1), vec.Z3) > 0);
        const d1 = vec.scale(vec.sub(c.eval(t + H), c.eval(t - H)), 1.0 / (2.0 * H));
        try expectVec(d1, s.d1, 1e-6);
        const d2 = vec.scale(vec.add(vec.sub(c.eval(t + H2), vec.scale(c.eval(t), 2.0)), c.eval(t - H2)), 1.0 / (H2 * H2));
        try expectVec(d2, s.d2, 1e-5);
    }
    // The parameter is the angle at the pieces' ends and middles (the pieces are symmetric)
    try expectVec(.{ 6, 2, 3 }, c.eval(types.TWO_PI), 1e-12);
    try expectVec(.{ 1, 7, 3 }, c.eval(std.math.pi / 2.0), 1e-12);
    try expectVec(.{ 1 + 5 * @cos(std.math.pi / 4.0), 2 + 5 * @sin(std.math.pi / 4.0), 3 }, c.eval(std.math.pi / 4.0), 1e-12);
    // Projection finds the parameter of the nearest point: the quarter point, where the
    // parameter is the angle
    try testing.expectApproxEqAbs(std.math.pi / 2.0, c.project(.{ 1, 9, 9 }, 1e-12, 50), 1e-9);
    // The box of the whole circle, from its control points, holds it with room
    const box = c.bounds(0, types.TWO_PI);
    try testing.expect(box.min[0] <= -4 and box.max[0] >= 6 and box.min[1] <= -3 and box.max[1] >= 7);
}

test "circleArc: a short arc is one piece, ellipseArc is the circle mapped" {
    var arc = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 1, 0.5, 1.5);
    defer arc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), arc.points.len);
    try testing.expectApproxEqAbs(@cos(0.5), arc.points[1][3], 1e-15);
    try expectVec(.{ @cos(1.0), @sin(1.0), 0 }, arc.view().eval(1.0), 1e-12); // the middle
    try expectVec(.{ @cos(1.5), @sin(1.5), 0 }, arc.view().eval(1.5), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), vec.length(arc.view().eval(0.8)), 1e-12);

    var ell = try nurbs.ellipseArc(testing.allocator, .{ 1, 0, 0 }, vec.X3, vec.Y3, 4, 2, 0, std.math.pi);
    defer ell.deinit(testing.allocator);
    var t: f64 = 0;
    while (t <= std.math.pi) : (t += 0.2) {
        // On the ellipse: ((x − 1) / 4)² + (y / 2)² = 1
        const p = ell.view().eval(t);
        try testing.expectApproxEqAbs(@as(f64, 1), ((p[0] - 1) / 4) * ((p[0] - 1) / 4) + (p[1] / 2) * (p[1] / 2), 1e-12);
    }
    try expectVec(.{ 1, 2, 0 }, ell.view().eval(std.math.pi / 2.0), 1e-12);
    try expectVec(.{ -3, 0, 0 }, ell.view().eval(std.math.pi), 1e-12);
}

test "lineSegment and reverse: the same points the other way" {
    var seg = try nurbs.lineSegment(testing.allocator, .{ 0, 0, 0 }, .{ 10, 0, 0 }, 0, 10);
    defer seg.deinit(testing.allocator);
    try expectVec(.{ 3, 0, 0 }, seg.view().eval(3), 1e-15);
    seg.reverse();
    try expectVec(.{ 7, 0, 0 }, seg.view().eval(3), 1e-15);
    var arc = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 1, 0, 1);
    defer arc.deinit(testing.allocator);
    const before = arc.view().eval(0.3);
    arc.reverse();
    try expectVec(before, arc.view().eval(1 - 0.3), 1e-12);
    try testing.expect(arc.view().isValid());
}

/// A cubic test curve with interior knots.
fn testCubic(allocator: std.mem.Allocator) !nurbs.CurveData {
    const knots = try allocator.dupe(f64, &.{ 0, 0, 0, 0, 1, 2, 3, 4, 5, 5, 5, 5 });
    errdefer allocator.free(knots);
    const points = try allocator.dupe(Vec4, &.{
        .{ 0, 0, 0, 1 }, .{ 1, 2, 0, 1 }, .{ 3, 3, 1, 1 }, .{ 4, 1, 2, 1 }, .{ 6, 0, 2, 1 }, .{ 7, 2, 1, 1 }, .{ 9, 3, 0, 1 }, .{ 10, 0, 0, 1 },
    });
    return .{ .degree = 3, .knots = knots, .points = points };
}

fn expectSameCurve(a: nurbs.Curve, b: nurbs.Curve) !void {
    var t: f64 = a.domain().t0;
    while (t <= a.domain().t1) : (t += 0.173) try expectVec(a.eval(t), b.eval(t), 1e-12);
    try expectVec(a.eval(a.domain().t1), b.eval(b.domain().t1), 1e-12);
}

test "insertKnot (A5.1): the curve is unchanged, with r more control points" {
    var cubic = try testCubic(testing.allocator);
    defer cubic.deinit(testing.allocator);
    try testing.expect(cubic.view().isValid());
    var once = try cubic.insertKnot(testing.allocator, 2.5, 1);
    defer once.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 9), once.points.len);
    try testing.expectEqual(@as(usize, 13), once.knots.len);
    try testing.expect(once.view().isValid());
    try expectSameCurve(cubic.view(), once.view());
    // Three times: the knot becomes a corner of the control polygon (a point on the curve)
    var thrice = try cubic.insertKnot(testing.allocator, 2.5, 3);
    defer thrice.deinit(testing.allocator);
    try testing.expect(thrice.view().isValid());
    try expectSameCurve(cubic.view(), thrice.view());
    // With multiplicity p at u the curve passes through a control point: the one at the
    // last copy's index less p (knots 6, 7, 8 hold 2.5 → Q_5)
    try expectVec(cubic.view().eval(2.5), vec.project4(thrice.points[5]), 1e-12);
    // At an existing knot, up to multiplicity p
    var at_knot = try cubic.insertKnot(testing.allocator, 2.0, 2);
    defer at_knot.deinit(testing.allocator);
    try expectSameCurve(cubic.view(), at_knot.view());
}

test "refineKnots (A5.4): several knots in one pass, the curve unchanged" {
    var cubic = try testCubic(testing.allocator);
    defer cubic.deinit(testing.allocator);
    var refined = try cubic.refineKnots(testing.allocator, &.{ 0.5, 1.5, 1.5, 2.5, 4.5 });
    defer refined.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 13), refined.points.len);
    try testing.expect(refined.view().isValid());
    try expectSameCurve(cubic.view(), refined.view());
    var none = try cubic.refineKnots(testing.allocator, &.{});
    defer none.deinit(testing.allocator);
    try expectSameCurve(cubic.view(), none.view());
}

test "segment: the piece of a curve over a range is the curve there, clamped" {
    var cubic = try testCubic(testing.allocator);
    defer cubic.deinit(testing.allocator);
    var piece = try cubic.segment(testing.allocator, 1.5, 3.5);
    defer piece.deinit(testing.allocator);
    try testing.expect(piece.view().isValid());
    try testing.expectEqual(@as(f64, 1.5), piece.view().domain().t0);
    try testing.expectEqual(@as(f64, 3.5), piece.view().domain().t1);
    var t: f64 = 1.5;
    while (t <= 3.5) : (t += 0.125) try expectVec(cubic.view().eval(t), piece.view().eval(t), 1e-12);
    try expectVec(cubic.view().eval(1.5), vec.project4(piece.points[0]), 1e-12);
    try expectVec(cubic.view().eval(3.5), vec.project4(piece.points[piece.points.len - 1]), 1e-12);
    // From the start of the domain, and the whole domain
    var head = try cubic.segment(testing.allocator, 0, 2);
    defer head.deinit(testing.allocator);
    try expectVec(cubic.view().eval(0.7), head.view().eval(0.7), 1e-12);
    var whole = try cubic.segment(testing.allocator, 0, 5);
    defer whole.deinit(testing.allocator);
    try testing.expectEqual(cubic.points.len, whole.points.len);
    try expectSameCurve(cubic.view(), whole.view());
}

test "surface refineKnots (A5.5) and segment: the same surface" {
    var meridian = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Z3, 3, -std.math.pi / 2.0, std.math.pi / 2.0);
    defer meridian.deinit(testing.allocator);
    var sphere = try nurbs.revolution(testing.allocator, meridian.view(), vec.ZERO3, vec.Z3, 0, types.TWO_PI);
    defer sphere.deinit(testing.allocator);
    var in_u = try sphere.refineKnots(testing.allocator, .u, &.{ 0.5, 2.0, 2.0 });
    defer in_u.deinit(testing.allocator);
    try testing.expect(in_u.view().isValid());
    try testing.expectEqual(@as(u32, 12), in_u.count_u);
    var in_v = try in_u.refineKnots(testing.allocator, .v, &.{ -1.0, 0.5 });
    defer in_v.deinit(testing.allocator);
    try testing.expect(in_v.view().isValid());
    try testing.expectEqual(@as(u32, 7), in_v.count_v);
    var u: f64 = 0;
    while (u <= types.TWO_PI) : (u += 0.37) {
        var v: f64 = -std.math.pi / 2.0;
        while (v <= std.math.pi / 2.0) : (v += 0.29) try expectVec(sphere.view().eval(u, v), in_v.view().eval(u, v), 1e-12);
    }
    const box = types.Box2{ .min = .{ 0.5, -1.0 }, .max = .{ 2.5, 1.2 } };
    var patch = try sphere.segment(testing.allocator, box);
    defer patch.deinit(testing.allocator);
    try testing.expect(patch.view().isValid());
    try testing.expectEqual(@as(f64, 0.5), patch.view().domainU().t0);
    try testing.expectEqual(@as(f64, 2.5), patch.view().domainU().t1);
    try testing.expectEqual(@as(f64, -1.0), patch.view().domainV().t0);
    try testing.expectEqual(@as(f64, 1.2), patch.view().domainV().t1);
    u = 0.5;
    while (u <= 2.5) : (u += 0.25) {
        var v: f64 = -1.0;
        while (v <= 1.2) : (v += 0.2) try expectVec(sphere.view().eval(u, v), patch.view().eval(u, v), 1e-12);
    }
}

test "decompose (A5.6): the Bézier segments evaluate as the curve span by span" {
    var cubic = try testCubic(testing.allocator);
    defer cubic.deinit(testing.allocator);
    const segments = try cubic.decompose(testing.allocator);
    defer {
        for (segments) |s| testing.allocator.free(s);
        testing.allocator.free(segments);
    }
    try testing.expectEqual(@as(usize, 5), segments.len);
    for (segments, 0..) |seg, i| {
        // A Bézier segment over [i, i+1]: a clamped cubic with no interior knots
        const a: f64 = @floatFromInt(i);
        const knots = [_]f64{ a, a, a, a, a + 1, a + 1, a + 1, a + 1 };
        const bez = nurbs.Curve{ .degree = 3, .knots = &knots, .points = seg };
        var t: f64 = a;
        while (t <= a + 1) : (t += 0.25) try expectVec(cubic.view().eval(t), bez.eval(t), 1e-12);
        // Segments share their ends
        if (i > 0) try expectVec(vec.project4(segments[i - 1][3]), vec.project4(seg[0]), 1e-12);
    }
}

test "knotsValid: what a clamped knot vector is" {
    try testing.expect(nurbs.knotsValid(&.{ 0, 0, 0, 1, 1, 1 }, 2));
    try testing.expect(nurbs.knotsValid(&.{ 0, 0, 0, 0.5, 0.5, 1, 1, 1 }, 2));
    try testing.expect(!nurbs.knotsValid(&.{ 0, 0, 0, 0.5, 0.5, 0.5, 1, 1, 1 }, 2)); // interior multiplicity 3 > p
    try testing.expect(!nurbs.knotsValid(&.{ 0, 0, 1, 1, 1 }, 2)); // start not clamped
    try testing.expect(!nurbs.knotsValid(&.{ 0, 0, 0, 1, 0.5, 1, 1, 1 }, 2)); // decreasing
    try testing.expect(!nurbs.knotsValid(&.{ 0, 0, 0, 0, 0, 0 }, 2)); // empty domain
    try testing.expect(!nurbs.knotsValid(&.{ 0, 0, 0, std.math.nan(f64), 1, 1, 1 }, 2));
}

test "bilinear and extrusion: a plane patch and a cylinder as NURBS evaluate exactly" {
    var patch = try nurbs.bilinear(testing.allocator, .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 0, 3, 0 }, .{ 2, 3, 0 }, .{ 0, 2 }, .{ 0, 3 });
    defer patch.deinit(testing.allocator);
    try testing.expect(patch.view().isValid());
    try expectVec(.{ 1.5, 1, 0 }, patch.view().eval(1.5, 1), 1e-15);
    const s = patch.view().sample(0.5, 0.5);
    try expectVec(vec.X3, s.du, 1e-15);
    try expectVec(vec.Y3, s.dv, 1e-15);

    var circle = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 2, 0, types.TWO_PI);
    defer circle.deinit(testing.allocator);
    var cyl = try nurbs.extrusion(testing.allocator, circle.view(), vec.Z3, 0, 5);
    defer cyl.deinit(testing.allocator);
    try testing.expect(cyl.view().isValid());
    var u: f64 = 0;
    while (u <= types.TWO_PI) : (u += 0.3) {
        const p = cyl.view().eval(u, 3);
        try testing.expectApproxEqAbs(@as(f64, 2), @sqrt(p[0] * p[0] + p[1] * p[1]), 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 3), p[2], 1e-12);
        const d = cyl.view().sample(u, 3);
        try expectVec(vec.Z3, d.dv, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0), vec.dot(d.du, .{ p[0], p[1], 0 }), 1e-9);
        try expectVec(vec.ZERO3, d.duv, 1e-12);
    }
    // Projection of a point outside the cylinder, above the quarter point (where the
    // parameter is the angle): the parameter and the height
    const uv = cyl.view().project(.{ 0, 7, 2 }, 1e-12, 50);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, uv[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0), uv[1], 1e-9);
}

test "revolution (A8.1): a sphere from a semicircle, a cone from a line" {
    // The semicircle in the xz plane from the south pole to the north pole, radius 3
    var meridian = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Z3, 3, -std.math.pi / 2.0, std.math.pi / 2.0);
    defer meridian.deinit(testing.allocator);
    var sphere = try nurbs.revolution(testing.allocator, meridian.view(), vec.ZERO3, vec.Z3, 0, types.TWO_PI);
    defer sphere.deinit(testing.allocator);
    try testing.expect(sphere.view().isValid());
    try testing.expectEqual(@as(u32, 9), sphere.count_u);
    try testing.expectEqual(@as(u32, 5), sphere.count_v);
    var u: f64 = 0;
    while (u <= types.TWO_PI) : (u += 0.4) {
        var v: f64 = -std.math.pi / 2.0;
        while (v <= std.math.pi / 2.0) : (v += 0.3) {
            try testing.expectApproxEqAbs(@as(f64, 3), vec.length(sphere.view().eval(u, v)), 1e-12);
        }
    }
    // At the pieces' ends and middles the parameters are the angles
    try expectVec(.{ 0, 3, 0 }, sphere.view().eval(std.math.pi / 2.0, 0), 1e-12);
    try expectVec(.{ 0, 0, 3 }, sphere.view().eval(1.0, std.math.pi / 2.0), 1e-12);
    try expectVec(.{ 3 * @cos(std.math.pi / 4.0) * @cos(std.math.pi / 4.0), 3 * @cos(std.math.pi / 4.0) * @sin(std.math.pi / 4.0), 3 * @sin(std.math.pi / 4.0) }, sphere.view().eval(std.math.pi / 4.0, std.math.pi / 4.0), 1e-12);
    // A line from (1, 0, 0) to (3, 0, 4) about z: a cone whose radius grows with height
    var gen = try nurbs.lineSegment(testing.allocator, .{ 1, 0, 0 }, .{ 3, 0, 4 }, 0, 1);
    defer gen.deinit(testing.allocator);
    var cone = try nurbs.revolution(testing.allocator, gen.view(), vec.ZERO3, vec.Z3, 0, std.math.pi);
    defer cone.deinit(testing.allocator);
    const p = cone.view().eval(std.math.pi / 2.0, 0.5);
    try expectVec(.{ 0, 2, 2 }, p, 1e-12);
    // On the cone everywhere: radius 1 + z / 2
    const q = cone.view().eval(1.0, 0.3);
    try testing.expectApproxEqAbs(1.0 + q[2] / 2.0, @sqrt(q[0] * q[0] + q[1] * q[1]), 1e-12);
    const s = cone.view().sample(std.math.pi / 2.0, 0.5);
    const n = vec.normalized(vec.cross(s.du, s.dv)).?;
    // Outward and tilted down at the quarter point: (0, 2, -1)/√5
    try expectVec(.{ 0, 2.0 / @sqrt(5.0), -1.0 / @sqrt(5.0) }, n, 1e-9);
}
