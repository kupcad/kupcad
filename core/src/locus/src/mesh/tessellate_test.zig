//! The tessellation of a box, a slab with a hole, a cylinder, a sphere, a cone, a torus,
//! a sketch with a hole, a mirrored body, and twice over: every mesh welded (each edge of
//! a closed body once each way, `CHECK_EDGE_PAIRS`), its triangles turned outward
//! (positive signed volume), its area and volume the exact ones for flat faces and
//! within the chords' share of them for curved ones; the edges' polylines.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const tolerance = @import("../tolerance.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const transform = @import("../construct/transform.zig");
const test_bodies = @import("../construct/test_bodies.zig");
const edges = @import("edges.zig");
const tessellate = @import("tessellate.zig");
const boolean = @import("../sketch/boolean.zig");
const mass = @import("../measure/mass.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Mesh = tessellate.Mesh;

const tol = tolerance.Tolerance.fromZone(1e-5);
const PI = std.math.pi;
/// How close a mesh measure is to the exact one, relative.
const CLOSE = 1e-12;

fn meshOf(body: *const Body, resolution: tolerance.Resolution) !Mesh {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return tessellate.tessellate(testing.allocator, body, resolution, .{}, &diag);
}

fn area(mesh: Mesh) f64 {
    var total: f64 = 0;
    for (mesh.triangles) |t| {
        const a = mesh.positions[t[0]];
        const b = mesh.positions[t[1]];
        const c = mesh.positions[t[2]];
        total += vec.length(vec.cross(vec.sub(b, a), vec.sub(c, a))) / 2;
    }
    return total;
}

/// The volume by the divergence theorem over the triangles: positive when they face out.
fn signedVolume(mesh: Mesh) f64 {
    var total: f64 = 0;
    for (mesh.triangles) |t| total += vec.dot(mesh.positions[t[0]], vec.cross(mesh.positions[t[1]], mesh.positions[t[2]])) / 6;
    return total;
}

/// `CHECK_EDGE_PAIRS`: every directed edge of the triangles appears once, and its reverse
/// once: the mesh is closed and consistently wound, with no vertex duplicated.
fn expectEdgePairs(mesh: Mesh) !void {
    var directed: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
    defer directed.deinit(testing.allocator);
    for (mesh.triangles) |t| {
        for (0..3) |i| {
            const entry = try directed.getOrPut(testing.allocator, .{ t[i], t[(i + 1) % 3] });
            try testing.expect(!entry.found_existing);
        }
    }
    var it = directed.keyIterator();
    while (it.next()) |edge| try testing.expect(directed.contains(.{ edge[1], edge[0] }));
}

fn expectNoDegenerate(mesh: Mesh) !void {
    for (mesh.triangles) |t| {
        try testing.expect(t[0] != t[1] and t[1] != t[2] and t[0] != t[2]);
        const a = mesh.positions[t[0]];
        const b = mesh.positions[t[1]];
        const c = mesh.positions[t[2]];
        try testing.expect(vec.lengthSq(vec.cross(vec.sub(b, a), vec.sub(c, a))) > 0);
    }
}

fn countStatus(mesh: Mesh, status: tessellate.Status) usize {
    var n: usize = 0;
    for (mesh.faces) |f| n += @intFromBool(f.status == status);
    return n;
}

test "tessellate: a box is eight vertices and twelve triangles, two per face, closed and outward" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer box.deinit();
    var mesh = try meshOf(&box, .{});
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8), mesh.positions.len);
    try testing.expectEqual(@as(usize, 12), mesh.triangles.len);
    try testing.expectEqual(@as(usize, 6), mesh.faces.len);
    for (mesh.faces) |f| {
        try testing.expectEqual(tessellate.Status.ok, f.status);
        try testing.expectEqual(@as(u32, 2), f.count);
    }
    try expectEdgePairs(mesh);
    try expectNoDegenerate(mesh);
    try testing.expectApproxEqRel(@as(f64, 2 * (6 + 12 + 8)), area(mesh), CLOSE);
    try testing.expectApproxEqRel(@as(f64, 24), signedVolume(mesh), CLOSE);
}

test "tessellate: a slab with a hole, every face planar with a hole or a notch, closed and exact" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const outer = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner = [_]Vec2{ .{ 2, 2 }, .{ 2, 4 }, .{ 4, 4 }, .{ 4, 2 } };
    var sheet = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer sheet.deinit();
    var slab = try sweep.extrude(testing.allocator, &sheet, .{ 0, 0, 3 }, .{}, &diag);
    defer slab.deinit();
    var mesh = try meshOf(&slab, .{});
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 16), mesh.positions.len);
    try testing.expectEqual(@as(usize, 10), mesh.faces.len);
    try testing.expectEqual(@as(usize, 10), countStatus(mesh, .ok));
    // Two caps of 8 points and a hole (8 triangles each), eight walls of 2
    try testing.expectEqual(@as(usize, 2 * 8 + 8 * 2), mesh.triangles.len);
    try expectEdgePairs(mesh);
    try expectNoDegenerate(mesh);
    try testing.expectApproxEqRel(@as(f64, 2 * 96 + 40 * 3 + 8 * 3), area(mesh), CLOSE);
    try testing.expectApproxEqRel(@as(f64, 96 * 3), signedVolume(mesh), CLOSE);
}

test "tessellate: a sketch with a hole is a sheet of n + 2h − 2 triangles facing up" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const outer = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner = [_]Vec2{ .{ 2, 2 }, .{ 2, 4 }, .{ 4, 4 }, .{ 4, 2 } };
    var sheet = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer sheet.deinit();
    var mesh = try meshOf(&sheet, .{});
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8), mesh.triangles.len);
    try testing.expectApproxEqRel(@as(f64, 96), area(mesh), CLOSE);
    for (mesh.triangles) |t| {
        const n = vec.cross(vec.sub(mesh.positions[t[1]], mesh.positions[t[0]]), vec.sub(mesh.positions[t[2]], mesh.positions[t[0]]));
        try testing.expect(n[2] > 0);
    }
}

test "tessellate: a cylinder's caps are polygons on the circle's grid and its sides the quads between, closed, the mesh engine's vertices" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cyl = try primitives.cylinder(testing.allocator, tol, 2, 5, false, &diag);
    defer cyl.deinit();
    const n: u32 = 16;
    var mesh = try meshOf(&cyl, .{ .segments = n });
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(mesh.faces.len, countStatus(mesh, .ok));
    // The grid's 16 points on each circle and no other: what Manifold's cylinder has
    try testing.expectEqual(@as(usize, 2 * n), mesh.positions.len);
    // Each cap 14 triangles, each half side 16 (the quads between the grids split)
    try testing.expectEqual(@as(usize, 2 * (n - 2) + 2 * n), mesh.triangles.len);
    try expectEdgePairs(mesh);
    try expectNoDegenerate(mesh);
    const polygon_area = 0.5 * @as(f64, n) * 4 * @sin(2 * PI / @as(f64, n));
    try testing.expectApproxEqRel(polygon_area * 5, signedVolume(mesh), 1e-9);
    // Every point is on its circle: the grid points are evaluated on the curve
    for (mesh.positions) |p| try testing.expectApproxEqAbs(@as(f64, 2), @sqrt(p[0] * p[0] + p[1] * p[1]), 1e-12);
    // The edges' polylines: the circles' halves run through the grid, the seams are
    // two vertices and smooth (g1), so a viewer draws no seam
    var seams: usize = 0;
    for (mesh.edges) |e| {
        const ids = mesh.verticesOf(e);
        if (e.regularity == .g1) {
            seams += 1;
            try testing.expectEqual(@as(usize, 2), ids.len);
        } else {
            try testing.expectEqual(@as(usize, n / 2 + 1), ids.len);
        }
    }
    try testing.expectEqual(@as(usize, 2), seams);
}

test "tessellate: an odd segment count gives the circle's grid plus the half-circles' meeting point" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var disc = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer disc.deinit();
    var points = try edges.discretize(testing.allocator, &disc, .{ .segments = 7 }, &diag);
    defer points.deinit(testing.allocator);
    // Two half-circle edges: angle 0 and π are the vertices; grid angles 1..3 and 4..6
    // of 2π/7 lie strictly inside them
    var total: usize = 0;
    for (0..disc.edges.items.len) |i| total += points.of(.of(i)).len;
    try testing.expectEqual(@as(usize, 2 * (2 + 3)), total);
}

test "tessellate: a sphere is a closed latitude-longitude mesh facing out, its poles fans, within the chords of the exact ball" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var ball = try primitives.sphere(testing.allocator, tol, 3, &diag);
    defer ball.deinit();
    for ([_]tolerance.Resolution{ .{ .segments = 8 }, .{}, .{ .segments = 64 } }) |resolution| {
        var mesh = try meshOf(&ball, resolution);
        defer mesh.deinit(testing.allocator);
        try testing.expectEqual(mesh.faces.len, countStatus(mesh, .ok));
        try testing.expectEqual(@as(usize, 0), diag.warnings());
        try expectEdgePairs(mesh);
        try expectNoDegenerate(mesh);
        // Every vertex on the sphere; every triangle facing out from the centre
        for (mesh.positions) |p| try testing.expectApproxEqAbs(@as(f64, 3), vec.length(p), 1e-12);
        for (mesh.triangles) |t| {
            const a = mesh.positions[t[0]];
            const nrm = vec.cross(vec.sub(mesh.positions[t[1]], a), vec.sub(mesh.positions[t[2]], a));
            try testing.expect(vec.dot(nrm, a) > 0);
        }
        // The inscribed mesh's volume and area are under the ball's, within the chords'
        // share: a few percent at 8 segments, under a per mille at 64
        const n: f64 = @floatFromInt(resolution.segmentsFor(3));
        const share = 1 - @cos(PI / n) * @cos(PI / n);
        const volume = signedVolume(mesh);
        const exact_volume = 4.0 / 3.0 * PI * 27;
        try testing.expect(volume < exact_volume and volume > exact_volume * (1 - 3 * share));
        const total = area(mesh);
        try testing.expect(total < 4 * PI * 9 and total > 4 * PI * 9 * (1 - 3 * share));
    }
    // At 16 a turn: two poles and 7 parallels of 16, the latitude-longitude grid
    var grid = try meshOf(&ball, .{ .segments = 16 });
    defer grid.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2 + 7 * 16), grid.positions.len);
    try testing.expectEqual(@as(usize, 2 * 16 + 6 * 16 * 2), grid.triangles.len);
}

test "tessellate: a cone's side fans to its apex, a frustum's joins two grids, closed and facing out" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cone = try primitives.cone(testing.allocator, tol, 3, 0, 4, false, &diag);
    defer cone.deinit();
    var mesh = try meshOf(&cone, .{ .segments = 12 });
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(mesh.faces.len, countStatus(mesh, .ok));
    try expectEdgePairs(mesh);
    try expectNoDegenerate(mesh);
    // The base's 12 grid points and the apex
    try testing.expectEqual(@as(usize, 13), mesh.positions.len);
    const base_area = 0.5 * 12 * 9 * @sin(2 * PI / 12.0);
    try testing.expectApproxEqRel(base_area * 4 / 3, signedVolume(mesh), 1e-9);
    // A frustum of radii 3 and 1: the two circles have grids of their own (3 by angle,
    // 1 by length at the default resolution), joined across the side
    var frustum = try primitives.cone(testing.allocator, tol, 3, 1, 4, false, &diag);
    defer frustum.deinit();
    var side = try meshOf(&frustum, .{});
    defer side.deinit(testing.allocator);
    try testing.expectEqual(side.faces.len, countStatus(side, .ok));
    try expectEdgePairs(side);
    try expectNoDegenerate(side);
    const exact = PI * 4.0 / 3.0 * (9 + 3 + 1);
    const volume = signedVolume(side);
    try testing.expect(volume < exact and volume > 0.9 * exact);
}

test "tessellate: a torus is a closed grid of its ring and tube circles, facing out, within the chords of the exact one" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var ring = try primitives.torus(testing.allocator, tol, 5, 1, &diag);
    defer ring.deinit();
    var mesh = try meshOf(&ring, .{ .segments = 16 });
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(mesh.faces.len, countStatus(mesh, .ok));
    try testing.expectEqual(@as(usize, 0), diag.warnings());
    try expectEdgePairs(mesh);
    try expectNoDegenerate(mesh);
    try testing.expectEqual(@as(usize, 16 * 16), mesh.positions.len);
    try testing.expectEqual(@as(usize, 2 * 16 * 16), mesh.triangles.len);
    // Every vertex on the torus: its distance from the ring's circle is the minor radius
    for (mesh.positions) |p| {
        const rho = @sqrt(p[0] * p[0] + p[1] * p[1]);
        try testing.expectApproxEqAbs(@as(f64, 1), @sqrt((rho - 5) * (rho - 5) + p[2] * p[2]), 1e-12);
    }
    const exact = 2 * PI * PI * 5;
    const share = 1 - @cos(PI / 16.0) * @cos(PI / 16.0);
    const volume = signedVolume(mesh);
    try testing.expect(volume < exact and volume > exact * (1 - 3 * share));
}

test "tessellate: the edges' polylines of a box are its twelve edges, two vertices each, creases" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer box.deinit();
    var mesh = try meshOf(&box, .{});
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 12), mesh.edges.len);
    try testing.expectEqual(@as(usize, 24), mesh.edge_vertices.len);
    for (mesh.edges, 0..) |e, i| {
        try testing.expectEqual(@as(usize, i), @backingInt(e.edge));
        try testing.expectEqual(@as(u32, 2), e.count);
        try testing.expectEqual(@import("../topology/types.zig").Regularity.c0, e.regularity);
        const ids = mesh.verticesOf(e);
        try testing.expectEqual(@as(u32, @intCast(@backingInt(box.edge(e.edge).start))), ids[0]);
        try testing.expectEqual(@as(u32, @intCast(@backingInt(box.edge(e.edge).end))), ids[1]);
    }
}

test "tessellate: a mirrored box keeps its triangles facing out" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer box.deinit();
    const affine = mat.Affine.mirror(vec.X3);
    var mirrored = try transform.transform(testing.allocator, &box, &affine, .{}, &diag);
    defer mirrored.deinit();
    var mesh = try meshOf(&mirrored, .{});
    defer mesh.deinit(testing.allocator);
    try expectEdgePairs(mesh);
    try testing.expectApproxEqRel(@as(f64, 24), signedVolume(mesh), CLOSE);
}

test "tessellate: a union whose boundary passes a vertex twice, once along a straight run, keeps the vertex on both passages" {
    // Two sheets of crossing rings (the fuzzer's): their union's boundary runs along the
    // line y = 0.8x through (3, 2.4), a vertex its other passage turns at; the straight
    // run's pieces were once merged into one edge through that vertex, which no
    // triangulation could take. All faces are triangulated and cover the exact area.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const a0 = [_]Vec2{ .{ 6, 4 }, .{ 2, 0 }, .{ 6, 5 } };
    const a1 = [_]Vec2{ .{ 3, 1 }, .{ 3, 6 }, .{ 6, 2 }, .{ 1, 2 }, .{ 6, 3 }, .{ 3, 5 }, .{ 0, 2 } };
    var first = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &a0, &a1 }, &diag);
    defer first.deinit();
    const b0 = [_]Vec2{ .{ 2, 6 }, .{ 5, 4 }, .{ 1, 0 }, .{ 4, 0 }, .{ 0, 6 }, .{ 1, 4 }, .{ 0, 4 } };
    const b1 = [_]Vec2{ .{ 2, 5 }, .{ 0, 1 }, .{ 5, 4 }, .{ 0, 0 }, .{ 3, 2 }, .{ 5, 6 }, .{ 5, 2 }, .{ 0, 1 } };
    var second = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &b0, &b1 }, &diag);
    defer second.deinit();
    var joined = try boolean.boolean(testing.allocator, &.{ &first, &second }, .@"union", .{}, &diag);
    defer joined.deinit();
    var mesh = try meshOf(&joined, .{});
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(mesh.faces.len, countStatus(mesh, .ok));
    try testing.expectApproxEqRel((try mass.mass(&joined, .{}, &diag)).area, area(mesh), 1e-9);
    try testing.expectEqual(@as(usize, 0), diag.warnings());
}

test "tessellate: the same body twice gives the same mesh" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const outer = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner = [_]Vec2{ .{ 2, 2 }, .{ 2, 4 }, .{ 4, 4 }, .{ 4, 2 } };
    var sheet = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer sheet.deinit();
    var slab = try sweep.extrude(testing.allocator, &sheet, .{ 0, 0, 3 }, .{}, &diag);
    defer slab.deinit();
    var first = try meshOf(&slab, .{});
    defer first.deinit(testing.allocator);
    var second = try meshOf(&slab, .{});
    defer second.deinit(testing.allocator);
    try testing.expectEqualSlices([3]u32, first.triangles, second.triangles);
    try testing.expectEqualSlices(Vec3, first.positions, second.positions);
}

test "tessellate: a cancel flag set before the call is error.Canceled" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer box.deinit();
    var flag = std.atomic.Value(bool).init(true);
    try testing.expectError(error.Canceled, tessellate.tessellate(testing.allocator, &box, .{}, .{ .cancel = &flag }, &diag));
}

test "tessellate: a crescent of two circles tangent at a point is simple at every resolution (a cusp)" {
    // The outer disc of radius 2.5 about (0, −1.5) less the inner disc of radius 2 about
    // (0, −1), tangent at (0, 1): a crescent whose two arcs meet at the cusp. Their
    // chords crossed near it however fine the grids; the flatter arc now takes points
    // at the tighter arc's tangent coordinates (edges.matchCusps). Area 2.25π
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const Arc = primitives.OutlineArc;
    const outer = [_]primitives.OutlineEdge{
        .{ .a = .{ 0, 1 }, .b = .{ 0, -4 }, .arc = Arc{ .c = .{ 0, -1.5 }, .r = 2.5, .ccw = true } },
        .{ .a = .{ 0, -4 }, .b = .{ 0, 1 }, .arc = Arc{ .c = .{ 0, -1.5 }, .r = 2.5, .ccw = true } },
    };
    const inner = [_]primitives.OutlineEdge{
        .{ .a = .{ 0, 1 }, .b = .{ 0, -3 }, .arc = Arc{ .c = .{ 0, -1 }, .r = 2, .ccw = true } },
        .{ .a = .{ 0, -3 }, .b = .{ 0, 1 }, .arc = Arc{ .c = .{ 0, -1 }, .r = 2, .ccw = true } },
    };
    var crescent = try primitives.outlines(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer crescent.deinit();
    for ([_]tolerance.Resolution{ .{}, .{ .segments = 8 }, .{ .segments = 64 } }) |resolution| {
        var mesh = try meshOf(&crescent, resolution);
        defer mesh.deinit(testing.allocator);
        for (mesh.faces) |range| try testing.expectEqual(tessellate.Status.ok, range.status);
        try testing.expect(mesh.triangles.len > 0);
        // Within the chords' share of the area: a few percent at the coarsest
        try testing.expectApproxEqRel(2.25 * PI, area(mesh), 0.05);
    }
}

test "tessellate: a sheet with an elliptic side extruded is closed, its side the ellipse's certified chords, within the chords of the exact volume" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sheet = try test_bodies.ellipseSheet(testing.allocator, tol, &diag);
    defer sheet.deinit();
    var block = try sweep.extrude(testing.allocator, &sheet, .{ 0, 0, 4 }, .{}, &diag);
    defer block.deinit();
    for ([_]tolerance.Resolution{ .{}, .{ .segments = 64 } }) |resolution| {
        var mesh = try meshOf(&block, resolution);
        defer mesh.deinit(testing.allocator);
        try testing.expectEqual(mesh.faces.len, countStatus(mesh, .ok));
        try testing.expectEqual(@as(usize, 0), diag.warnings());
        try expectEdgePairs(mesh);
        try expectNoDegenerate(mesh);
        // The half ellipse's edge is cut, and its side face (an extrusion surface) runs
        // between the two copies' chords: every vertex on the ellipse or a corner
        var on_ellipse: usize = 0;
        for (mesh.positions) |p| {
            const dy = (p[1] - 1.5) / 1.5;
            const dx = (p[0] - 2) / 0.8;
            if (p[0] > 2 + 1e-9) {
                try testing.expectApproxEqAbs(@as(f64, 1), dx * dx + dy * dy, 1e-9);
                on_ellipse += 1;
            }
        }
        try testing.expect(on_ellipse >= 2 * 3);
        const exact = (6 + 0.6 * PI) * 4;
        const volume = signedVolume(mesh);
        try testing.expect(volume < exact + 1e-9 and volume > exact * 0.97);
        if (resolution.segments == 64) try testing.expect(volume > exact * 0.999);
    }
}

test "tessellate: a quarter disc with a rational arc extruded, and a spline profile revolved, mesh closed within the chords of the exact volume" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var disc = try test_bodies.quarterDisc(testing.allocator, tol, &diag);
    defer disc.deinit();
    var wedge = try sweep.extrude(testing.allocator, &disc, .{ 0, 0, 3 }, .{}, &diag);
    defer wedge.deinit();
    var mesh = try meshOf(&wedge, .{ .segments = 32 });
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(mesh.faces.len, countStatus(mesh, .ok));
    try expectEdgePairs(mesh);
    try expectNoDegenerate(mesh);
    for (mesh.positions) |p| {
        const rho = @sqrt(p[0] * p[0] + p[1] * p[1]);
        try testing.expect(rho <= 2 + 1e-9);
    }
    const exact = PI * 3;
    const volume = signedVolume(mesh);
    try testing.expect(volume < exact and volume > exact * 0.99);

    // The spline sheet shifted to x in [1, 3] and stood up, turned about z: a ring whose
    // outer and inner walls are surfaces of revolution (the spline is straight, so the
    // exact volume is the rectangle's 6 swept at its centroid's radius 2)
    var sheet = try test_bodies.splineSheet(testing.allocator, tol, &diag);
    defer sheet.deinit();
    var shifted = try transform.transform(testing.allocator, &sheet, &mat.Affine.translate(.{ 1, 0, 0 }), .{}, &diag);
    defer shifted.deinit();
    var profile = try transform.transform(testing.allocator, &shifted, &mat.Affine.rotate(vec.X3, PI / 2.0), .{}, &diag);
    defer profile.deinit();
    var ring = try sweep.revolve(testing.allocator, &profile, vec.ZERO3, vec.Z3, 2 * PI, .{}, &diag);
    defer ring.deinit();
    var ring_mesh = try meshOf(&ring, .{ .segments = 24 });
    defer ring_mesh.deinit(testing.allocator);
    try testing.expectEqual(ring_mesh.faces.len, countStatus(ring_mesh, .ok));
    try expectEdgePairs(ring_mesh);
    try expectNoDegenerate(ring_mesh);
    const ring_exact = 2 * PI * 2 * 6;
    const ring_volume = signedVolume(ring_mesh);
    // The inscribed polygon's share: cos²(π/24) of the area of each disc
    try testing.expect(ring_volume < ring_exact and ring_volume > ring_exact * 0.98);
}

test "tessellate: a box with a bilinear top is two triangles when flat and a refined saddle when not, closed, the exact volume within the chords" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var flat = try test_bodies.patchTopBox(testing.allocator, tol, 0, &diag);
    defer flat.deinit();
    var mesh = try meshOf(&flat, .{});
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(mesh.faces.len, countStatus(mesh, .ok));
    try testing.expectEqual(@as(usize, 8), mesh.positions.len);
    try testing.expectEqual(@as(usize, 12), mesh.triangles.len);
    try expectEdgePairs(mesh);
    try testing.expectApproxEqRel(@as(f64, 24), signedVolume(mesh), CLOSE);

    var saddle = try test_bodies.patchTopBox(testing.allocator, tol, 2, &diag);
    defer saddle.deinit();
    var refined = try meshOf(&saddle, .{});
    defer refined.deinit(testing.allocator);
    try testing.expectEqual(refined.faces.len, countStatus(refined, .ok));
    try expectEdgePairs(refined);
    try expectNoDegenerate(refined);
    // Refined: points inside the top beyond its four corners, every one on the patch
    try testing.expect(refined.positions.len > 8);
    for (refined.positions) |p| {
        if (p[2] <= 4 + 1e-12 and (p[0] == 0 or p[0] == 2 or p[1] == 0 or p[1] == 3)) continue;
        const u = p[0] / 2;
        const v = p[1] / 3;
        try testing.expectApproxEqAbs(4 + 2 * u * v, p[2], 1e-9);
    }
    const exact = 6.0 * (16 + 2) / 4.0;
    try testing.expectApproxEqRel(exact, signedVolume(refined), 0.01);
}
