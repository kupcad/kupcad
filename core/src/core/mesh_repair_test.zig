const std = @import("std");
const testing = std.testing;
const mesh_repair = @import("mesh_repair.zig");

/// A unit cube's corners, and its twelve triangles facing out.
const CORNERS = [_][3]f64{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 } };
const CUBE = [_][3]u32{
    .{ 0, 3, 2 }, .{ 0, 2, 1 }, // bottom
    .{ 4, 5, 6 }, .{ 4, 6, 7 }, // top
    .{ 0, 1, 5 }, .{ 0, 5, 4 }, // front
    .{ 2, 3, 7 }, .{ 2, 7, 6 }, // back
    .{ 3, 0, 4 }, .{ 3, 4, 7 }, // left
    .{ 1, 2, 6 }, .{ 1, 6, 5 }, // right
};
const TOLERANCE = 1e-6;

fn volume(points: []const [3]f64, faces: []const [3]u32) f64 {
    var six: f64 = 0;
    for (faces) |f| {
        const a = points[f[0]];
        const b = points[f[1]];
        const c = points[f[2]];
        six += a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] * c[1] - b[1] * c[0]);
    }
    return six / 6;
}

/// `faces` mended, which the test expects to close.
fn mended(points: []const [3]f64, faces: []const [3]u32) !mesh_repair.Repaired {
    const fixed = try mesh_repair.repair(testing.allocator, .{ .points = points, .faces = faces }, TOLERANCE);
    errdefer fixed.deinit(testing.allocator);
    try testing.expect(fixed.report.closed());
    return fixed;
}

test "mesh repair: a closed mesh is as it was" {
    const report = try mesh_repair.check(testing.allocator, .{ .points = &CORNERS, .faces = &CUBE });
    try testing.expect(report.closed());
    const fixed = try mended(&CORNERS, &CUBE);
    defer fixed.deinit(testing.allocator);
    try testing.expect(!fixed.report.changed());
    try testing.expectEqualSlices([3]u32, &CUBE, fixed.faces);
}

test "mesh repair: a hole is filled, and the crack a T-junction leaves is closed" {
    // No top: its four edges are open, and the hole is one loop
    const open = CUBE[0..2] ++ CUBE[4..];
    const report = try mesh_repair.check(testing.allocator, .{ .points = &CORNERS, .faces = open });
    try testing.expectEqual(@as(usize, 4), report.open_edges);
    try testing.expectEqual([2][3]f64{ .{ 0, 0, 1 }, .{ 0, 1, 1 } }, report.first.?);
    const fixed = try mended(&CORNERS, open);
    defer fixed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), fixed.report.filled);
    try testing.expectApproxEqAbs(@as(f64, 1), volume(fixed.points, fixed.faces), 1e-12);

    // The front cut at the middle of its top edge, which the top doesn't share: the crack
    // along it encloses nothing, so it is fanned shut
    const points = CORNERS ++ [_][3]f64{.{ 0.5, 0, 1 }};
    const cracked = CUBE[0..4].* ++ [_][3]u32{ .{ 0, 1, 8 }, .{ 1, 5, 8 }, .{ 0, 8, 4 } } ++ CUBE[6..].*;
    const sealed = try mended(&points, &cracked);
    defer sealed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), sealed.report.filled);
    try testing.expectApproxEqAbs(@as(f64, 1), volume(sealed.points, sealed.faces), 1e-12);
}

test "mesh repair: points a hair apart are welded, triangles turned to agree, repeats dropped" {
    // The top's two triangles on points of their own, a hair off the cube's
    var points = CORNERS ++ [_][3]f64{ .{ 0, 0, 1 + 1e-9 }, .{ 1, 0, 1 }, .{ 1, 1, 1 - 1e-9 }, .{ 0, 1, 1 } };
    const apart = CUBE[0..2].* ++ [_][3]u32{ .{ 8, 9, 10 }, .{ 8, 10, 11 } } ++ CUBE[4..].*;
    const welded = try mended(&points, &apart);
    defer welded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), welded.report.welded);
    try testing.expectEqual(@as(usize, 8), welded.points.len);
    points[8] = points[0];

    // One triangle turned the wrong way: turned back, as the rest of the cube faces
    var turned = CUBE;
    std.mem.swap(u32, &turned[3][1], &turned[3][2]);
    try testing.expectEqual(@as(usize, 3), (try mesh_repair.check(testing.allocator, .{ .points = &CORNERS, .faces = &turned })).turned_edges);
    const agreed = try mended(&CORNERS, &turned);
    defer agreed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), agreed.report.turned);
    try testing.expectApproxEqAbs(@as(f64, 1), volume(agreed.points, agreed.faces), 1e-12);

    // A triangle twice, and one with a corner twice
    const repeated = CUBE ++ [_][3]u32{ CUBE[5], .{ 1, 1, 2 } };
    const cleaned = try mended(&CORNERS, &repeated);
    defer cleaned.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), cleaned.report.dropped);
}

test "mesh repair: the wall between two boxes is dropped, and what can't be mended is said" {
    // Two cubes side by side, each with its face against the other: a wall of no thickness
    var points: [12][3]f64 = undefined;
    @memcpy(points[0..8], &CORNERS);
    for (points[8..], [_]usize{ 1, 2, 5, 6 }) |*p, k| p.* = .{ CORNERS[k][0] + 1, CORNERS[k][1], CORNERS[k][2] };
    // The second cube's corners: its left side is the first's right
    const map = [_]u32{ 1, 8, 9, 2, 5, 10, 11, 6 };
    var faces: [24][3]u32 = undefined;
    @memcpy(faces[0..12], &CUBE);
    for (faces[12..], CUBE) |*f, c| f.* = .{ map[c[0]], map[c[1]], map[c[2]] };
    // Its left side the first's right turned around, triangle for triangle
    faces[12 + 8] = .{ 1, 6, 2 };
    faces[12 + 9] = .{ 1, 5, 6 };
    try testing.expect((try mesh_repair.check(testing.allocator, .{ .points = &points, .faces = &faces })).shared_edges > 0);
    const joined = try mended(&points, &faces);
    defer joined.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), joined.report.dropped);
    try testing.expectApproxEqAbs(@as(f64, 2), volume(joined.points, joined.faces), 1e-12);

    // A fin on an edge of the cube: three triangles on that edge, which nothing mends
    const fin_points = CORNERS ++ [_][3]f64{.{ 0.5, -1, 0 }};
    const fin = CUBE ++ [_][3]u32{.{ 0, 1, 8 }};
    const left = try mesh_repair.repair(testing.allocator, .{ .points = &fin_points, .faces = &fin }, TOLERANCE);
    defer left.deinit(testing.allocator);
    try testing.expect(!left.report.closed());
    try testing.expectEqual(@as(usize, 1), left.report.shared_edges);
    // Its other two edges stay open: they run into the fin's edge, no loop
    try testing.expectEqual(@as(usize, 2), left.report.open_edges);
    try testing.expectEqual(mesh_repair.Report.Fault.open, left.report.first_kind);
}

test "mesh repair: holes that touch at a point are filled each on its own" {
    // Two triangles gone that share only the corner (1, 1, 1): a top one and a right one
    var faces: std.ArrayList([3]u32) = .empty;
    defer faces.deinit(testing.allocator);
    for (CUBE, 0..) |f, i| if (i != 3 and i != 10) try faces.append(testing.allocator, f);
    const fixed = try mended(&CORNERS, faces.items);
    defer fixed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), fixed.report.filled);
    try testing.expectApproxEqAbs(@as(f64, 1), volume(fixed.points, fixed.faces), 1e-12);
}

test "mesh repair: a sphere with many holes, some touching, is closed again" {
    // A sphere of 24 by 12 quads, and every fifth triangle gone
    const around = 24;
    const down = 12;
    var points: std.ArrayList([3]f64) = .empty;
    defer points.deinit(testing.allocator);
    for (0..down + 1) |i| for (0..around) |j| {
        const theta = std.math.pi * @as(f64, @floatFromInt(i)) / down;
        const phi = 2 * std.math.pi * @as(f64, @floatFromInt(j)) / around;
        try points.append(testing.allocator, .{ @sin(theta) * @cos(phi), @sin(theta) * @sin(phi), @cos(theta) });
    };
    var faces: std.ArrayList([3]u32) = .empty;
    defer faces.deinit(testing.allocator);
    var n: usize = 0;
    for (0..down) |i| for (0..around) |j| {
        const a: u32 = @intCast(i * around + j);
        const b: u32 = @intCast(i * around + (j + 1) % around);
        const c: u32 = a + around;
        const d: u32 = b + around;
        for ([_][3]u32{ .{ a, c, d }, .{ a, d, b } }) |t| {
            defer n += 1;
            if (n % 5 != 0) try faces.append(testing.allocator, t);
        }
    };
    // The poles' rings are points on one point: weld them as a file would have them
    const fixed = try mesh_repair.repair(testing.allocator, .{ .points = points.items, .faces = faces.items }, 1e-9);
    defer fixed.deinit(testing.allocator);
    try testing.expect(fixed.report.closed());
    try testing.expect(fixed.report.filled > 20);
    // Near the whole sphere's volume (a holed facet is patched flat, as it was)
    try testing.expectApproxEqRel(@as(f64, 4.0 / 3.0 * std.math.pi), volume(fixed.points, fixed.faces), 0.05);
}
