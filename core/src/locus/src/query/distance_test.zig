//! The gap between solids on their exact geometry: boxes apart along an axis and across a
//! corner, a box and a cylinder (the exact gap, not the polygons'), two spheres, a pin in
//! a hollow, touching and crossing solids, the search cap; and the triangle distances the
//! search stands on, against brute force.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const tolerance = @import("../tolerance.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const transform = @import("../construct/transform.zig");
const tessellate = @import("../mesh/tessellate.zig");
const distance = @import("distance.zig");
const Vec3 = vec.Vec3;

const tol = tolerance.Tolerance.fromZone(1e-5);
const CLOSE = 1e-7;

/// A body moved by `offset`, with its mesh at `resolution`.
const Meshed = struct {
    body: Body,
    mesh: tessellate.Mesh,
    resolution: tolerance.Resolution,

    fn of(body: Body, offset: Vec3, resolution: tolerance.Resolution) !Meshed {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var original = body;
        defer original.deinit();
        var moved = try transform.transform(testing.allocator, &original, &mat.Affine.translate(offset), .{}, &diag);
        errdefer moved.deinit();
        const mesh = try tessellate.tessellate(testing.allocator, &moved, resolution, .{}, &diag);
        return .{ .body = moved, .mesh = mesh, .resolution = resolution };
    }

    fn deinit(self: *Meshed) void {
        self.mesh.deinit(testing.allocator);
        self.body.deinit();
    }

    fn part(self: *const Meshed) distance.Part {
        return .{ .body = &self.body, .mesh = &self.mesh, .resolution = self.resolution };
    }
};

fn gap(a: *const Meshed, b: *const Meshed, search: f64) !f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return distance.minGap(testing.allocator, a.part(), b.part(), search, .{}, &diag);
}

fn box(size: f64, offset: Vec3) !Meshed {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return Meshed.of(try primitives.box(testing.allocator, tol, size, size, size, false, &diag), offset, .{});
}

test "distance: boxes apart along an axis, across an edge and a corner; the search caps it; touching and crossing are 0" {
    var a = try box(1, .{ 0, 0, 0 });
    defer a.deinit();
    var b = try box(1, .{ 150, 0, 0 });
    defer b.deinit();
    try testing.expectApproxEqAbs(@as(f64, 149), try gap(&a, &b, 1000), CLOSE);
    try testing.expectEqual(@as(f64, 50), try gap(&a, &b, 50));
    var c = try box(1, .{ 4, 5, 0 });
    defer c.deinit();
    try testing.expectApproxEqAbs(@as(f64, 5), try gap(&a, &c, 100), CLOSE);
    var d = try box(1, .{ 3, 3, 3 });
    defer d.deinit();
    try testing.expectApproxEqAbs(@sqrt(12.0), try gap(&a, &d, 100), CLOSE);
    var touching = try box(1, .{ 1, 0, 0 });
    defer touching.deinit();
    try testing.expectEqual(@as(f64, 0), try gap(&a, &touching, 100));
    var crossing = try box(1, .{ 0.5, 0, 0 });
    defer crossing.deinit();
    try testing.expectEqual(@as(f64, 0), try gap(&a, &crossing, 100));
}

test "distance: curved parts on their exact surfaces, not their polygons" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // A cylinder of radius 3 beside a box 2 away from its axis's nearest polygon side: at
    // 7 a turn the polygon's flat is r·cos(π/7) from the axis, the circle r
    const coarse: tolerance.Resolution = .{ .segments = 7 };
    var cyl = try Meshed.of(try primitives.cylinder(testing.allocator, tol, 3, 5, false, &diag), .{ 0, 0, 0 }, coarse);
    defer cyl.deinit();
    var b = try Meshed.of(try primitives.box(testing.allocator, tol, 2, 2, 2, false, &diag), .{ -6, -1, 1 }, coarse);
    defer b.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1), try gap(&cyl, &b, 100), CLOSE);
    try testing.expectApproxEqAbs(@as(f64, 1), try gap(&b, &cyl, 100), CLOSE);
    // Two spheres: centre distance less the radii
    var s1 = try Meshed.of(try primitives.sphere(testing.allocator, tol, 2, &diag), .{ 0, 0, 0 }, .{});
    defer s1.deinit();
    var s2 = try Meshed.of(try primitives.sphere(testing.allocator, tol, 1, &diag), .{ 3, 4, 2 }, .{});
    defer s2.deinit();
    try testing.expectApproxEqAbs(@sqrt(29.0) - 3, try gap(&s1, &s2, 100), CLOSE);
    // A cylinder's flat cap above a sphere
    var cap = try Meshed.of(try primitives.cylinder(testing.allocator, tol, 1, 1, false, &diag), .{ 0.3, 0.2, 2.5 }, .{});
    defer cap.deinit();
    try testing.expectApproxEqAbs(@as(f64, 0.5), try gap(&s1, &cap, 100), CLOSE);
    // A small sphere inside a big one: the gap between their surfaces
    var inner = try Meshed.of(try primitives.sphere(testing.allocator, tol, 0.5, &diag), .{ 0.5, 0, 0 }, .{});
    defer inner.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1), try gap(&s1, &inner, 100), CLOSE);
}

test "distance: the triangle distances against brute force on random pairs" {
    var prng = std.Random.DefaultPrng.init(0xd157);
    const random = prng.random();
    for (0..300) |_| {
        var a: [3]Vec3 = undefined;
        var b: [3]Vec3 = undefined;
        for (&a) |*p| p.* = .{ random.float(f64) * 4, random.float(f64) * 4, random.float(f64) * 4 };
        for (&b) |*p| p.* = .{ random.float(f64) * 4 + 1, random.float(f64) * 4, random.float(f64) * 4 };
        const near = distance.triangleTriangle(a, b);
        // Brute force over barycentric grids: never below the answer (but within a grid
        // cell of it)
        const n = 40;
        var brute = std.math.inf(f64);
        for (0..n + 1) |i| for (0..n + 1 - i) |j| {
            const u = @as(f64, @floatFromInt(i)) / n;
            const v = @as(f64, @floatFromInt(j)) / n;
            const p = vec.add(vec.add(vec.scale(a[0], 1 - u - v), vec.scale(a[1], u)), vec.scale(a[2], v));
            const q = distance.closestOnTriangle(p, b);
            brute = @min(brute, vec.distance(p, q));
        };
        try testing.expect(near.distance <= brute + 1e-12);
        try testing.expect(brute - near.distance <= 0.25);
        try testing.expectApproxEqAbs(near.distance, vec.distance(near.p, near.q), 1e-12);
    }
}
