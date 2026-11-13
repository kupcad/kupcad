const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const types = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const canonical = @import("../geometry/canonical.zig");
const Geometry = @import("../geometry/arena.zig").Geometry;
const Tolerance = @import("../tolerance.zig").Tolerance;
const grid = @import("grid.zig");
const Interner = @import("intern.zig").Interner;
const Vec3 = vec.Vec3;
const Frame = types.Frame;

/// Points of the differential test, and the box they fall in.
const RANDOM_POINTS = 4000;
const SEED = 0x9e1d;

test "Grid: a query visits the cells its box overlaps and nothing farther" {
    var g = grid.Grid.init(1.0);
    defer g.deinit(testing.allocator);
    const pts = [_]Vec3{ .{ 0.5, 0.5, 0.5 }, .{ 1.4, 0.5, 0.5 }, .{ 3.5, 0.5, 0.5 }, .{ 0.6, 0.6, 0.6 } };
    for (pts, 0..) |p, i| try g.insert(testing.allocator, @intCast(i), p);
    try testing.expectEqual(@as(usize, 4), g.count());
    const Seen = struct {
        mask: u32 = 0,
        fn visit(self: *@This(), index: u32) bool {
            self.mask |= @as(u32, 1) << @intCast(index);
            return true;
        }
    };
    var seen = Seen{};
    try g.query(.{ 0.9, 0.5, 0.5 }, 0.5, &seen, Seen.visit);
    // The box [0.4, 1.4] overlaps cells 0 and 1 in x: points 0, 1, 3, never 2
    try testing.expectEqual(@as(u32, 0b1011), seen.mask);
    seen = .{};
    try g.query(.{ 3.2, 0.5, 0.5 }, 0.1, &seen, Seen.visit);
    try testing.expectEqual(@as(u32, 0b0100), seen.mask);
    // A point too far for the cell to be a number is refused
    try testing.expectError(error.OutOfRange, g.insert(testing.allocator, 4, .{ 1e300, 0, 0 }));
    try testing.expectError(error.OutOfRange, g.insert(testing.allocator, 4, .{ std.math.nan(f64), 0, 0 }));
}

test "PointWelder: the first kept point within the radius, whatever the order of insertion" {
    var points: std.ArrayList(Vec3) = .empty;
    defer points.deinit(testing.allocator);
    var welder = grid.PointWelder.init(1e-5);
    defer welder.deinit(testing.allocator);
    const zone = 1e-5;
    try points.append(testing.allocator, .{ 0, 0, 0 });
    try welder.add(testing.allocator, points.items, 0);
    try points.append(testing.allocator, .{ 0.6 * zone, 0, 0 });
    try welder.add(testing.allocator, points.items, 1);
    // A query between them, within the radius of both: the first kept
    try testing.expectEqual(@as(?u32, 0), try welder.find(points.items, .{ 0.3 * zone, 0, 0 }));
    // Nearer the second only
    try testing.expectEqual(@as(?u32, 1), try welder.find(points.items, .{ 1.4 * zone, 0, 0 }));
    try testing.expectEqual(@as(?u32, null), try welder.find(points.items, .{ 3 * zone, 0, 0 }));
    // Across a cell boundary (cells are 2·zone wide): the neighbour cell is searched
    try points.append(testing.allocator, .{ 2 * zone - 0.1 * zone, 0, 0 });
    try welder.add(testing.allocator, points.items, 2);
    try testing.expectEqual(@as(?u32, 2), try welder.find(points.items, .{ 2 * zone + 0.5 * zone, 0, 0 }));
}

test "PointWelder: a kept point at the radius to within the margin, either side, and none clear of it" {
    var points: std.ArrayList(Vec3) = .empty;
    defer points.deinit(testing.allocator);
    const radius = 2e-5;
    const margin = 1e-13;
    var welder = grid.PointWelder.initWithMargin(radius, margin);
    defer welder.deinit(testing.allocator);
    try points.append(testing.allocator, .{ 3, 3, 4 });
    try welder.add(testing.allocator, points.items, 0);
    // The solids fuzzer's pair (2026-11-13): a hull moved by the radius, 2.0000000000131e-5
    // away as the numbers fall, a rounding past it: neither within nor clear
    try testing.expectEqual(@as(?u32, 0), try welder.atRadius(points.items, .{ 3.00002, 3, 4 }));
    try testing.expectEqual(@as(?u32, null), try welder.find(points.items, .{ 3.00002, 3, 4 }));
    // A rounding inside it, and the radius exactly
    try testing.expectEqual(@as(?u32, 0), try welder.atRadius(points.items, .{ 3, 3, 4 - radius + 0.5 * margin }));
    // Clearly within, clearly beyond
    try testing.expectEqual(@as(?u32, null), try welder.atRadius(points.items, .{ 3 + 0.9 * radius, 3, 4 }));
    try testing.expectEqual(@as(?u32, null), try welder.atRadius(points.items, .{ 3 + 1.1 * radius, 3, 4 }));
    try testing.expectEqual(@as(?u32, 0), try welder.find(points.items, .{ 3 + 0.9 * radius, 3, 4 }));
}

test "Interner: points weld to the first kept, and no two kept points are within zone (against a linear scan)" {
    const tol = Tolerance.fromZone(1e-3);
    var g: Geometry = .empty;
    defer g.deinit(testing.allocator);
    var interner = Interner.init(tol);
    defer interner.deinit(testing.allocator);
    // A linear-scan reference with the same rule: the first kept point within zone
    var reference: std.ArrayList(Vec3) = .empty;
    defer reference.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    var i: usize = 0;
    while (i < RANDOM_POINTS) : (i += 1) {
        // Clustered: a coarse grid of 0.01 with jitter of ±zone, so many points weld
        const p = Vec3{
            @round(random.float(f64) * 100) * 0.01 + (random.float(f64) - 0.5) * 2 * tol.zone,
            @round(random.float(f64) * 100) * 0.01 + (random.float(f64) - 0.5) * 2 * tol.zone,
            @round(random.float(f64) * 10) * 0.01 + (random.float(f64) - 0.5) * 2 * tol.zone,
        };
        const got = try interner.point(testing.allocator, &g, p);
        var expected: ?usize = null;
        for (reference.items, 0..) |q, k| {
            if (vec.distanceSq(q, p) <= tol.zone * tol.zone) {
                expected = k;
                break;
            }
        }
        if (expected == null) {
            try reference.append(testing.allocator, p);
            expected = reference.items.len - 1;
        }
        try testing.expectEqual(expected.?, @backingInt(got));
    }
    try testing.expectEqual(reference.items.len, g.points.items.len);
    try testing.expect(g.points.items.len < RANDOM_POINTS);
    // No two kept points within zone
    for (g.points.items, 0..) |p, a| {
        for (g.points.items[a + 1 ..]) |q| try testing.expect(vec.distanceSq(p, q) > tol.zone * tol.zone);
    }
}

test "Interner: the same line, plane and surface get one index; different ones their own" {
    const tol = Tolerance.fromZone(1e-5);
    var g: Geometry = .empty;
    defer g.deinit(testing.allocator);
    var interner = Interner.init(tol);
    defer interner.deinit(testing.allocator);

    // Lines: the same line placed and directed differently
    const l1 = curves.Line.through(.{ 0, 0, 0 }, .{ 2, 0, 0 }).?;
    const l2 = curves.Line.through(.{ 5, 0, 0 }, .{ -3, 0, 0 }).?;
    const l3 = curves.Line.through(.{ 0, 1, 0 }, .{ 2, 1, 0 }).?;
    const r1 = try interner.line(testing.allocator, &g, l1, .{ 0, 0, 0 }, .{ 2, 0, 0 });
    try testing.expect(r1.eql(try interner.line(testing.allocator, &g, l2, .{ 5, 0, 0 }, .{ -3, 0, 0 })));
    try testing.expect(!r1.eql(try interner.line(testing.allocator, &g, l3, .{ 0, 1, 0 }, .{ 2, 1, 0 })));
    try testing.expectEqual(@as(usize, 2), g.lines.items.len);
    // A line through the origin shares its key with every other such line
    const through_origin = curves.Line.through(.{ 0, 0, 0 }, .{ 0, 0, 1 }).?;
    const r4 = try interner.line(testing.allocator, &g, through_origin, .{ 0, 0, 0 }, .{ 0, 0, 1 });
    try testing.expect(!r4.eql(r1));
    try testing.expectEqual(@as(usize, 3), g.lines.items.len);
    // A line through the origin a fraction of a degree off the x axis is within the angle
    // and shares the key, but its far end is 0.1 off the x axis: its own line (over a
    // short edge near the origin it would be the same)
    const askew = curves.Line.through(.{ 0, 0, 0 }, .{ 10, 0.1, 0 }).?;
    const r5 = try interner.line(testing.allocator, &g, askew, .{ 0, 0, 0 }, .{ 10, 0.1, 0 });
    try testing.expect(!r5.eql(r1));
    try testing.expectEqual(@as(usize, 4), g.lines.items.len);
    try testing.expect(r1.eql(try interner.line(testing.allocator, &g, askew, .{ 0, 0, 0 }, .{ 0.001, 0.00001, 0 })));

    // Planes: z = 1 with either normal, and its parallel at z = 1 + zone/2 is the same
    const p1 = surfaces.Plane{ .frame = Frame.init(.{ 0, 0, 1 }, vec.X3, vec.Z3) };
    const p2 = surfaces.Plane{ .frame = Frame.init(.{ 7, 3, 1 }, vec.Y3, vec.neg(vec.Z3)) };
    const p3 = surfaces.Plane{ .frame = Frame.init(.{ 0, 0, 1 + 0.5e-5 }, vec.X3, vec.Z3) };
    const p4 = surfaces.Plane{ .frame = Frame.init(.{ 0, 0, 1.001 }, vec.X3, vec.Z3) };
    const s1 = try interner.plane(testing.allocator, &g, p1);
    try testing.expect(s1.eql(try interner.plane(testing.allocator, &g, p2)));
    try testing.expect(s1.eql(try interner.plane(testing.allocator, &g, p3)));
    try testing.expect(!s1.eql(try interner.plane(testing.allocator, &g, p4)));
    try testing.expectEqual(@as(usize, 2), g.planes.items.len);

    // Cylinders: the same axis line and radius with a turned reference direction
    const c1 = surfaces.Cylinder{ .frame = Frame.init(.{ 0, 0, 0 }, vec.X3, vec.Z3), .r = 2 };
    const c2 = surfaces.Cylinder{ .frame = Frame.init(.{ 0, 0, 9 }, vec.Y3, vec.Z3), .r = 2 };
    const c3 = surfaces.Cylinder{ .frame = Frame.init(.{ 0, 0, 0 }, vec.X3, vec.Z3), .r = 2.001 };
    const cy = try interner.cylinder(testing.allocator, &g, c1);
    try testing.expect(cy.eql(try interner.cylinder(testing.allocator, &g, c2)));
    try testing.expect(!cy.eql(try interner.cylinder(testing.allocator, &g, c3)));

    // Spheres, tori, cones, circles
    const sp = try interner.sphere(testing.allocator, &g, .{ .frame = Frame.world, .r = 1 });
    try testing.expect(sp.eql(try interner.sphere(testing.allocator, &g, .{ .frame = Frame.init(.{ 0.4e-5, 0, 0 }, vec.Y3, vec.X3), .r = 1 })));
    try testing.expect(!sp.eql(try interner.sphere(testing.allocator, &g, .{ .frame = Frame.world, .r = 1.1 })));
    const to = try interner.torus(testing.allocator, &g, .{ .frame = Frame.world, .major = 5, .minor = 1 });
    try testing.expect(to.eql(try interner.torus(testing.allocator, &g, .{ .frame = Frame.init(vec.ZERO3, vec.Y3, vec.neg(vec.Z3)), .major = 5, .minor = 1 })));
    try testing.expect(!to.eql(try interner.torus(testing.allocator, &g, .{ .frame = Frame.world, .major = 5, .minor = 2 })));
    const cone1 = surfaces.Cone{ .frame = Frame.world, .r = 1, .half_angle = 0.3 };
    // The same cone described from a ring higher up: the apex and axis agree
    const up = 2.0 * @cos(0.3);
    const cone2 = surfaces.Cone{ .frame = Frame.init(.{ 0, 0, up }, vec.Y3, vec.Z3), .r = 1 + 2.0 * @sin(0.3), .half_angle = 0.3 };
    const cone3 = surfaces.Cone{ .frame = Frame.world, .r = 1, .half_angle = 0.31 };
    const co = try interner.cone(testing.allocator, &g, cone1);
    try testing.expect(co.eql(try interner.cone(testing.allocator, &g, cone2)));
    try testing.expect(!co.eql(try interner.cone(testing.allocator, &g, cone3)));
    const ci = try interner.circle(testing.allocator, &g, curves.Circle.inPlane(.{ 1, 1, 1 }, vec.Z3, 2));
    try testing.expect(ci.eql(try interner.circle(testing.allocator, &g, .{ .c = .{ 1, 1, 1 }, .x = vec.Y3, .y = vec.neg(vec.X3), .r = 2 })));
    try testing.expect(!ci.eql(try interner.circle(testing.allocator, &g, curves.Circle.inPlane(.{ 1, 1, 1 }, vec.X3, 2))));
}

test "Geometry: references resolve to views, NURBS through the pools, and a clone is independent" {
    var g: Geometry = .empty;
    defer g.deinit(testing.allocator);
    const nurbs = @import("../geometry/nurbs.zig");
    var arc = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 2, 0, types.TWO_PI);
    defer arc.deinit(testing.allocator);
    const c = try g.addNurbsCurve(testing.allocator, arc.view());
    var cyl = try nurbs.extrusion(testing.allocator, arc.view(), vec.Z3, 0, 5);
    defer cyl.deinit(testing.allocator);
    const s = try g.addNurbsSurface(testing.allocator, cyl.view());
    const line = try g.addLine(testing.allocator, curves.Line.through(.{ 0, 0, 0 }, .{ 0, 0, 1 }).?);
    const ext = try g.addExtrusion(testing.allocator, c, vec.Z3);
    const rev = try g.addRevolution(testing.allocator, line, .{ 3, 0, 0 }, vec.Y3);
    try testing.expectEqual(@as(usize, 2), g.curveCount());
    try testing.expectEqual(@as(usize, 3), g.surfaceCount());
    try testing.expect(g.curve(c).nurbs.isValid());
    try testing.expectApproxEqAbs(@as(f64, 2), vec.length(g.curve(c).eval(1.0)), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2), vec.length(vec.sub(g.surface(s).eval(1.0, 3), .{ 0, 0, 3 })), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2), vec.length(vec.sub(g.surface(ext).eval(1.0, 3), .{ 0, 0, 3 })), 1e-12);
    // The generator's point (0, 0, 1) is √10 from the axis through (3, 0, 0) along y, and
    // stays so when revolved
    const r = g.surface(rev).eval(std.math.pi / 2.0, 1);
    try testing.expectApproxEqAbs(@sqrt(10.0), vec.length(vec.cross(vec.sub(r, .{ 3, 0, 0 }), vec.Y3)), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), r[1], 1e-12);
    const p = try g.addPoint(testing.allocator, .{ 1, 2, 3 });
    try testing.expectEqual(Vec3{ 1, 2, 3 }, g.point(p));
    const l2 = try g.addLine2(testing.allocator, .{ .o = .{ 0, 0 }, .d = .{ 1, 0 } });
    try testing.expectEqual(@as(f64, 2), g.pcurve(l2).eval(2)[0]);
    const knots = [_]f64{ 0, 0, 1, 1 };
    const pts = [_]Vec3{ .{ 0, 0, 1 }, .{ 1, 1, 1 } };
    const n2 = try g.addNurbs2(testing.allocator, .{ .degree = 1, .knots = &knots, .points = &pts });
    try testing.expectEqual(@as(f64, 0.5), g.pcurve(n2).eval(0.5)[1]);

    var copy = try g.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    _ = try g.addPoint(testing.allocator, .{ 9, 9, 9 });
    try testing.expectEqual(@as(usize, 1), copy.points.items.len);
    try testing.expectApproxEqAbs(@as(f64, 2), vec.length(copy.curve(c).eval(1.0)), 1e-12);
}
