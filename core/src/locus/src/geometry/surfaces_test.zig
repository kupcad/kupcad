const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const types = @import("types.zig");
const curves = @import("curves.zig");
const surfaces = @import("surfaces.zig");
const nurbs = @import("nurbs.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Frame = types.Frame;
const Surface = surfaces.Surface;
const Box2 = types.Box2;

const H: f64 = 1e-6;
const H2: f64 = 1e-4;
const PI = std.math.pi;

fn expectVec(expected: Vec3, actual: Vec3, tol: f64) !void {
    for (0..3) |k| try testing.expectApproxEqAbs(expected[k], actual[k], tol);
}

/// Derivatives against central differences, the normal unit and along `du × dv`.
fn expectContract(s: Surface, u: f64, v: f64) !void {
    const smp = s.sample(u, v);
    try expectVec(s.eval(u, v), smp.p, 1e-12);
    const du = vec.scale(vec.sub(s.eval(u + H, v), s.eval(u - H, v)), 1.0 / (2.0 * H));
    const dv = vec.scale(vec.sub(s.eval(u, v + H), s.eval(u, v - H)), 1.0 / (2.0 * H));
    try expectVec(du, smp.du, 1e-6);
    try expectVec(dv, smp.dv, 1e-6);
    const duu = vec.scale(vec.add(vec.sub(s.eval(u + H2, v), vec.scale(s.eval(u, v), 2.0)), s.eval(u - H2, v)), 1.0 / (H2 * H2));
    const dvv = vec.scale(vec.add(vec.sub(s.eval(u, v + H2), vec.scale(s.eval(u, v), 2.0)), s.eval(u, v - H2)), 1.0 / (H2 * H2));
    try expectVec(duu, smp.duu, 1e-5);
    try expectVec(dvv, smp.dvv, 1e-5);
    const duv = vec.scale(vec.sub(vec.sub(s.eval(u + H2, v + H2), s.eval(u + H2, v - H2)), vec.sub(s.eval(u - H2, v + H2), s.eval(u - H2, v - H2))), 1.0 / (4.0 * H2 * H2));
    try expectVec(duv, smp.duv, 1e-5);
    const n = s.normal(u, v);
    try testing.expectApproxEqAbs(@as(f64, 1), vec.length(n), 1e-12);
    if (vec.normalized(vec.cross(smp.du, smp.dv))) |cross| try expectVec(cross, n, 1e-9);
}

/// A point on the surface projects back to its parameters; one off it projects to the
/// nearest point (the tangents perpendicular to the way there).
fn expectProjection(s: Surface, u: f64, v: f64, off: Vec3) !void {
    const on = s.eval(u, v);
    const uv = s.project(on, 1e-12, 50);
    try testing.expectApproxEqAbs(u, uv[0], 1e-9);
    try testing.expectApproxEqAbs(v, uv[1], 1e-9);
    const p = vec.add(on, off);
    const foot = s.project(p, 1e-12, 50);
    const smp = s.sample(foot[0], foot[1]);
    const to = vec.sub(p, smp.p);
    try testing.expectApproxEqAbs(@as(f64, 0), vec.dot(smp.du, to), 1e-7 * (1 + vec.length(smp.du)) * (1 + vec.length(to)));
    try testing.expectApproxEqAbs(@as(f64, 0), vec.dot(smp.dv, to), 1e-7 * (1 + vec.length(smp.dv)) * (1 + vec.length(to)));
}

/// The box holds every sample of the patch.
fn expectBounds(s: Surface, box: Box2) !void {
    const b = s.bounds(box);
    var i: usize = 0;
    while (i <= 20) : (i += 1) {
        var j: usize = 0;
        while (j <= 20) : (j += 1) {
            const u = box.min[0] + (box.max[0] - box.min[0]) * @as(f64, @floatFromInt(i)) / 20.0;
            const v = box.min[1] + (box.max[1] - box.min[1]) * @as(f64, @floatFromInt(j)) / 20.0;
            try testing.expect(b.inflated(1e-9).contains(s.eval(u, v)));
        }
    }
}

const tilted = Frame.init(.{ 1, 2, 3 }, vec.normalized(.{ 1, -1, 0 }).?, vec.normalized(.{ 1, 1, 1 }).?);

test "Plane: the contract" {
    const s = Surface{ .plane = .{ .frame = tilted } };
    try expectContract(s, 0.3, -2);
    try expectProjection(s, 1.5, -0.5, vec.scale(tilted.z, 3));
    try expectBounds(s, .{ .min = .{ -1, -1 }, .max = .{ 2, 3 } });
    try testing.expectApproxEqAbs(@as(f64, 3), s.plane.height(vec.addScaled(tilted.origin, tilted.z, 3)), 1e-12);
    const b = s.bounds(.{ .min = .{ 0, 0 }, .max = .{ 1, 1 } });
    try testing.expect(b.contains(tilted.toWorld(.{ 0.5, 0.5, 0 })));
}

test "Cylinder: the contract, the seam, and tight bounds" {
    const s = Surface{ .cylinder = .{ .frame = tilted, .r = 2 } };
    try expectContract(s, 0.3, -2);
    try expectContract(s, 4.0, 1);
    try expectProjection(s, 1.0, 2.0, vec.scale(s.normal(1.0, 2.0), 3));
    // Past the seam the angle wraps into [0, 2π)
    const uv = s.project(s.eval(types.TWO_PI - 0.1, 1), 1e-12, 50);
    try testing.expectApproxEqAbs(types.TWO_PI - 0.1, uv[0], 1e-9);
    try expectBounds(s, .{ .min = .{ 0, -1 }, .max = .{ PI, 1 } });
    // An upright cylinder's half face: the box is exact
    const upright = Surface{ .cylinder = .{ .frame = Frame.world, .r = 2 } };
    const b = upright.bounds(.{ .min = .{ 0, 0 }, .max = .{ PI, 5 } });
    try expectVec(.{ -2, 0, 0 }, b.min, 1e-12);
    try expectVec(.{ 2, 2, 5 }, b.max, 1e-12);
    try testing.expect(s.isPeriodicU() and !s.isPeriodicV());
}

test "Cone: the contract, the apex, and the generator projection" {
    const cone = surfaces.Cone{ .frame = tilted, .r = 2, .half_angle = 0.4 };
    const s = Surface{ .cone = cone };
    try expectContract(s, 0.3, 1);
    try expectContract(s, 3.0, -1);
    try expectProjection(s, 2.0, 1.5, vec.scale(s.normal(2.0, 1.5), 1));
    try expectBounds(s, .{ .min = .{ 0, -1 }, .max = .{ PI, 3 } });
    // The apex is where the radius vanishes
    try testing.expectApproxEqAbs(@as(f64, 0), cone.radiusAt(cone.apexV()), 1e-12);
    try expectVec(cone.eval(0, cone.apexV()), cone.eval(2, cone.apexV()), 1e-12);
    // The normal is perpendicular to the generator direction and to the ring
    const smp = s.sample(1, 1);
    try testing.expectApproxEqAbs(@as(f64, 0), vec.dot(s.normal(1, 1), smp.dv), 1e-12);
    try testing.expect(s.isPeriodicU());
}

test "Sphere: the contract, the poles, the box of an octant" {
    const s = Surface{ .sphere = .{ .frame = tilted, .r = 3 } };
    try expectContract(s, 0.3, 0.2);
    try expectContract(s, 4.0, -1.2);
    try expectProjection(s, 1.0, 0.5, vec.scale(s.normal(1.0, 0.5), 2));
    try expectBounds(s, .{ .min = .{ 0, -PI / 2.0 }, .max = .{ PI, PI / 2.0 } });
    // At the poles the normal is still the axis
    try expectVec(tilted.z, s.normal(1.0, PI / 2.0), 1e-12);
    try expectVec(vec.neg(tilted.z), s.normal(2.0, -PI / 2.0), 1e-12);
    // An octant of the unit sphere at the origin: exactly the unit cube's corner
    const unit = Surface{ .sphere = .{ .frame = Frame.world, .r = 1 } };
    const b = unit.bounds(.{ .min = .{ 0, 0 }, .max = .{ PI / 2.0, PI / 2.0 } });
    try expectVec(.{ 0, 0, 0 }, b.min, 1e-12);
    try expectVec(.{ 1, 1, 1 }, b.max, 1e-12);
    // A patch straddling the x extreme: the interior extreme is found
    const c = unit.bounds(.{ .min = .{ -0.0, -0.5 }, .max = .{ 0.5, 0.5 } });
    try testing.expectApproxEqAbs(@as(f64, 1), c.max[0], 1e-12);
    try testing.expect(!s.isPeriodicV());
}

test "Torus: the contract and the box of a patch" {
    const s = Surface{ .torus = .{ .frame = tilted, .major = 5, .minor = 1 } };
    try expectContract(s, 0.3, 0.2);
    try expectContract(s, 4.0, 4.0);
    try expectProjection(s, 1.0, 0.5, vec.scale(s.normal(1.0, 0.5), 0.5));
    try expectBounds(s, .{ .min = .{ 0, 0 }, .max = .{ PI, PI } });
    try expectBounds(s, .{ .min = .{ PI, PI }, .max = .{ types.TWO_PI, types.TWO_PI } });
    // A whole torus at the origin: the box is exact
    const flat = Surface{ .torus = .{ .frame = Frame.world, .major = 5, .minor = 1 } };
    const b = flat.bounds(.{ .min = .{ 0, 0 }, .max = .{ types.TWO_PI, types.TWO_PI } });
    try expectVec(.{ -6, -6, -1 }, b.min, 1e-12);
    try expectVec(.{ 6, 6, 1 }, b.max, 1e-12);
    try testing.expect(s.isPeriodicU() and s.isPeriodicV());
}

test "Extrusion: a circle along a direction is a cylinder" {
    const circle = curves.Circle.inPlane(.{ 1, 2, 3 }, vec.Z3, 2);
    const s = Surface{ .extrusion = .{ .curve = .{ .circle = circle }, .d = vec.Z3 } };
    const cyl = Surface{ .cylinder = .{ .frame = Frame.init(.{ 1, 2, 3 }, circle.x, vec.Z3), .r = 2 } };
    var u: f64 = 0;
    while (u < types.TWO_PI) : (u += 0.5) {
        try expectVec(cyl.eval(u, 1.5), s.eval(u, 1.5), 1e-12);
        try expectVec(cyl.normal(u, 1.5), s.normal(u, 1.5), 1e-12);
    }
    try expectContract(s, 0.7, 2);
    try expectProjection(s, 1.0, 2.0, vec.scale(s.normal(1.0, 2.0), 3));
    try expectBounds(s, .{ .min = .{ 0, -1 }, .max = .{ 2, 4 } });
    const b = s.bounds(.{ .min = .{ 0, 0 }, .max = .{ types.TWO_PI, 5 } });
    try expectVec(.{ -1, 0, 3 }, b.min, 1e-12);
    try expectVec(.{ 3, 4, 8 }, b.max, 1e-12);
}

test "Revolution: a line about the axis is a cone, a semicircle a sphere, with the generator off the axis plane" {
    // The generator from (1, 0, 0) to (3, 0, 4) about z
    const gen = curves.Line.through(.{ 1, 0, 0 }, .{ 3, 0, 4 }).?;
    const s = Surface{ .revolution = surfaces.Revolution.init(.{ .line = gen }, vec.ZERO3, vec.Z3) };
    const len = vec.distance(.{ 1, 0, 0 }, .{ 3, 0, 4 });
    try expectVec(.{ 0, 2, 2 }, s.eval(PI / 2.0, len / 2.0), 1e-12);
    try expectContract(s, 1.0, 2.0);
    try expectContract(s, 4.5, 0.5);
    // The matching cone: radius 1 at v = 0, half-angle atan(2/4)
    const cone = Surface{ .cone = .{ .frame = Frame.world, .r = 1, .half_angle = std.math.atan(@as(f64, 0.5)) } };
    try expectVec(cone.eval(1.0, 2.0), s.eval(1.0, 2.0 * @cos(std.math.atan(@as(f64, 0.5))) / @cos(std.math.atan(@as(f64, 0.5)))), 1e-9);
    try expectVec(cone.normal(1.0, 2.0), s.normal(1.0, 2.0), 1e-9);
    try expectProjection(s, 1.0, 2.0, vec.scale(s.normal(1.0, 2.0), 1));
    try expectBounds(s, .{ .min = .{ 0, 0 }, .max = .{ PI, len } });

    // A generator at angle 1 rad about the axis: the surface's u is measured from there
    const off = curves.Circle{ .c = .{ 4 * @cos(1.0), 4 * @sin(1.0), 0 }, .x = .{ @cos(1.0), @sin(1.0), 0 }, .y = vec.Z3, .r = 1 };
    const torus = Surface{ .revolution = surfaces.Revolution.init(.{ .circle = off }, vec.ZERO3, vec.Z3) };
    const exact = Surface{ .torus = .{ .frame = Frame.world, .major = 4, .minor = 1 } };
    try expectVec(exact.eval(1.0 + 0.3, 0.7), torus.eval(0.3, 0.7), 1e-12);
    try expectContract(torus, 0.3, 0.7);
    try expectProjection(torus, 0.3, 0.7, vec.scale(torus.normal(0.3, 0.7), 0.4));
    try expectBounds(torus, .{ .min = .{ 0, 0 }, .max = .{ 2, 3 } });

    // At the axis (a pole) the normal is still unit, along the axis
    const meridian = curves.Circle{ .c = vec.ZERO3, .x = vec.X3, .y = vec.Z3, .r = 3 };
    const sphere = Surface{ .revolution = surfaces.Revolution.init(.{ .circle = meridian }, vec.ZERO3, vec.Z3) };
    try expectVec(vec.Z3, sphere.normal(0.5, PI / 2.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 3), vec.length(sphere.eval(2.0, 1.0)), 1e-12);
}

/// The NURBS form of the patch lies on the surface, and the box's corners are its corners.
fn expectNurbsOnSurface(s: Surface, box: Box2) !void {
    var data = try s.toNurbs(testing.allocator, box);
    defer data.deinit(testing.allocator);
    try testing.expect(data.view().isValid());
    const n = Surface{ .nurbs = data.view() };
    var i: usize = 0;
    while (i <= 8) : (i += 1) {
        var j: usize = 0;
        while (j <= 8) : (j += 1) {
            const u = box.min[0] + (box.max[0] - box.min[0]) * @as(f64, @floatFromInt(i)) / 8.0;
            const v = box.min[1] + (box.max[1] - box.min[1]) * @as(f64, @floatFromInt(j)) / 8.0;
            const p = n.eval(u, v);
            const foot = s.project(p, 1e-12, 50);
            try testing.expectApproxEqAbs(@as(f64, 0), vec.distance(p, s.eval(foot[0], foot[1])), 1e-9);
        }
    }
    try expectVec(s.eval(box.min[0], box.min[1]), n.eval(box.min[0], box.min[1]), 1e-9);
    try expectVec(s.eval(box.max[0], box.max[1]), n.eval(box.max[0], box.max[1]), 1e-9);
    try expectVec(s.eval(box.min[0], box.max[1]), n.eval(box.min[0], box.max[1]), 1e-9);
}

test "toNurbs: every kind's NURBS form lies on it" {
    const box = Box2{ .min = .{ 0.2, -0.5 }, .max = .{ 2.0, 1.1 } };
    try expectNurbsOnSurface(.{ .plane = .{ .frame = tilted } }, box);
    try expectNurbsOnSurface(.{ .cylinder = .{ .frame = tilted, .r = 2 } }, box);
    try expectNurbsOnSurface(.{ .cone = .{ .frame = tilted, .r = 2, .half_angle = 0.4 } }, box);
    try expectNurbsOnSurface(.{ .sphere = .{ .frame = tilted, .r = 3 } }, box);
    try expectNurbsOnSurface(.{ .torus = .{ .frame = tilted, .major = 5, .minor = 1 } }, .{ .min = .{ 0.2, 0.5 }, .max = .{ 2.0, 4.0 } });
    const circle = curves.Circle.inPlane(.{ 1, 2, 3 }, vec.Z3, 2);
    try expectNurbsOnSurface(.{ .extrusion = .{ .curve = .{ .circle = circle }, .d = vec.Z3 } }, box);
    const gen = curves.Line.through(.{ 1, 0, 0 }, .{ 3, 0, 4 }).?;
    try expectNurbsOnSurface(.{ .revolution = surfaces.Revolution.init(.{ .line = gen }, vec.ZERO3, vec.Z3) }, .{ .min = .{ 0.2, 0.5 }, .max = .{ 2.0, 3.0 } });
    var ell = try nurbs.ellipseArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 4, 2, 0, std.math.pi);
    defer ell.deinit(testing.allocator);
    var swept = try nurbs.extrusion(testing.allocator, ell.view(), vec.Z3, 0, 5);
    defer swept.deinit(testing.allocator);
    // Inside its domain, [0, π] × [0, 5]
    try expectNurbsOnSurface(.{ .nurbs = swept.view() }, .{ .min = .{ 0.2, 0.5 }, .max = .{ 2.0, 4.0 } });
    // A curve's NURBS form, through the union
    const c = curves.Curve{ .ellipse = .{ .c = vec.ZERO3, .x = vec.X3, .y = vec.Y3, .a = 4, .b = 2 } };
    var arc = try c.toNurbs(testing.allocator, 0.5, 2.5);
    defer arc.deinit(testing.allocator);
    try expectVec(c.eval(0.5), arc.view().eval(0.5), 1e-12);
    try expectVec(c.eval(2.5), arc.view().eval(2.5), 1e-12);
    var sub = try (curves.Curve{ .nurbs = arc.view() }).toNurbs(testing.allocator, 1.0, 2.0);
    defer sub.deinit(testing.allocator);
    try expectVec(arc.view().eval(1.5), sub.view().eval(1.5), 1e-12);
}

test "NURBS surface: the contract through the union" {
    var circle = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 2, 0, types.TWO_PI);
    defer circle.deinit(testing.allocator);
    var cyl = try nurbs.extrusion(testing.allocator, circle.view(), vec.Z3, 0, 5);
    defer cyl.deinit(testing.allocator);
    const s = Surface{ .nurbs = cyl.view() };
    try expectContract(s, 0.7, 2);
    try expectContract(s, 3.5, 4);
    try expectProjection(s, 1.0, 2.0, vec.scale(s.normal(1.0, 2.0), 3));
    try expectBounds(s, .{ .min = .{ 0, 0 }, .max = .{ 3, 5 } });
    try testing.expect(!s.isPeriodicU());
}
