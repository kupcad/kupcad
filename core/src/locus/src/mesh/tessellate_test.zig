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
const validate = @import("validate.zig");
const boolean = @import("../sketch/boolean.zig");
const mass = @import("../measure/mass.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Mesh = tessellate.Mesh;

const tol = tolerance.Tolerance.fromZone(1e-5);
const PI = std.math.pi;
/// How close a mesh measure is to the exact one, relative.
const CLOSE = 1e-12;
/// The 2D chain fuzzer's sheet of 2026-11-21 (bw): three rings of grid points, each point
/// with the bulge and sense of the arc it leaves by (none for a line), as the fuzzer drew
/// them. The third ring's two arcs leave (2, 0) 7.1° apart, curving the same way, and the
/// even-odd sheet keeps the region about the narrow wedge between them.
const WEDGE_RINGS = [_][]const WedgePoint{
    &.{ .{ .p = .{ 6, 0 } }, .{ .p = .{ 4, 3 } }, .{ .p = .{ 1, 5 }, .bulge = -0.5, .ccw = true } },
    &.{ .{ .p = .{ 5, 4 } }, .{ .p = .{ 2, 2 } }, .{ .p = .{ 5, 6 } }, .{ .p = .{ 1, 0 } }, .{ .p = .{ 1, 2 } }, .{ .p = .{ 1, 5 } } },
    &.{ .{ .p = .{ 4, 1 } }, .{ .p = .{ 4, 4 }, .bulge = -0.5, .ccw = true }, .{ .p = .{ 2, 0 }, .bulge = 0.5, .ccw = false }, .{ .p = .{ 4, 3 } } },
};
const WedgePoint = struct { p: Vec2, bulge: ?f64 = null, ccw: bool = false };
/// The lunes of two circles through one vertex, their tangents there the angle apart (in
/// degrees: past the angular tolerance, 0.8°, where the cusp matcher stops) and both
/// centres on one side: radii, and the lune drawn as a sheet or as a hole in a square.
const LUNE_ANGLES = [_]f64{ 1.5, 3, 7.1, 15 };
const LUNE_RADII = [_]f64{ 2.5, 2 };
const LUNE_SQUARE = [2]Vec2{ .{ -6, -6 }, .{ 6, 6 } };
/// The 2D chain fuzzer's sheet of 2026-11-22 (cf), its log's `c` a clockwise arc. Two
/// arcs leave (0, 1), curving the same way, each to a point of the first ring's line from
/// (0, 1) to (3, 3) where another edge crosses it; the even-odd sheet keeps the region
/// between the two arcs and that line, and each arc is one chord, along the line.
const FOLD_RINGS = [_][]const WedgePoint{
    &.{ .{ .p = .{ 0, 1 } }, .{ .p = .{ 2, 5 }, .bulge = -1 }, .{ .p = .{ 0, 1 } }, .{ .p = .{ 3, 3 } }, .{ .p = .{ 4, 3 } }, .{ .p = .{ 3, 5 } }, .{ .p = .{ 5, 2 } }, .{ .p = .{ 2, 0 } } },
    &.{ .{ .p = .{ 2, 6 } }, .{ .p = .{ 1, 5 }, .bulge = -1, .ccw = true }, .{ .p = .{ 4, 6 }, .bulge = 1 }, .{ .p = .{ 1, 5 } }, .{ .p = .{ 4, 4 }, .bulge = -0.5 }, .{ .p = .{ 6, 0 } }, .{ .p = .{ 4, 5 } }, .{ .p = .{ 0, 4 } } },
    &.{ .{ .p = .{ 0, 5 }, .bulge = -0.5 }, .{ .p = .{ 1, 4 } }, .{ .p = .{ 3, 0 } }, .{ .p = .{ 0, 1 }, .bulge = 0.5, .ccw = true } },
};
/// The most rings, and points a ring, of the sheets drawn from `WedgePoint`s.
const MAX_WEDGE_RINGS = 3;
const MAX_WEDGE_POINTS = 8;
/// The region between two arcs leaving one vertex, curving the same way, each to a point
/// of one line through it, and that line (the configuration of find cf): the line's
/// directions from the vertex at the origin, the centres' height over the line, and the
/// two arcs' half-chords along it, the outer's first. Flat enough that an arc is one
/// chord at some resolution, and then the two chords and the line are one line.
const FOLD_DIRECTIONS = [_]Vec2{ .{ 3, 2 }, .{ 1, 0 }, .{ 5, 1 } };
const FOLD_HEIGHTS = [_]f64{ 5, 10, 20 };
const FOLD_REACHES = [_][2]f64{ .{ 1, 0.5 }, .{ 1.5, 0.25 } };
/// The resolutions the sheets of these tests are meshed at: the default, and grids of 4,
/// 8 and 64 segments a circle (the coarse ones leave a flat arc one chord).
const MESH_RESOLUTIONS = [_]tolerance.Resolution{ .{}, .{ .segments = 4 }, .{ .segments = 8 }, .{ .segments = 64 } };
/// A sliver between a flatter arc and a tighter one tangent to it at the origin, both
/// curving up from the x axis, closed by a line between their far ends (the audit's
/// configuration of 2026-11-22: a short tighter arc whose far vertex the cusp matcher left
/// out). The flatter circle's radius, the tighter's as shares of it, and the tighter arc's
/// far end's tangent coordinates (each past the intersection tolerance above the flatter
/// arc there, each within a quarter turn).
const CUSP_FLAT_R: f64 = 1000;
const CUSP_FLAT_REACH: f64 = 100;
const CUSP_TIGHT_SHARES = [_]f64{ 0.5, 0.1, 0.01 };
const CUSP_TIGHT_REACHES = [_]f64{ 0.3, 1, 3 };
/// The audit's own tighter arc: radius 100, its far end at tangent coordinate 0.07.
const CUSP_FIND_SHARE: f64 = 0.1;
const CUSP_FIND_REACH: f64 = 0.07;
/// The square the sliver is a hole in.
const CUSP_SQUARE = [2]Vec2{ .{ -150, -150 }, .{ 150, 150 } };

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
    // `CHECK_EDGE_PAIRS` in the checker's words: closed, no singular vertex, nothing
    // degenerate (mesh/validate.zig)
    const verdict = try validate.grade(testing.allocator, mesh.triangles, mesh.positions.len);
    errdefer std.debug.print("mesh: {s}, {d} singular vertices, {d} degenerate triangles\n", .{ verdict.grade.condition.word(), verdict.grade.singular_vertices, verdict.degenerate_triangles });
    try testing.expect(verdict.isManifoldClosed());
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

test "tessellate: a budget bounds a provisional mesh by edge, face and body, closed still; a body within it gets its full mesh unmarked" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var ball = try primitives.sphere(testing.allocator, tol, 3, &diag);
    defer ball.deinit();
    const fine: tolerance.Resolution = .{ .segments = 256 };
    var full = try tessellate.tessellate(testing.allocator, &ball, fine, .{}, &diag);
    defer full.deinit(testing.allocator);
    try testing.expect(!full.provisional);
    try testing.expectEqual(@as(usize, 2 + 127 * 256), full.positions.len);
    const budget: tessellate.Budget = .{ .points_per_edge = 16, .points_per_face = 1000, .points_per_body = 4000 };
    var bounded = try tessellate.tessellateWithin(testing.allocator, &ball, fine, budget, .{}, &diag);
    defer bounded.deinit(testing.allocator);
    try testing.expect(bounded.provisional);
    try testing.expect(bounded.positions.len <= 4000 + 2 + 4 * 16);
    try testing.expect(bounded.positions.len > 100);
    try testing.expectEqual(bounded.faces.len, countStatus(bounded, .ok));
    try expectEdgePairs(bounded);
    try expectNoDegenerate(bounded);
    for (bounded.positions) |p| try testing.expectApproxEqAbs(@as(f64, 3), vec.length(p), 1e-12);
    const exact = 4.0 / 3.0 * PI * 27;
    try testing.expect(signedVolume(bounded) < exact and signedVolume(bounded) > 0.8 * exact);
    // Each meridian half has its 16 interior points at most
    for (bounded.edges) |e| try testing.expect(e.count <= 16 + 2);
    // The same mesh with an unbounded budget, and a box, which no cap touches
    var free = try tessellate.tessellateWithin(testing.allocator, &ball, fine, tessellate.Budget.unbounded, .{}, &diag);
    defer free.deinit(testing.allocator);
    try testing.expect(!free.provisional);
    try testing.expectEqualSlices([3]u32, full.triangles, free.triangles);
    var box = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer box.deinit();
    var small = try tessellate.tessellateWithin(testing.allocator, &box, .{}, .{ .points_per_edge = 1, .points_per_face = 1, .points_per_body = 1 }, .{}, &diag);
    defer small.deinit(testing.allocator);
    try testing.expect(!small.provisional);
    try testing.expectEqual(@as(usize, 12), small.triangles.len);
    // A cylinder's circles resampled to 8 points per half: still closed, on the circle
    var cyl = try primitives.cylinder(testing.allocator, tol, 2, 5, false, &diag);
    defer cyl.deinit();
    var coarse = try tessellate.tessellateWithin(testing.allocator, &cyl, .{ .segments = 64 }, .{ .points_per_edge = 8, .points_per_face = 1 << 20, .points_per_body = 1 << 20 }, .{}, &diag);
    defer coarse.deinit(testing.allocator);
    try testing.expect(coarse.provisional);
    try testing.expectEqual(@as(usize, 4 + 4 * 8), coarse.positions.len);
    try expectEdgePairs(coarse);
    try expectNoDegenerate(coarse);
    for (coarse.positions) |p| try testing.expectApproxEqAbs(@as(f64, 2), @sqrt(p[0] * p[0] + p[1] * p[1]), 1e-12);
}

test "tessellate: two long arcs tangent at a cusp, each sweeping past a quarter turn, are matched there (fuzz find)" {
    // A fuzz sheet of 2026-11-11 (found unread then, by the exit code): arcs about (2, 2),
    // radius √5, and about (2.25, 2.5), radius √5·1.25, both ending at (1, 0) where the
    // circles are internally tangent, each sweeping some 243°. The cusp matcher measured
    // the flatter arc's reach by its far end's place along the tangent, behind the
    // tangent for an arc past a quarter turn, and matched nothing; the face's chords
    // crossed at every doubling
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const Arc = primitives.OutlineArc;
    // Built as the fuzzer built it: the ring with its two coincident arcs, which cancel
    const P = struct { p: Vec2, bulge: ?f64, ccw: bool };
    const points = [_]P{
        .{ .p = .{ 4, 1 }, .bulge = -1, .ccw = false },
        .{ .p = .{ 3, 1 }, .bulge = 1, .ccw = true },
        .{ .p = .{ 4, 1 }, .bulge = -1, .ccw = true },
        .{ .p = .{ 1, 0 }, .bulge = 0.5, .ccw = false },
        .{ .p = .{ 5, 3 }, .bulge = null, .ccw = false },
    };
    var outline: [points.len]primitives.OutlineEdge = undefined;
    for (points, 0..) |r, k| {
        const a = r.p;
        const b = points[(k + 1) % points.len].p;
        outline[k] = .{ .a = a, .b = b };
        if (r.bulge) |bulge| {
            const half = vec.scale2(vec.sub2(b, a), 0.5);
            const c = vec.add2(vec.add2(a, half), vec.scale2(vec.perp2(half), bulge));
            outline[k].arc = Arc{ .c = c, .r = vec.distance2(a, c), .ccw = r.ccw };
        }
    }
    var sheet = try primitives.outlines(testing.allocator, tol, &.{&outline}, &diag);
    defer sheet.deinit();
    const exact = (try mass.mass(&sheet, .{}, &diag)).area;
    for ([_]tolerance.Resolution{ .{}, .{ .segments = 8 }, .{ .segments = 64 } }) |resolution| {
        var mesh = try meshOf(&sheet, resolution);
        defer mesh.deinit(testing.allocator);
        for (mesh.faces) |range| try testing.expectEqual(tessellate.Status.ok, range.status);
        try testing.expectApproxEqRel(exact, area(mesh), 0.05);
    }
}

test "tessellate: an arc's grid point within the zone of its end is the end's: no chord along the tangent line beside it (fuzz find)" {
    // The locus fuzzer's find (the 10K session on f8c19412, 2026-11-16), a face of a chain
    // moved whole, as it came: a sliver between the line x = 100000 and an arc of radius
    // 3.54 tangent to it at the circle's grid angle π, the arc ending 1.2e-8 rad before
    // it. The grid point at π was the arc's own, 4.2e-8 from its end and on the line, and
    // the ring ran back along the line from it (not simple: the face failed)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const Arc = primitives.OutlineArc;
    const a: Vec2 = .{ 100000, -199995.9593898218 };
    const b: Vec2 = .{ 100000.00573026108, -199995.95857121306 };
    const c: Vec2 = .{ 100000, -199995.75735927073 };
    const outline = [_]primitives.OutlineEdge{
        .{ .a = a, .b = b },
        .{ .a = b, .b = c, .arc = Arc{ .c = .{ 100003.53553390593, -199995.75735931288 }, .r = 3.5355339059327378, .ccw = false } },
        .{ .a = c, .b = a },
    };
    var sheet = try primitives.outlines(testing.allocator, tol, &.{&outline}, &diag);
    defer sheet.deinit();
    const exact = (try mass.mass(&sheet, .{}, &diag)).area;
    // The sliver is a few chords' segments wide: the mesh within the arc's whole segment,
    // ½ r² (θ − sin θ), the most its chords can cut off
    const r = 3.5355339059327378;
    const span = 2 * std.math.asin(vec.distance2(b, c) / (2 * r));
    const segment = r * r * (span - @sin(span)) / 2;
    for ([_]tolerance.Resolution{ .{}, .{ .segments = 8 }, .{ .segments = 64 } }) |resolution| {
        var mesh = try meshOf(&sheet, resolution);
        defer mesh.deinit(testing.allocator);
        for (mesh.faces) |range| try testing.expectEqual(tessellate.Status.ok, range.status);
        try testing.expectApproxEqAbs(exact, area(mesh), segment * (1 + 1e-6));
    }
}

test "tessellate: solids touching at a corner, along an edge or apex to apex are each closed by the mesh's indices" {
    // research/manifold-parity.md: two cubes sharing an edge exported a 3MF object with an
    // edge on four triangles (3MF judges by indices; lib3mf's IsManifoldAndOriented said
    // no); a vertex where solids touch is now a mesh vertex for each, at one place
    const pipeline = @import("../boolean/pipeline.zig");
    const helpers = @import("../boolean/pipeline_test.zig");
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try helpers.box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var corner = try helpers.box(.{ 1, 1, 1 }, .{ 2, 2, 2 });
    defer corner.deinit();
    var edge = try helpers.box(.{ 1, 1, 0 }, .{ 2, 2, 1 });
    defer edge.deinit();
    const hull = @import("../construct/hull.zig");
    var down = try hull.hull(testing.allocator, tol, &.{ .{ 0, 0, 0 }, .{ 1, -1, -2 }, .{ -1, -1, -2 }, .{ 0, 1.5, -2 } }, &diag);
    defer down.deinit();
    var up = try hull.hull(testing.allocator, tol, &.{ .{ 0, 0, 0 }, .{ 1, -1, 2 }, .{ -1, -1, 2 }, .{ 0, 1.5, 2 } }, &diag);
    defer up.deinit();
    const pairs = [_][2]*const Body{ .{ &a, &corner }, .{ &a, &edge }, .{ &down, &up } };
    for (pairs, [_]usize{ 16, 16, 8 }) |pair, vertices| {
        var u = try pipeline.boolean(testing.allocator, pair[0], pair[1], .@"union", .{}, &diag, null);
        defer u.deinit();
        try testing.expectEqual(@as(usize, 2), u.counts().shells);
        var mesh = try meshOf(&u, .{});
        defer mesh.deinit(testing.allocator);
        const verdict = try validate.grade(testing.allocator, mesh.triangles, mesh.positions.len);
        try testing.expect(verdict.isManifoldClosed());
        // Each solid its own vertices where they touch
        try testing.expectEqual(vertices, mesh.positions.len);
        const want = (try mass.mass(pair[0], .{}, &diag)).volume + (try mass.mass(pair[1], .{}, &diag)).volume;
        try testing.expectApproxEqAbs(want, signedVolume(mesh), 1e-12);
    }
}

/// Point `p` turned `quarter` quarter turns about the origin, then mirrored in the y axis
/// when `mirrored`: exact for grid points.
fn wedgeMove(p: Vec2, quarter: usize, mirrored: bool) Vec2 {
    var q = p;
    for (0..quarter) |_| {
        const turned: Vec2 = .{ -q[1], q[0] };
        q = turned;
    }
    return if (mirrored) .{ -q[0], q[1] } else q;
}

/// The sheet of `rings`, each point leaving by the arc of its bulge and sense or by a line,
/// turned `quarter` quarter turns and mirrored when `mirrored` (`wedgeMove`).
fn wedgeSheet(rings: []const []const WedgePoint, quarter: usize, mirrored: bool, diag: *Diagnostics) !Body {
    var storage: [MAX_WEDGE_RINGS][MAX_WEDGE_POINTS]primitives.OutlineEdge = undefined;
    var outlines: [MAX_WEDGE_RINGS][]const primitives.OutlineEdge = undefined;
    for (rings, 0..) |ring, r| {
        for (ring, 0..) |point, k| {
            const a = point.p;
            const b = ring[(k + 1) % ring.len].p;
            storage[r][k] = .{ .a = wedgeMove(a, quarter, mirrored), .b = wedgeMove(b, quarter, mirrored) };
            if (point.bulge) |bulge| {
                const half = vec.scale2(vec.sub2(b, a), 0.5);
                const c = vec.add2(vec.add2(a, half), vec.scale2(vec.perp2(half), bulge));
                storage[r][k].arc = .{ .c = wedgeMove(c, quarter, mirrored), .r = vec.distance2(a, c), .ccw = point.ccw != mirrored };
            }
        }
        outlines[r] = storage[r][0..ring.len];
    }
    return primitives.outlines(testing.allocator, tol, outlines[0..rings.len], diag);
}

/// The sheet and its extrusion by 1 each meshed with every face triangulated at
/// `MESH_RESOLUTIONS`, every triangle of some area, the extrusion's mesh closed with no
/// singular vertex (each solid of regions touching at a corner its own vertices there).
fn expectSheetAndSolidMeshed(sheet: *const Body) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (MESH_RESOLUTIONS) |resolution| {
        errdefer std.debug.print("resolution {any}\n", .{resolution});
        var flat = try meshOf(sheet, resolution);
        defer flat.deinit(testing.allocator);
        for (flat.faces) |range| try testing.expectEqual(tessellate.Status.ok, range.status);
        try expectNoDegenerate(flat);
        var solid = try sweep.extrude(testing.allocator, sheet, .{ 0, 0, 1 }, .{}, &diag);
        defer solid.deinit();
        var mesh = try meshOf(&solid, resolution);
        defer mesh.deinit(testing.allocator);
        for (mesh.faces) |range| try testing.expectEqual(tessellate.Status.ok, range.status);
        try expectNoDegenerate(mesh);
        const verdict = try validate.grade(testing.allocator, mesh.triangles, mesh.positions.len);
        errdefer std.debug.print("mesh {s}, {d} singular\n", .{ verdict.grade.condition.word(), verdict.grade.singular_vertices });
        try testing.expect(verdict.isManifoldClosed());
    }
}

test "tessellate: two arcs leaving a vertex 7° apart, curving the same way, are chorded so that their polylines do not cross, the extrusion's mesh closed, in every quarter turn, mirrored or not (fuzz find bw)" {
    // The 2D chain fuzzer's find (2026-11-21, bw): the flatter arc's one chord from (2, 0)
    // passed over the other arc's grid point 0.2 from the vertex, 1.5e-3 above it, and the
    // face's chorded outline crossed itself there; the triangulator took it, the region
    // between the chords wound twice and covered twice, and the extrusion's top cap was
    // left a side used once, its triangles overlapping
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("quarter turns {d}, mirrored {}\n", .{ quarter, mirrored });
        var sheet = try wedgeSheet(&WEDGE_RINGS, quarter, mirrored, &diag);
        defer sheet.deinit();
        try expectSheetAndSolidMeshed(&sheet);
    };
}

test "tessellate: the lune of two circles through a vertex, their tangents there past the angular tolerance apart, as a sheet or a hole, is meshed and its extrusion closed in every quarter turn, mirrored or not" {
    // The configuration of the find above: two arcs leaving one vertex into a narrow wedge,
    // both curving to one side, where a chord of the flatter can pass over the other's
    // polyline; within the angular tolerance the two are a cusp, matched (`edges.zig`)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (LUNE_ANGLES) |degrees| for ([_]bool{ false, true }) |as_hole| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("{d}°, as a hole {}, quarter turns {d}, mirrored {}\n", .{ degrees, as_hole, quarter, mirrored });
        const angle = degrees * PI / 180;
        const a_centre: Vec2 = .{ 0, LUNE_RADII[0] };
        const b_centre = vec.scale2(.{ -@sin(angle), @cos(angle) }, LUNE_RADII[1]);
        // The circles' second meeting: the vertex reflected in the line of the centres
        const along = vec.sub2(b_centre, a_centre);
        const t = -vec.dot2(a_centre, along) / vec.dot2(along, along);
        const far = vec.scale2(vec.add2(a_centre, vec.scale2(along, t)), 2);
        const v = wedgeMove(.{ 0, 0 }, quarter, mirrored);
        const p = wedgeMove(far, quarter, mirrored);
        // The lune inside the first circle, outside the second: up the first from the
        // vertex counter-clockwise, back down the second clockwise
        var lune = [_]primitives.OutlineEdge{
            .{ .a = v, .b = p, .arc = .{ .c = wedgeMove(a_centre, quarter, mirrored), .r = LUNE_RADII[0], .ccw = !mirrored } },
            .{ .a = p, .b = v, .arc = .{ .c = wedgeMove(b_centre, quarter, mirrored), .r = LUNE_RADII[1], .ccw = mirrored } },
        };
        const lo = LUNE_SQUARE[0];
        const hi = LUNE_SQUARE[1];
        const square = [_]primitives.OutlineEdge{
            .{ .a = lo, .b = .{ hi[0], lo[1] } },
            .{ .a = .{ hi[0], lo[1] }, .b = hi },
            .{ .a = hi, .b = .{ lo[0], hi[1] } },
            .{ .a = .{ lo[0], hi[1] }, .b = lo },
        };
        const with_square = [_][]const primitives.OutlineEdge{ &square, &lune };
        const alone = [_][]const primitives.OutlineEdge{&lune};
        var sheet = try primitives.outlines(testing.allocator, tol, if (as_hole) &with_square else &alone, &diag);
        defer sheet.deinit();
        try expectSheetAndSolidMeshed(&sheet);
    };
}

test "tessellate: two arcs from one vertex to points of one line, their chords fallen onto it, are refined until the region between them has area, its extrusion closed, in every quarter turn, mirrored or not (fuzz find cf)" {
    // The 2D chain fuzzer's find (2026-11-22, cf): each arc one chord along the line, the
    // region's polygon three points of one line, its one triangle of no area; neither
    // neighbour of the fold one mesh vertex, so the spike went unpruned and its arcs
    // unrefined
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("quarter turns {d}, mirrored {}\n", .{ quarter, mirrored });
        var sheet = try wedgeSheet(&FOLD_RINGS, quarter, mirrored, &diag);
        defer sheet.deinit();
        try expectSheetAndSolidMeshed(&sheet);
    };
}

test "tessellate: the region between two arcs leaving one vertex to points of one line, and the line, as a sheet or a hole, is meshed with area and its extrusion closed in every quarter turn, mirrored or not" {
    // The configuration of the find above: both centres over the line, the outer arc to the
    // farther point; where each arc is one chord, the region's chords are the line's
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (FOLD_DIRECTIONS) |direction| for (FOLD_HEIGHTS) |height| for (FOLD_REACHES) |reach| for ([_]bool{ false, true }) |as_hole| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("direction {any}, height {d}, reach {any}, as a hole {}, quarter turns {d}, mirrored {}\n", .{ direction, height, reach, as_hole, quarter, mirrored });
        const d = vec.normalized2(direction).?;
        const n = vec.perp2(d);
        const v = wedgeMove(.{ 0, 0 }, quarter, mirrored);
        const outer_end = wedgeMove(vec.scale2(d, 2 * reach[0]), quarter, mirrored);
        const inner_end = wedgeMove(vec.scale2(d, 2 * reach[1]), quarter, mirrored);
        const outer_centre = vec.add2(vec.scale2(d, reach[0]), vec.scale2(n, height));
        const inner_centre = vec.add2(vec.scale2(d, reach[1]), vec.scale2(n, height));
        // Out along the outer arc, back along the line to the inner arc's end, home along
        // the inner arc: the region on the left, below the line
        var region = [_]primitives.OutlineEdge{
            .{ .a = v, .b = outer_end, .arc = .{ .c = wedgeMove(outer_centre, quarter, mirrored), .r = vec.length2(outer_centre), .ccw = !mirrored } },
            .{ .a = outer_end, .b = inner_end },
            .{ .a = inner_end, .b = v, .arc = .{ .c = wedgeMove(inner_centre, quarter, mirrored), .r = vec.length2(inner_centre), .ccw = mirrored } },
        };
        const lo = LUNE_SQUARE[0];
        const hi = LUNE_SQUARE[1];
        const square = [_]primitives.OutlineEdge{
            .{ .a = lo, .b = .{ hi[0], lo[1] } },
            .{ .a = .{ hi[0], lo[1] }, .b = hi },
            .{ .a = hi, .b = .{ lo[0], hi[1] } },
            .{ .a = .{ lo[0], hi[1] }, .b = lo },
        };
        const with_square = [_][]const primitives.OutlineEdge{ &square, &region };
        const alone = [_][]const primitives.OutlineEdge{&region};
        var sheet = try primitives.outlines(testing.allocator, tol, if (as_hole) &with_square else &alone, &diag);
        defer sheet.deinit();
        try expectSheetAndSolidMeshed(&sheet);
    };
}

/// The cusp sliver (`CUSP_*`): the tighter circle of radius `share · CUSP_FLAT_R`, its arc
/// from the origin to tangent coordinate `reach`, turned and mirrored (`wedgeMove`), alone
/// or as a hole in `CUSP_SQUARE`.
fn cuspSheet(share: f64, reach: f64, quarter: usize, mirrored: bool, as_hole: bool, diag: *Diagnostics) !Body {
    const flat_r = CUSP_FLAT_R;
    const tight_r = share * CUSP_FLAT_R;
    const v = wedgeMove(.{ 0, 0 }, quarter, mirrored);
    const tight_far = wedgeMove(.{ reach, tight_r - @sqrt(tight_r * tight_r - reach * reach) }, quarter, mirrored);
    const flat_far = wedgeMove(.{ CUSP_FLAT_REACH, flat_r - @sqrt(flat_r * flat_r - CUSP_FLAT_REACH * CUSP_FLAT_REACH) }, quarter, mirrored);
    // Along the flatter arc counter-clockwise, back along the line, down the tighter arc
    const sliver = [_]primitives.OutlineEdge{
        .{ .a = v, .b = flat_far, .arc = .{ .c = wedgeMove(.{ 0, flat_r }, quarter, mirrored), .r = flat_r, .ccw = !mirrored } },
        .{ .a = flat_far, .b = tight_far },
        .{ .a = tight_far, .b = v, .arc = .{ .c = wedgeMove(.{ 0, tight_r }, quarter, mirrored), .r = tight_r, .ccw = mirrored } },
    };
    const lo = CUSP_SQUARE[0];
    const hi = CUSP_SQUARE[1];
    const square = [_]primitives.OutlineEdge{
        .{ .a = lo, .b = .{ hi[0], lo[1] } },
        .{ .a = .{ hi[0], lo[1] }, .b = hi },
        .{ .a = hi, .b = .{ lo[0], hi[1] } },
        .{ .a = .{ lo[0], hi[1] }, .b = lo },
    };
    const with_square = [_][]const primitives.OutlineEdge{ &square, &sliver };
    const alone = [_][]const primitives.OutlineEdge{&sliver};
    return primitives.outlines(testing.allocator, tol, if (as_hole) &with_square else &alone, diag);
}

test "tessellate: a short tighter arc tangent to a long flatter one at a cusp has its far vertex matched too, the sliver meshed and its extrusion closed in every quarter turn, mirrored or not, as a sheet or a hole" {
    // The mesher audit (2026-11-22, finding 3): a tighter arc of radius 100 sweeping 7e-4
    // rad, its far vertex 2.2e-5 above a flatter arc of radius 1000 tangent to it at the
    // origin. The cusp matcher gave the flatter arc the tighter one's interior points'
    // tangent coordinates and had none to give: the flatter arc's first chord left the
    // vertex steeper than the tighter arc's only chord, the outline inverted, and no
    // doubling brought it under (the face failed at the default resolution and at 8
    // segments a circle)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for ([_]bool{ false, true }) |as_hole| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("as a hole {}, quarter turns {d}, mirrored {}\n", .{ as_hole, quarter, mirrored });
        var sheet = try cuspSheet(CUSP_FIND_SHARE, CUSP_FIND_REACH, quarter, mirrored, as_hole, &diag);
        defer sheet.deinit();
        try expectSheetAndSolidMeshed(&sheet);
    };
}

test "tessellate: tighter arcs of a half, a tenth and a hundredth of a flatter one's radius, tangent to it at a cusp and ending at three tangent coordinates, are meshed and their extrusions closed in every quarter turn, mirrored or not" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (CUSP_TIGHT_SHARES) |share| for (CUSP_TIGHT_REACHES) |reach| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("radius share {d}, reach {d}, quarter turns {d}, mirrored {}\n", .{ share, reach, quarter, mirrored });
        var sheet = try cuspSheet(share, reach, quarter, mirrored, false, &diag);
        defer sheet.deinit();
        try expectSheetAndSolidMeshed(&sheet);
    };
}
