const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const types = @import("types.zig");
const curves = @import("curves.zig");
const surfaces = @import("surfaces.zig");
const nurbs = @import("nurbs.zig");
const transform = @import("transform.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Vec3 = vec.Vec3;
const Affine = mat.Affine;
const Frame = types.Frame;
const Box2 = types.Box2;

const tol = Tolerance.fromZone(1e-9);
const PI = std.math.pi;

fn expectVec(expected: Vec3, actual: Vec3, t: f64) !void {
    for (0..3) |k| try testing.expectApproxEqAbs(expected[k], actual[k], t);
}

/// A rigid move with a rotation, a uniform scale, a mirror, and a stretch.
const rigid = Affine.translate(.{ 1, -2, 3 }).compose(&Affine.rotate(vec.normalized(.{ 1, 1, 0 }).?, 0.7));
const scaled = Affine.scaleBy(.{ 2, 2, 2 }).compose(&rigid);
const mirrored = Affine.mirror(vec.Y3).compose(&rigid);
const stretched = Affine.scaleBy(.{ 2, 1, 1 }).compose(&rigid);

test "classify: rigid, scaled and mirrored maps are similarities; a stretch is general; a flat map singular" {
    const r = transform.classify(&rigid, tol).similarity;
    try testing.expectApproxEqAbs(@as(f64, 1), r.scale, 1e-12);
    try testing.expect(!r.mirror);
    const s = transform.classify(&scaled, tol).similarity;
    try testing.expectApproxEqAbs(@as(f64, 2), s.scale, 1e-12);
    const m = transform.classify(&mirrored, tol).similarity;
    try testing.expect(m.mirror);
    try testing.expectEqual(transform.Shape.general, transform.classify(&stretched, tol));
    try testing.expectEqual(transform.Shape.singular, transform.classify(&Affine.scaleBy(.{ 1, 0, 1 }), tol));
}

/// The mapped curve passes through the images of the original's points over the range,
/// at the (scaled) parameters.
fn expectCurveMapped(c: curves.Curve, t0: f64, t1: f64, a: *const Affine) !void {
    const shape = transform.classify(a, tol);
    var out = try transform.curve(testing.allocator, c, t0, t1, a, shape);
    defer out.deinit(testing.allocator);
    var i: usize = 0;
    while (i <= 10) : (i += 1) {
        const t = t0 + (t1 - t0) * @as(f64, @floatFromInt(i)) / 10.0;
        try expectVec(a.point(c.eval(t)), out.curve.eval(t * out.t_scale), 1e-9);
    }
}

test "curve: every kind under a similarity keeps its kind and parameter; a line's parameter scales" {
    const line = curves.Curve{ .line = curves.Line.through(.{ 0, 0, 0 }, .{ 3, 4, 0 }).? };
    const circle = curves.Curve{ .circle = curves.Circle.inPlane(.{ 1, 2, 3 }, vec.normalized(.{ 1, 1, 1 }).?, 2) };
    const ellipse = curves.Curve{ .ellipse = .{ .c = .{ 1, 0, 0 }, .x = vec.X3, .y = vec.Z3, .a = 3, .b = 1 } };
    for ([_]*const Affine{ &rigid, &scaled, &mirrored }) |a| {
        try expectCurveMapped(line, -1, 5, a);
        try expectCurveMapped(circle, 0.3, 4.0, a);
        try expectCurveMapped(ellipse, 0, PI, a);
        const shape = transform.classify(a, tol);
        var c = try transform.curve(testing.allocator, circle, 0, 1, a, shape);
        defer c.deinit(testing.allocator);
        try testing.expect(c.curve == .circle);
        try testing.expectApproxEqAbs(2.0 * shape.similarity.scale, c.curve.circle.r, 1e-12);
        try testing.expectEqual(@as(f64, 1), c.t_scale);
        var e = try transform.curve(testing.allocator, ellipse, 0, 1, a, shape);
        defer e.deinit(testing.allocator);
        try testing.expect(e.curve == .ellipse);
    }
    // A line under the stretch: its direction turns, its parameter scales by the stretch along it
    const shape = transform.classify(&stretched, tol);
    var l = try transform.curve(testing.allocator, line, 0, 5, &stretched, shape);
    defer l.deinit(testing.allocator);
    try testing.expect(l.curve == .line);
    try testing.expect(l.t_scale > 1.0 and l.t_scale < 2.0);
    try expectCurveMapped(line, 0, 5, &stretched);
}

test "curve: under a stretch an arc becomes its NURBS form, mapped, over the range in use" {
    const circle = curves.Curve{ .circle = curves.Circle.inPlane(.{ 1, 2, 3 }, vec.Z3, 2) };
    const shape = transform.classify(&stretched, tol);
    var c = try transform.curve(testing.allocator, circle, 0.5, 2.5, &stretched, shape);
    defer c.deinit(testing.allocator);
    try testing.expect(c.curve == .nurbs);
    try testing.expectEqual(@as(f64, 0.5), c.curve.domain().t0);
    try testing.expectEqual(@as(f64, 2.5), c.curve.domain().t1);
    // Its points are images of points of the circle (the arc's own parameterization): the
    // ends and the middle exactly
    try expectVec(stretched.point(circle.eval(0.5)), c.curve.eval(0.5), 1e-9);
    try expectVec(stretched.point(circle.eval(2.5)), c.curve.eval(2.5), 1e-9);
    try expectVec(stretched.point(circle.eval(1.5)), c.curve.eval(1.5), 1e-9);
    // In between, on the image of the circle: back through the map it is on the circle
    const p = stretched.inverse().?.point(c.curve.eval(1.0));
    try testing.expectApproxEqAbs(@as(f64, 2), vec.distance(p, .{ 1, 2, 3 }), 1e-9);
    // A NURBS curve maps under anything, parameter kept
    var arc = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 1, 0, PI);
    defer arc.deinit(testing.allocator);
    try expectCurveMapped(.{ .nurbs = arc.view() }, 0, PI, &stretched);
}

/// The mapped surface's points are the images of the original's over the box, at the
/// scaled parameters, and its normals the images of the original's (turned by a mirror).
fn expectSurfaceMapped(s: surfaces.Surface, box: Box2, a: *const Affine) !void {
    const shape = transform.classify(a, tol);
    var out = try transform.surface(testing.allocator, s, box, a, shape);
    defer out.deinit(testing.allocator);
    const nm = a.normalMatrix().?;
    var i: usize = 0;
    while (i <= 6) : (i += 1) {
        var j: usize = 0;
        while (j <= 6) : (j += 1) {
            const u = box.min[0] + (box.max[0] - box.min[0]) * @as(f64, @floatFromInt(i)) / 6.0;
            const v = box.min[1] + (box.max[1] - box.min[1]) * @as(f64, @floatFromInt(j)) / 6.0;
            const image = a.point(s.eval(u, v));
            // The normal follows the map's inverse transpose, with the mirror's sign
            const expected = vec.normalized(mat.apply3(&nm, s.normal(u, v))).?;
            const sign: f64 = if (a.determinant() < 0) -1 else 1;
            if (out.reparameterized) {
                // A plane with new axes: the image lies on it, the normal is the image normal
                try testing.expectApproxEqAbs(@as(f64, 0), out.surface.plane.height(image), 1e-9);
                try expectVec(vec.scale(expected, sign), out.surface.normal(0, 0), 1e-9);
            } else {
                try expectVec(image, out.surface.eval(u * out.u_scale, v * out.v_scale), 1e-9);
                try expectVec(vec.scale(expected, sign), out.surface.normal(u * out.u_scale, v * out.v_scale), 1e-9);
            }
        }
    }
}

test "surface: every kind under a similarity keeps its kind; a mirror turns the frame left-handed and the normal with it" {
    const box = Box2{ .min = .{ 0.2, -0.5 }, .max = .{ 2.0, 1.1 } };
    const circle = curves.Circle.inPlane(.{ 1, 2, 3 }, vec.Z3, 2);
    const gen = curves.Line.through(.{ 1, 0, 0 }, .{ 3, 0, 4 }).?;
    const kinds = [_]surfaces.Surface{
        .{ .plane = .{ .frame = Frame.init(.{ 1, 1, 1 }, vec.X3, vec.Z3) } },
        .{ .cylinder = .{ .frame = Frame.init(.{ 1, 1, 1 }, vec.X3, vec.Z3), .r = 2 } },
        .{ .cone = .{ .frame = Frame.init(.{ 1, 1, 1 }, vec.X3, vec.Z3), .r = 2, .half_angle = 0.4 } },
        .{ .sphere = .{ .frame = Frame.init(.{ 1, 1, 1 }, vec.X3, vec.Z3), .r = 3 } },
        .{ .torus = .{ .frame = Frame.init(.{ 1, 1, 1 }, vec.X3, vec.Z3), .major = 5, .minor = 1 } },
        .{ .extrusion = .{ .curve = .{ .circle = circle }, .d = vec.Z3 } },
        .{ .revolution = surfaces.Revolution.init(.{ .line = gen }, vec.ZERO3, vec.Z3) },
    };
    for ([_]*const Affine{ &rigid, &scaled, &mirrored }) |a| {
        for (kinds) |s| {
            try expectSurfaceMapped(s, box, a);
            var out = try transform.surface(testing.allocator, s, box, a, transform.classify(a, tol));
            defer out.deinit(testing.allocator);
            try testing.expectEqual(std.meta.activeTag(s), std.meta.activeTag(out.surface));
        }
    }
    // The mirrored cylinder's frame is left-handed
    var m = try transform.surface(testing.allocator, kinds[1], box, &mirrored, transform.classify(&mirrored, tol));
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, -1), m.surface.cylinder.frame.sign());
    // A NURBS surface under anything
    var arc = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 2, 0, PI);
    defer arc.deinit(testing.allocator);
    var swept = try nurbs.extrusion(testing.allocator, arc.view(), vec.Z3, 0, 5);
    defer swept.deinit(testing.allocator);
    try expectSurfaceMapped(.{ .nurbs = swept.view() }, .{ .min = .{ 0.2, 0.5 }, .max = .{ 2.0, 4.0 } }, &stretched);
}

test "surface: under a stretch a plane stays a plane and a swept NURBS survives, the curved kinds are not representable" {
    const box = Box2{ .min = .{ 0.2, -0.5 }, .max = .{ 2.0, 1.1 } };
    const shape = transform.classify(&stretched, tol);
    try expectSurfaceMapped(.{ .plane = .{ .frame = Frame.init(.{ 1, 1, 1 }, vec.normalized(.{ 1, 1, 0 }).?, vec.normalized(.{ -1, 1, 1 }).?) } }, box, &stretched);
    for ([_]surfaces.Surface{
        .{ .cylinder = .{ .frame = Frame.world, .r = 2 } },
        .{ .cone = .{ .frame = Frame.world, .r = 2, .half_angle = 0.4 } },
        .{ .sphere = .{ .frame = Frame.world, .r = 3 } },
        .{ .torus = .{ .frame = Frame.world, .major = 5, .minor = 1 } },
        .{ .extrusion = .{ .curve = .{ .circle = curves.Circle.inPlane(vec.ZERO3, vec.Z3, 2) }, .d = vec.Z3 } },
        .{ .revolution = surfaces.Revolution.init(.{ .line = curves.Line.through(.{ 1, 0, 0 }, .{ 3, 0, 4 }).? }, vec.ZERO3, vec.Z3) },
    }) |s| {
        try testing.expectError(error.NotRepresentable, transform.surface(testing.allocator, s, box, &stretched, shape));
    }
    // An extrusion of a NURBS curve along a direction: exact, the direction's stretch in v
    var arc = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 2, 0, PI);
    defer arc.deinit(testing.allocator);
    const along_x = surfaces.Surface{ .extrusion = .{ .curve = .{ .nurbs = arc.view() }, .d = vec.X3 } };
    var out = try transform.surface(testing.allocator, along_x, .{ .min = .{ 0.2, 0.5 }, .max = .{ 2.0, 4.0 } }, &Affine.scaleBy(.{ 2, 1, 1 }), transform.classify(&Affine.scaleBy(.{ 2, 1, 1 }), tol));
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 2), out.v_scale);
    try expectSurfaceMapped(along_x, .{ .min = .{ 0.2, 0.5 }, .max = .{ 2.0, 4.0 } }, &Affine.scaleBy(.{ 2, 1, 1 }));
}
