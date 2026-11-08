//! The planar tessellation on a box, a slab with a hole, a cylinder's caps, a sphere (all
//! curved), a sketch with a hole, a mirrored body, and twice over: every mesh welded (each
//! edge of a closed planar body once each way, `CHECK_EDGE_PAIRS`), its triangles turned
//! outward (positive signed volume), its area and volume the exact ones.

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
const edges = @import("edges.zig");
const tessellate = @import("tessellate.zig");
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

test "tessellate: a cylinder's caps are polygons on the circle's grid, its side waits for M3" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cyl = try primitives.cylinder(testing.allocator, tol, 2, 5, false, &diag);
    defer cyl.deinit();
    const n: u32 = 16;
    var mesh = try meshOf(&cyl, .{ .segments = n });
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), countStatus(mesh, .ok));
    try testing.expectEqual(@as(usize, 2), countStatus(mesh, .curved_later));
    // Each cap: the grid's 16 points (the two half-circles meet on it), 14 triangles
    try testing.expectEqual(@as(usize, 2 * (n - 2)), mesh.triangles.len);
    try expectNoDegenerate(mesh);
    const polygon_area = 0.5 * @as(f64, n) * 4 * @sin(2 * PI / @as(f64, n));
    try testing.expectApproxEqRel(2 * polygon_area, area(mesh), 1e-9);
    // Every cap point is on its circle: the grid points are evaluated on the curve
    for (mesh.faces) |f| {
        if (f.status != .ok) continue;
        for (mesh.of(f)) |t| for (t) |v| {
            const p = mesh.positions[v];
            try testing.expectApproxEqAbs(@as(f64, 2), @sqrt(p[0] * p[0] + p[1] * p[1]), 1e-12);
        };
    }
    // The caps face away from each other
    var up: usize = 0;
    var down: usize = 0;
    for (mesh.triangles) |t| {
        const nrm = vec.cross(vec.sub(mesh.positions[t[1]], mesh.positions[t[0]]), vec.sub(mesh.positions[t[2]], mesh.positions[t[0]]));
        if (nrm[2] > 0) up += 1 else down += 1;
    }
    try testing.expectEqual(up, down);
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

test "tessellate: a sphere's faces are all curved, so the mesh has no triangles yet, and nothing fails" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var ball = try primitives.sphere(testing.allocator, tol, 3, &diag);
    defer ball.deinit();
    var mesh = try meshOf(&ball, .{});
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), mesh.triangles.len);
    try testing.expectEqual(mesh.faces.len, countStatus(mesh, .curved_later));
    try testing.expectEqual(@as(usize, 0), diag.warnings());
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
