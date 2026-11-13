//! The degeneracy corpus as OCCT's test scripts state their cases (`checknbshapes`,
//! `checkprops -s -v`, `checkmaxtol`; M4's exit, architecture §9.2): per case, per
//! operation, the result's vertices, edges, faces, solids and voids, its area, its volume
//! and the largest gap the boolean recorded, each answer worked out by hand (in the case's
//! comment), never read off the kernel; and the volume identities on every case,
//! V(A ∪ B) + V(A ∩ B) = V(A) + V(B), V(A − B) = V(A) − V(A ∩ B). The operands are boxes,
//! so each answer has a closed form; the corpus's other configurations (a vertex on a face,
//! a knife edge, a V groove, slivers, the fuzzer's finds) are degeneracy_test.zig's, with
//! the identities there too.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Body = @import("../topology/body.zig").Body;
const mass = @import("../measure/mass.zig");
const diagnostics = @import("../diagnostics.zig");
const pipeline = @import("pipeline.zig");
const helpers = @import("pipeline_test.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);
/// The answers are exact; the measures are sums of products of the boxes' coordinates.
const CLOSE = 1e-9;
/// A merged vertex's centre is rounded at its coordinates: its gap may pass half the
/// distance it merged by that much (64 ulps of the largest coordinate, 2, as D27 reckons).
const GAP_ROUNDING = 64 * std.math.floatEps(f64) * 2;

/// What one operation must give. `vertices` and `edges` are null where solids touch along
/// an edge or at a corner: each solid keeps its own edge there (`EdgeSpec.copy`), a
/// representation's choice OCCT's compounds make otherwise, so the faces, solids and
/// measures say what the result is.
const Expect = struct {
    vertices: ?usize,
    edges: ?usize,
    faces: usize,
    solids: usize,
    voids: usize = 0,
    area: f64,
    volume: f64,
    /// The largest gap the report may record: 0 where every vertex is exact.
    max_gap: f64 = 0,
    /// How far the measures may be from the answer: the slab of faces closer than the
    /// intersection tolerance, which the boolean takes for one plane.
    slack: f64 = CLOSE,
};

const EMPTY: Expect = .{ .vertices = 0, .edges = 0, .faces = 0, .solids = 0, .area = 0, .volume = 0 };

/// A box's counts, area and volume.
fn boxOf(dx: f64, dy: f64, dz: f64) Expect {
    return .{ .vertices = 8, .edges = 12, .faces = 6, .solids = 1, .area = 2 * (dx * dy + dy * dz + dz * dx), .volume = dx * dy * dz };
}

const Case = struct {
    name: []const u8,
    a: [2]Vec3,
    b: [2]Vec3,
    @"union": Expect,
    intersection: Expect,
    difference: Expect,
};

const CASES = [_]Case{
    .{
        // Identical: the union and the intersection are the box, the difference empty
        .name = "identical boxes",
        .a = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .b = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .@"union" = boxOf(2, 2, 2),
        .intersection = boxOf(2, 2, 2),
        .difference = EMPTY,
    },
    .{
        // Nested: the union is the outer box, the intersection the inner, the difference a
        // box with a cube-shaped void (both boxes' counts; area 96 + 24; 64 − 8)
        .name = "a cube inside a cube",
        .a = .{ .{ 0, 0, 0 }, .{ 4, 4, 4 } },
        .b = .{ .{ 1, 1, 1 }, .{ 3, 3, 3 } },
        .@"union" = boxOf(4, 4, 4),
        .intersection = boxOf(2, 2, 2),
        .difference = .{ .vertices = 16, .edges = 24, .faces = 12, .solids = 1, .voids = 1, .area = 120, .volume = 56 },
    },
    .{
        // A box in another's corner, three faces touching with equal normals: the union is
        // the big box, the difference it with a corner notched: 7 of its corners and the
        // notch's 7, the three faces at the corner L-shaped, its other three, the notch's
        // three (V − E + F = 2: 14 − 21 + 9); the notch takes three unit squares and
        // gives three back
        .name = "faces touching with equal normals, a box in another's corner",
        .a = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .b = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .@"union" = boxOf(2, 2, 2),
        .intersection = boxOf(1, 1, 1),
        .difference = .{ .vertices = 14, .edges = 21, .faces = 9, .solids = 1, .area = 24, .volume = 7 },
    },
    .{
        // Two unit cubes face to face, whole: one 2 × 1 × 1 box; touching in a face only,
        // no volume in common
        .name = "faces touching with opposite normals, whole",
        .a = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .b = .{ .{ 1, 0, 0 }, .{ 2, 1, 1 } },
        .@"union" = boxOf(2, 1, 1),
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
    },
    .{
        // Face to face in part: the union is a prism on the octagon (0,0) (2,0) (2,1) (3,1)
        // (3,3) (2,3) (2,2) (0,2) of area 6 and perimeter 12, 2 high: 16 vertices, 24
        // edges, 10 faces, area 2·6 + 12·2, volume 12; the difference keeps the box whole
        .name = "faces touching with opposite normals, in part",
        .a = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .b = .{ .{ 2, 1, 0 }, .{ 3, 3, 2 } },
        .@"union" = .{ .vertices = 16, .edges = 24, .faces = 10, .solids = 1, .area = 36, .volume = 12 },
        .intersection = EMPTY,
        .difference = boxOf(2, 2, 2),
    },
    .{
        // Coplanar overlap (top and bottom in one plane): the union a prism on the octagon
        // (0,0) (2,0) (2,1) (3,1) (3,3) (1,3) (1,2) (0,2), area 7, perimeter 12 (area
        // 14 + 24, volume 14); the intersection the unit square's prism; the difference a
        // prism on the hexagon (0,0) (2,0) (2,1) (1,1) (1,2) (0,2), area 3, perimeter 8
        .name = "coplanar overlap",
        .a = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .b = .{ .{ 1, 1, 0 }, .{ 3, 3, 2 } },
        .@"union" = .{ .vertices = 16, .edges = 24, .faces = 10, .solids = 1, .area = 38, .volume = 14 },
        .intersection = boxOf(1, 1, 2),
        .difference = .{ .vertices = 12, .edges = 18, .faces = 8, .solids = 1, .area = 22, .volume = 6 },
    },
    .{
        // Overlapping at a corner: the union's vertices are each cube's 7 outer corners
        // and the 6 points where an edge of one meets a face of the other; its faces each
        // cube's 3 outer ones whole and 3 L-shaped (V − E + F = 2: 20 − 30 + 12); area
        // 2 · (24 − 3); the difference a cube notched at the far corner
        .name = "two cubes overlapping at a corner",
        .a = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .b = .{ .{ 1, 1, 1 }, .{ 3, 3, 3 } },
        .@"union" = .{ .vertices = 20, .edges = 30, .faces = 12, .solids = 1, .area = 42, .volume = 15 },
        .intersection = boxOf(1, 1, 1),
        .difference = .{ .vertices = 14, .edges = 21, .faces = 9, .solids = 1, .area = 24, .volume = 7 },
    },
    .{
        // The same moved to (1000, -700, 300), where rounding is a thousand times coarser
        // than at the origin: the same answers
        .name = "two cubes overlapping at a corner, at (1000, -700, 300)",
        .a = .{ .{ 1000, -700, 300 }, .{ 1002, -698, 302 } },
        .b = .{ .{ 1001, -699, 301 }, .{ 1003, -697, 303 } },
        .@"union" = .{ .vertices = 20, .edges = 30, .faces = 12, .solids = 1, .area = 42, .volume = 15 },
        .intersection = boxOf(1, 1, 1),
        .difference = .{ .vertices = 14, .edges = 21, .faces = 9, .solids = 1, .area = 24, .volume = 7 },
    },
    .{
        // Touching at a corner: the union two solids, nothing in common
        .name = "a vertex on a vertex",
        .a = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .b = .{ .{ 1, 1, 1 }, .{ 2, 2, 2 } },
        .@"union" = .{ .vertices = null, .edges = null, .faces = 12, .solids = 2, .area = 12, .volume = 2 },
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
    },
    .{
        // Touching along an edge: two solids, nothing in common
        .name = "an edge on an edge",
        .a = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .b = .{ .{ 1, 1, 0 }, .{ 2, 2, 1 } },
        .@"union" = .{ .vertices = null, .edges = null, .faces = 12, .solids = 2, .area = 12, .volume = 2 },
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
    },
    .{
        // A gap of 1e-3, far past the tolerance: two boxes, the second 0.999 long
        .name = "a near-tangent gap of 1e-3",
        .a = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .b = .{ .{ 1.001, 0, 0 }, .{ 2, 1, 1 } },
        .@"union" = .{ .vertices = 16, .edges = 24, .faces = 12, .solids = 2, .area = 6 + 2 * (0.999 + 0.999 + 1), .volume = 1.999 },
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
    },
    .{
        // An overlap of 1e-6, within the tolerance: the faces are one plane, the boxes
        // touch, and the merged vertices' balls are half the overlap; the measures hold to
        // the slab between the planes (1e-6 times the face)
        .name = "a near-tangent overlap of 1e-6",
        .a = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .b = .{ .{ 1 - 1e-6, 0, 0 }, .{ 2, 1, 1 } },
        .@"union" = withGap(boxOf(2, 1, 1), 1e-6),
        .intersection = withGap(EMPTY, 1e-6),
        .difference = withGap(boxOf(1, 1, 1), 1e-6),
    },
};

/// `e` from a boolean whose merged vertices may carry gaps up to half of `overlap` (within
/// the zone) and their centre's rounding, its measures within the slab `overlap` thick
/// over a unit face (twice that over the sides it lengthens or shortens).
fn withGap(e: Expect, overlap: f64) Expect {
    var out = e;
    out.max_gap = overlap / 2 + GAP_ROUNDING;
    out.slack = 4 * overlap + CLOSE;
    return out;
}

fn expectCase(case: Case, a: *const Body, b: *const Body, op: pipeline.Op, want: Expect) !void {
    errdefer std.debug.print("case \"{s}\", {s}\n", .{ case.name, @tagName(op) });
    // The result passes the checker, the overlap rules and its report's own checks
    var result = try helpers.sound(a, b, op);
    defer result.deinit();
    var report = pipeline.Report.init(testing.allocator);
    defer report.deinit();
    var again = try helpers.reported(a, b, op, .{}, &report);
    defer again.deinit();
    const counts = result.counts();
    errdefer std.debug.print("got {d} vertices, {d} edges, {d} faces, shells {any}\n", .{ counts.vertices, counts.edges, counts.faces, helpers.shellKinds(&result) });
    if (want.vertices) |v| try testing.expectEqual(v, counts.vertices);
    if (want.edges) |e| try testing.expectEqual(e, counts.edges);
    try testing.expectEqual(want.faces, counts.faces);
    try testing.expectEqual([2]usize{ want.solids, want.voids }, helpers.shellKinds(&result));
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const m = try mass.mass(&result, .{}, &diag);
    try testing.expectApproxEqAbs(want.area, m.area, want.slack);
    try testing.expectApproxEqAbs(want.volume, m.volume, want.slack);
    errdefer std.debug.print("largest gap {e}, at most {e}\n", .{ report.max_gap, want.max_gap });
    try testing.expect(report.max_gap <= want.max_gap);
}

test "corpus: each case's counts, area, volume and largest gap, every operation" {
    for (CASES) |case| {
        var a = try helpers.box(case.a[0], case.a[1]);
        defer a.deinit();
        var b = try helpers.box(case.b[0], case.b[1]);
        defer b.deinit();
        try expectCase(case, &a, &b, .@"union", case.@"union");
        try expectCase(case, &a, &b, .intersection, case.intersection);
        try expectCase(case, &a, &b, .difference, case.difference);
    }
}

test "corpus: the volume identities hold on every case" {
    for (CASES) |case| {
        errdefer std.debug.print("case \"{s}\"\n", .{case.name});
        var a = try helpers.box(case.a[0], case.a[1]);
        defer a.deinit();
        var b = try helpers.box(case.b[0], case.b[1]);
        defer b.deinit();
        var u = try helpers.sound(&a, &b, .@"union");
        defer u.deinit();
        var i = try helpers.sound(&a, &b, .intersection);
        defer i.deinit();
        var d = try helpers.sound(&a, &b, .difference);
        defer d.deinit();
        const slack = @max(case.@"union".slack, case.intersection.slack, case.difference.slack);
        const va = try helpers.volume(&a);
        const vb = try helpers.volume(&b);
        const vi = try helpers.volume(&i);
        try testing.expectApproxEqAbs(va + vb, try helpers.volume(&u) + vi, slack);
        try testing.expectApproxEqAbs(va - vi, try helpers.volume(&d), slack);
    }
}
