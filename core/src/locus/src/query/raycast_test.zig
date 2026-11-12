//! Point in face, point in body and the ray cast on every primitive kind, a plate with a
//! hole, a stadium slab (arcs), an elliptic slab (an extrusion surface), a spline ring (a
//! surface of revolution) and a saddle-topped box (a NURBS patch): exact distances and
//! normals, boundary within the zone, edges, vertices and tangencies as touches or single
//! crossings, and the invariant that the crossings along a segment sum to the change in
//! containment from its origin to its end.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const tolerance = @import("../tolerance.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const types = @import("../topology/types.zig");
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const transform = @import("../construct/transform.zig");
const test_bodies = @import("../construct/test_bodies.zig");
const FaceIndex = @import("index.zig").FaceIndex;
const in_face = @import("in_face.zig");
const point_in_body = @import("point_in_body.zig");
const raycast = @import("raycast.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;

const tol = tolerance.Tolerance.fromZone(1e-5);
const PI = std.math.pi;
const CLOSE = 1e-9;

/// A body with its face index, for the queries.
const Indexed = struct {
    body: Body,
    index: FaceIndex,
    diag: Diagnostics,

    fn of(body: Body) !Indexed {
        var self: Indexed = .{ .body = body, .index = undefined, .diag = Diagnostics.init(testing.allocator) };
        self.index = try FaceIndex.build(testing.allocator, &self.body, &self.diag);
        return self;
    }

    fn deinit(self: *Indexed) void {
        self.index.deinit(testing.allocator);
        self.body.deinit();
        self.diag.deinit();
    }

    fn place(self: *Indexed, p: Vec3) !point_in_body.Place {
        return point_in_body.classify(testing.allocator, &self.body, &self.index, p, .{}, &self.diag);
    }

    fn cast(self: *Indexed, o: Vec3, e: Vec3) ![]raycast.Hit {
        return raycast.cast(testing.allocator, &self.body, &self.index, o, e, .{}, &self.diag);
    }

    /// The crossings along the segment sum to the change in containment, for ends off the
    /// boundary.
    fn expectConsistent(self: *Indexed, o: Vec3, e: Vec3) !void {
        const start = try self.place(o);
        const end = try self.place(e);
        if (start == .boundary or end == .boundary) return;
        const hits = try self.cast(o, e);
        defer testing.allocator.free(hits);
        var sum: i32 = 0;
        var last: f64 = -1;
        for (hits) |h| {
            sum += h.crossing;
            try testing.expect(h.t >= last);
            last = h.t;
        }
        const want: i32 = @as(i32, @intFromBool(end == .inside)) - @intFromBool(start == .inside);
        errdefer std.debug.print("segment {any} → {any}: crossings {d}, containment {s} → {s}\n", .{ o, e, sum, @tagName(start), @tagName(end) });
        try testing.expectEqual(want, sum);
    }
};

fn makeBox() !Indexed {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return Indexed.of(try primitives.box(testing.allocator, tol, 10, 10, 10, false, &diag));
}

fn expectHits(hits: []const raycast.Hit, want_t: []const f64, want_crossing: []const i32) !void {
    errdefer for (hits) |h| std.debug.print("hit t {d} crossing {d} normal {any}\n", .{ h.t, h.crossing, h.normal });
    try testing.expectEqual(want_t.len, hits.len);
    for (hits, want_t, want_crossing) |h, t, c| {
        try testing.expectApproxEqAbs(t, h.t, CLOSE);
        try testing.expectEqual(c, h.crossing);
    }
}

test "in_face: a box's top face holds its middle, not a point past it, and its edges are its boundary" {
    var box = try makeBox();
    defer box.deinit();
    // The top face: the one whose outward normal is +z
    var top: ?types.FaceIndex = null;
    for (box.index.faces) |f| {
        const n = in_face.outwardNormal(&box.body, f, in_face.uvOf(&box.body, f, .{ 5, 5, 10 }));
        if (n[2] > 0.5) top = f;
    }
    const f = top.?;
    const middle: Vec3 = .{ 5, 5, 10 };
    try testing.expectEqual(in_face.Place.inside, try in_face.classify(&box.body, f, middle, in_face.uvOf(&box.body, f, middle), tol.zone, &box.diag));
    const past: Vec3 = .{ 15, 5, 10 };
    try testing.expectEqual(in_face.Place.outside, try in_face.classify(&box.body, f, past, in_face.uvOf(&box.body, f, past), tol.zone, &box.diag));
    const on_edge: Vec3 = .{ 10, 5, 10 };
    try testing.expectEqual(in_face.Place.boundary, try in_face.classify(&box.body, f, on_edge, in_face.uvOf(&box.body, f, on_edge), tol.zone, &box.diag));
    const near_edge: Vec3 = .{ 10 - 2e-5, 5, 10 };
    try testing.expectEqual(in_face.Place.inside, try in_face.classify(&box.body, f, near_edge, in_face.uvOf(&box.body, f, near_edge), tol.zone, &box.diag));
}

test "point in body: a box's inside, outside, faces, edges and corners, under its zone" {
    var box = try makeBox();
    defer box.deinit();
    try testing.expectEqual(point_in_body.Place.inside, try box.place(.{ 5, 5, 5 }));
    try testing.expectEqual(point_in_body.Place.inside, try box.place(.{ 0.001, 9.999, 0.001 }));
    try testing.expectEqual(point_in_body.Place.outside, try box.place(.{ -0.001, 5, 5 }));
    try testing.expectEqual(point_in_body.Place.outside, try box.place(.{ 15, 5, 5 }));
    try testing.expectEqual(point_in_body.Place.outside, try box.place(.{ 1e9, 1e9, 1e9 }));
    try testing.expectEqual(point_in_body.Place.boundary, try box.place(.{ 10, 5, 5 }));
    try testing.expectEqual(point_in_body.Place.boundary, try box.place(.{ 10 + 5e-6, 5, 5 }));
    try testing.expectEqual(point_in_body.Place.boundary, try box.place(.{ 10, 10, 5 }));
    try testing.expectEqual(point_in_body.Place.boundary, try box.place(.{ 0, 0, 0 }));
    // A point level with an edge, off the box: the foot rays would graze the edge
    try testing.expectEqual(point_in_body.Place.outside, try box.place(.{ 12, 12, 5 }));
    try testing.expectEqual(point_in_body.Place.outside, try box.place(.{ 12, 12, 12 }));
}

test "ray cast: a box crossed, left from inside, grazed at a corner and an edge, and entered through an edge" {
    var box = try makeBox();
    defer box.deinit();
    // Through the top and the bottom
    const through = try box.cast(.{ 5, 5, 20 }, .{ 5, 5, -10 });
    defer testing.allocator.free(through);
    try expectHits(through, &.{ 10, 20 }, &.{ 1, -1 });
    try testing.expectEqual(Vec3{ 0, 0, 1 }, through[0].normal);
    try testing.expectEqual(Vec3{ 0, 0, -1 }, through[1].normal);
    try testing.expectEqual(Vec3{ 5, 5, 10 }, through[0].point);
    // From inside, only the way out
    const out = try box.cast(.{ 5, 5, 5 }, .{ 5, 5, 15 });
    defer testing.allocator.free(out);
    try expectHits(out, &.{5}, &.{-1});
    // A corner touched from outside (the mesh engine's test): in and out at once
    const corner = try box.cast(.{ -5, -5, 5 }, .{ 5, 5, 15 });
    defer testing.allocator.free(corner);
    try expectHits(corner, &.{ @sqrt(75.0), @sqrt(75.0) }, &.{ 1, -1 });
    // An edge grazed from outside (the line x − z = −10 at y = 5 touches the box along
    // the edge x = 0, z = 10 only): in and out at once
    const edge = try box.cast(.{ -5, 5, 5 }, .{ 5, 5, 15 });
    defer testing.allocator.free(edge);
    try expectHits(edge, &.{ @sqrt(50.0), @sqrt(50.0) }, &.{ 1, -1 });
    // Into the box through an edge, out through the opposite edge (the diagonal of the
    // square section at y = 5)
    const across = try box.cast(.{ -5, 5, -5 }, .{ 15, 5, 15 });
    defer testing.allocator.free(across);
    try expectHits(across, &.{ @sqrt(50.0), @sqrt(450.0) }, &.{ 1, -1 });
    // In through the bottom at (5, 6, 0), out through the edge y = z = 10 at (5, 10, 10)
    const out_edge = try box.cast(.{ 5, 4, -5 }, .{ 5, 12, 15 });
    defer testing.allocator.free(out_edge);
    const span = @sqrt(8.0 * 8.0 + 20.0 * 20.0);
    try expectHits(out_edge, &.{ 0.25 * span, 0.75 * span }, &.{ 1, -1 });
    // Missing it
    const miss = try box.cast(.{ 20, 20, 20 }, .{ 30, 20, 20 });
    defer testing.allocator.free(miss);
    try testing.expectEqual(@as(usize, 0), miss.len);
}

test "ray cast: through the line two solids touch along, out of one before into the other" {
    // The bow tie's prisms touch along x = y = 1: a ray along y = 1 leaves the first
    // solid and enters the second there, which a touch from outside would order the other way
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var bow = try primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 2, 2 }, .{ 2, 0 }, .{ 0, 2 } }, &diag);
    defer bow.deinit();
    var prisms = try Indexed.of(try sweep.extrude(testing.allocator, &bow, .{ 0, 0, 3 }, .{}, &diag));
    defer prisms.deinit();
    const hits = try prisms.cast(.{ -1, 1, 1.5 }, .{ 3, 1, 1.5 });
    defer testing.allocator.free(hits);
    try expectHits(hits, &.{ 1, 2, 2, 3 }, &.{ 1, -1, 1, -1 });
    try prisms.expectConsistent(.{ -1, 1, 1.5 }, .{ 3, 1, 1.5 });
}

test "ray cast and containment: a cylinder across, along its axis, tangent; a cone; a sphere; a torus through its hole" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cyl = try Indexed.of(try primitives.cylinder(testing.allocator, tol, 3, 5, false, &diag));
    defer cyl.deinit();
    const across = try cyl.cast(.{ -10, 0, 2 }, .{ 10, 0, 2 });
    defer testing.allocator.free(across);
    try expectHits(across, &.{ 7, 13 }, &.{ 1, -1 });
    try testing.expectApproxEqAbs(@as(f64, -1), across[0].normal[0], CLOSE);
    // Through the seam's line (x = 3 at the side, where the half faces meet) at y = 0
    const along = try cyl.cast(.{ 1, 1, -5 }, .{ 1, 1, 10 });
    defer testing.allocator.free(along);
    try expectHits(along, &.{ 5, 10 }, &.{ 1, -1 });
    // Tangent to the side at x = 3: a touch
    const tangent = try cyl.cast(.{ 3, -10, 2 }, .{ 3, 10, 2 });
    defer testing.allocator.free(tangent);
    try expectHits(tangent, &.{ 10, 10 }, &.{ 1, -1 });
    try testing.expectEqual(point_in_body.Place.inside, try cyl.place(.{ 0, 0, 2.5 }));
    try testing.expectEqual(point_in_body.Place.outside, try cyl.place(.{ 2.9, 2.9, 2.5 }));
    try testing.expectEqual(point_in_body.Place.boundary, try cyl.place(.{ 3, 0, 2.5 }));
    try testing.expectEqual(point_in_body.Place.boundary, try cyl.place(.{ 0, 3, 0 }));

    var cone = try Indexed.of(try primitives.cone(testing.allocator, tol, 3, 0, 6, false, &diag));
    defer cone.deinit();
    // Across at half height, where the radius is 1.5
    const cone_hits = try cone.cast(.{ -10, 0, 3 }, .{ 10, 0, 3 });
    defer testing.allocator.free(cone_hits);
    try expectHits(cone_hits, &.{ 8.5, 11.5 }, &.{ 1, -1 });
    try testing.expectEqual(point_in_body.Place.inside, try cone.place(.{ 0, 0, 5.9 }));
    try testing.expectEqual(point_in_body.Place.outside, try cone.place(.{ 0, 0, 6.1 }));
    try testing.expectEqual(point_in_body.Place.boundary, try cone.place(.{ 0, 0, 6 }));

    var ball = try Indexed.of(try primitives.sphere(testing.allocator, tol, 3, &diag));
    defer ball.deinit();
    const centre_line = try ball.cast(.{ 0, 0, -10 }, .{ 0, 0, 10 });
    defer testing.allocator.free(centre_line);
    try expectHits(centre_line, &.{ 7, 13 }, &.{ 1, -1 });
    const skew = try ball.cast(.{ -10, 1, 2 }, .{ 10, 1, 2 });
    defer testing.allocator.free(skew);
    try expectHits(skew, &.{ 10 - 2, 10 + 2 }, &.{ 1, -1 });
    for (skew) |h| try testing.expectApproxEqAbs(@as(f64, 1), vec.dot(h.normal, vec.scale(h.point, 1.0 / 3.0)), CLOSE);

    var ring = try Indexed.of(try primitives.torus(testing.allocator, tol, 5, 1, &diag));
    defer ring.deinit();
    const through = try ring.cast(.{ -10, 0, 0 }, .{ 10, 0, 0 });
    defer testing.allocator.free(through);
    try expectHits(through, &.{ 4, 6, 14, 16 }, &.{ 1, -1, 1, -1 });
    try testing.expectEqual(point_in_body.Place.outside, try ring.place(.{ 0, 0, 0 }));
    try testing.expectEqual(point_in_body.Place.inside, try ring.place(.{ 5, 0, 0.5 }));
    try testing.expectEqual(point_in_body.Place.outside, try ring.place(.{ 5, 0, 1.5 }));
    // Tangent to the top of the tube: a touch
    const over = try ring.cast(.{ 5, -10, 1 }, .{ 5, 10, 1 });
    defer testing.allocator.free(over);
    try expectHits(over, &.{ 10, 10 }, &.{ 1, -1 });
}

test "ray cast and containment: a plate with a hole, a stadium slab, free-form faces" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const outer = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner = [_]Vec2{ .{ 4, 4 }, .{ 4, 6 }, .{ 6, 6 }, .{ 6, 4 } };
    var sheet = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer sheet.deinit();
    var plate = try Indexed.of(try sweep.extrude(testing.allocator, &sheet, .{ 0, 0, 2 }, .{}, &diag));
    defer plate.deinit();
    const hole = try plate.cast(.{ 5, 5, -5 }, .{ 5, 5, 5 });
    defer testing.allocator.free(hole);
    try testing.expectEqual(@as(usize, 0), hole.len);
    try testing.expectEqual(point_in_body.Place.outside, try plate.place(.{ 5, 5, 1 }));
    try testing.expectEqual(point_in_body.Place.inside, try plate.place(.{ 2, 5, 1 }));

    const Arc = primitives.OutlineArc;
    const stadium = [_]primitives.OutlineEdge{
        .{ .a = .{ -2, -1 }, .b = .{ 2, -1 } },
        .{ .a = .{ 2, -1 }, .b = .{ 2, 1 }, .arc = Arc{ .c = .{ 2, 0 }, .r = 1, .ccw = true } },
        .{ .a = .{ 2, 1 }, .b = .{ -2, 1 } },
        .{ .a = .{ -2, 1 }, .b = .{ -2, -1 }, .arc = Arc{ .c = .{ -2, 0 }, .r = 1, .ccw = true } },
    };
    var slot = try primitives.outlines(testing.allocator, tol, &.{&stadium}, &diag);
    defer slot.deinit();
    var slab = try Indexed.of(try sweep.extrude(testing.allocator, &slot, .{ 0, 0, 2 }, .{}, &diag));
    defer slab.deinit();
    // Down through the round end, where the slot is 0.6 wide at x = 2.8
    const end = try slab.cast(.{ 10, 0.3, 1 }, .{ -10, 0.3, 1 });
    defer testing.allocator.free(end);
    const x_end = 2 + @sqrt(1 - 0.09);
    try expectHits(end, &.{ 10 - x_end, 10 + x_end }, &.{ 1, -1 });
    try testing.expectEqual(point_in_body.Place.inside, try slab.place(.{ 2.7, 0.5, 1 }));
    try testing.expectEqual(point_in_body.Place.outside, try slab.place(.{ 2.8, 0.7, 1 }));

    // An extrusion surface: the square with a half-ellipse side (centre (2, 1.5), 0.8 by
    // 1.5) extruded 4 up
    var ellipse_sheet = try test_bodies.ellipseSheet(testing.allocator, tol, &diag);
    defer ellipse_sheet.deinit();
    var lens = try Indexed.of(try sweep.extrude(testing.allocator, &ellipse_sheet, .{ 0, 0, 4 }, .{}, &diag));
    defer lens.deinit();
    const bulge = try lens.cast(.{ 10, 1.5, 2 }, .{ -10, 1.5, 2 });
    defer testing.allocator.free(bulge);
    try expectHits(bulge, &.{ 10 - 2.8, 10 }, &.{ 1, -1 });
    try testing.expectApproxEqAbs(@as(f64, 1), bulge[0].normal[0], CLOSE);
    const y = 2.5;
    const x_ellipse = 2 + 0.8 * @sqrt(1 - (y - 1.5) * (y - 1.5) / 2.25);
    const off_axis = try lens.cast(.{ 10, y, 2 }, .{ -10, y, 2 });
    defer testing.allocator.free(off_axis);
    try expectHits(off_axis, &.{ 10 - x_ellipse, 10 }, &.{ 1, -1 });
    try testing.expectEqual(point_in_body.Place.inside, try lens.place(.{ 2.7, 1.5, 2 }));
    try testing.expectEqual(point_in_body.Place.outside, try lens.place(.{ 2.7, 2.8, 2 }));

    // A surface of revolution: the spline sheet stood up and turned (a ring 1 to 3 out,
    // 0 to 3 high)
    var spline = try test_bodies.splineSheet(testing.allocator, tol, &diag);
    defer spline.deinit();
    var shifted = try transform.transform(testing.allocator, &spline, &mat.Affine.translate(.{ 1, 0, 0 }), .{}, &diag);
    defer shifted.deinit();
    var profile = try transform.transform(testing.allocator, &shifted, &mat.Affine.rotate(vec.X3, PI / 2.0), .{}, &diag);
    defer profile.deinit();
    var spun = try Indexed.of(try sweep.revolve(testing.allocator, &profile, vec.ZERO3, vec.Z3, 2 * PI, .{}, &diag));
    defer spun.deinit();
    const ring_hits = try spun.cast(.{ -10, 0.2, 1.5 }, .{ 10, 0.2, 1.5 });
    defer testing.allocator.free(ring_hits);
    const outer_x = @sqrt(9 - 0.04);
    const inner_x = @sqrt(1 - 0.04);
    try expectHits(ring_hits, &.{ 10 - outer_x, 10 - inner_x, 10 + inner_x, 10 + outer_x }, &.{ 1, -1, 1, -1 });
    try testing.expectEqual(point_in_body.Place.inside, try spun.place(.{ 0, 2, 1.5 }));
    try testing.expectEqual(point_in_body.Place.outside, try spun.place(.{ 0, 0.5, 1.5 }));

    // A NURBS face: the box whose top corner above (2, 3) is raised by 2 (z = 4 + 2uv)
    var saddle = try Indexed.of(try test_bodies.patchTopBox(testing.allocator, tol, 2, &diag));
    defer saddle.deinit();
    const down = try saddle.cast(.{ 1, 1.5, 10 }, .{ 1, 1.5, -10 });
    defer testing.allocator.free(down);
    try expectHits(down, &.{ 10 - (4 + 2 * 0.25), 10 }, &.{ 1, -1 });
    try testing.expectEqual(point_in_body.Place.inside, try saddle.place(.{ 1.8, 2.8, 5.5 }));
    try testing.expectEqual(point_in_body.Place.outside, try saddle.place(.{ 0.2, 0.2, 4.5 }));
}

test "ray cast and containment agree on random segments through every kind" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var bodies = [_]Indexed{
        try makeBox(),
        try Indexed.of(try primitives.cylinder(testing.allocator, tol, 3, 5, true, &diag)),
        try Indexed.of(try primitives.sphere(testing.allocator, tol, 3, &diag)),
        try Indexed.of(try primitives.cone(testing.allocator, tol, 3, 1, 4, true, &diag)),
        try Indexed.of(try primitives.torus(testing.allocator, tol, 4, 1.5, &diag)),
    };
    defer for (&bodies) |*b| b.deinit();
    var prng = std.Random.DefaultPrng.init(0x7a7);
    const random = prng.random();
    for (&bodies) |*b| {
        for (0..40) |_| {
            const o: Vec3 = .{ random.float(f64) * 20 - 8, random.float(f64) * 20 - 8, random.float(f64) * 20 - 8 };
            const e: Vec3 = .{ random.float(f64) * 20 - 8, random.float(f64) * 20 - 8, random.float(f64) * 20 - 8 };
            try b.expectConsistent(o, e);
        }
    }
    // A sphere's containment is |p| < r, away from the surface
    for (0..300) |_| {
        const p: Vec3 = .{ random.float(f64) * 8 - 4, random.float(f64) * 8 - 4, random.float(f64) * 8 - 4 };
        const r = vec.length(p);
        if (@abs(r - 3) < 1e-3) continue;
        const want: point_in_body.Place = if (r < 3) .inside else .outside;
        try testing.expectEqual(want, try bodies[2].place(p));
    }
}
