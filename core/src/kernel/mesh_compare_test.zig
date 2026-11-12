//! The mesh comparison on boxes whose answers are known: one against itself, against itself
//! moved, nested, apart, and tilted; a coarse sphere against a fine one; and nothing.

const std = @import("std");
const testing = std.testing;
const mesh_compare = @import("mesh_compare.zig");
const Mesh = mesh_compare.Mesh;

/// The corners of a box, `lo` to `hi`, and its twelve triangles wound outward.
const Box = struct {
    points: [8][3]f64,

    const triangles = [_][3]u32{
        .{ 0, 2, 1 }, .{ 0, 3, 2 }, // bottom
        .{ 4, 5, 6 }, .{ 4, 6, 7 }, // top
        .{ 0, 1, 5 }, .{ 0, 5, 4 }, // front (y low)
        .{ 1, 2, 6 }, .{ 1, 6, 5 }, // right (x high)
        .{ 2, 3, 7 }, .{ 2, 7, 6 }, // back (y high)
        .{ 3, 0, 4 }, .{ 3, 4, 7 }, // left (x low)
    };

    fn of(lo: [3]f64, hi: [3]f64) Box {
        return .{ .points = .{
            .{ lo[0], lo[1], lo[2] }, .{ hi[0], lo[1], lo[2] }, .{ hi[0], hi[1], lo[2] }, .{ lo[0], hi[1], lo[2] },
            .{ lo[0], lo[1], hi[2] }, .{ hi[0], lo[1], hi[2] }, .{ hi[0], hi[1], hi[2] }, .{ lo[0], hi[1], hi[2] },
        } };
    }

    fn mesh(self: *const Box) Mesh {
        return .{ .points = &self.points, .triangles = &triangles };
    }
};

fn compared(a: Mesh, b: Mesh) !mesh_compare.Comparison {
    return mesh_compare.compare(testing.allocator, a, b, .{ .spacing = 0.05 });
}

test "mesh compare: a box against itself is at no distance, with no volume in one alone" {
    const box = Box.of(.{ 0, 0, 0 }, .{ 1, 2, 3 });
    const c = try compared(box.mesh(), box.mesh());
    // To rounding: a sample inside a face is a sum of its corners
    try testing.expect(c.distance() <= 1e-12);
    try testing.expectEqual(@as(f64, 0), c.only_one);
}

test "mesh compare: a box moved up is as far as it moved, and its slabs above and below are in one alone" {
    const box = Box.of(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    const moved = Box.of(.{ 0, 0, 0.1 }, .{ 1, 1, 1.1 });
    const c = try compared(box.mesh(), moved.mesh());
    try testing.expectApproxEqAbs(@as(f64, 0.1), c.a_to_b, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.1), c.b_to_a, 1e-12);
    // Every line along z passes both: 0.1 below and 0.1 above, exactly
    try testing.expectApproxEqAbs(@as(f64, 0.2), c.only_one, 1e-12);
}

test "mesh compare: a box inside another, and two boxes apart" {
    const outer = Box.of(.{ 0, 0, 0 }, .{ 4, 4, 4 });
    const inner = Box.of(.{ 1, 1, 1 }, .{ 2, 2, 3 });
    const nested = try compared(outer.mesh(), inner.mesh());
    try testing.expectApproxEqAbs(@as(f64, 64 - 2), nested.only_one, 64 * 1e-2);
    // The outer box's corner (4, 4, 4) is 3 from the inner box's (2, 2, 3); the inner box's
    // edge point (2, 2, 2) is 2 from every outer wall it faces, which the samples, 0.05
    // apart, reach within their spacing
    try testing.expectApproxEqAbs(@as(f64, 3), nested.a_to_b, 1e-9);
    try testing.expect(nested.b_to_a <= 2 and nested.b_to_a >= 2 - 0.05);
    const left = Box.of(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    const right = Box.of(.{ 3, 0, 0 }, .{ 4, 1, 1 });
    const apart = try compared(left.mesh(), right.mesh());
    try testing.expectApproxEqAbs(@as(f64, 2), apart.only_one, 2e-2);
    // The left box's far wall is 3 from the right box's near one, square on
    try testing.expectApproxEqAbs(@as(f64, 3), apart.distance(), 1e-9);
}

/// A sphere of radius 1 as a latitude–longitude mesh of `n` bands and `2n` sectors, its
/// points on the sphere; owned by the caller.
fn sphere(allocator: std.mem.Allocator, n: u32) !struct { points: [][3]f64, triangles: [][3]u32 } {
    const sectors = 2 * n;
    var points: std.ArrayList([3]f64) = .empty;
    errdefer points.deinit(allocator);
    try points.append(allocator, .{ 0, 0, -1 });
    for (1..n) |i| {
        const lat = -std.math.pi / 2.0 + std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        for (0..sectors) |j| {
            const lon = 2 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(sectors));
            try points.append(allocator, .{ @cos(lat) * @cos(lon), @cos(lat) * @sin(lon), @sin(lat) });
        }
    }
    try points.append(allocator, .{ 0, 0, 1 });
    const top: u32 = @intCast(points.items.len - 1);
    var triangles: std.ArrayList([3]u32) = .empty;
    errdefer triangles.deinit(allocator);
    const at = struct {
        fn f(ring: usize, j: usize, s: u32) u32 {
            return @intCast(1 + ring * s + j % s);
        }
    }.f;
    for (0..sectors) |j| {
        try triangles.append(allocator, .{ 0, at(0, j + 1, sectors), at(0, j, sectors) });
        try triangles.append(allocator, .{ top, at(n - 2, j, sectors), at(n - 2, j + 1, sectors) });
        for (0..n - 2) |r| {
            try triangles.append(allocator, .{ at(r, j, sectors), at(r, j + 1, sectors), at(r + 1, j + 1, sectors) });
            try triangles.append(allocator, .{ at(r, j, sectors), at(r + 1, j + 1, sectors), at(r + 1, j, sectors) });
        }
    }
    return .{ .points = try points.toOwnedSlice(allocator), .triangles = try triangles.toOwnedSlice(allocator) };
}

test "mesh compare: a coarse sphere against a fine one is within the coarse one's chords, the volume between them thin" {
    const coarse = try sphere(testing.allocator, 8);
    defer testing.allocator.free(coarse.points);
    defer testing.allocator.free(coarse.triangles);
    const fine = try sphere(testing.allocator, 64);
    defer testing.allocator.free(fine.points);
    defer testing.allocator.free(fine.triangles);
    const c = try compared(.{ .points = coarse.points, .triangles = coarse.triangles }, .{ .points = fine.points, .triangles = fine.triangles });
    // The coarse mesh's faces sag below the sphere by less than a band's sagitta, about
    // 1 − cos(π/8) across a quad's diagonal; its corners lie on it
    const sag = 1 - @cos(std.math.pi / 8.0);
    try testing.expect(c.a_to_b > 0.25 * sag and c.a_to_b < sag);
    try testing.expect(c.b_to_a < sag);
    // The volume between them is the fine one's less the coarse one's (it lies inside),
    // a few hundredths of the ball's
    try testing.expect(c.only_one > 0 and c.only_one < 0.1 * 4.0 / 3.0 * std.math.pi);
}

test "mesh compare: nothing against nothing is nothing; something against nothing is infinitely far" {
    const none: Mesh = .{ .points = &.{}, .triangles = &.{} };
    const c = try compared(none, none);
    try testing.expectEqual(@as(f64, 0), c.distance());
    try testing.expectEqual(@as(f64, 0), c.only_one);
    const box = Box.of(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    const one = try compared(box.mesh(), none);
    try testing.expectEqual(std.math.inf(f64), one.a_to_b);
    try testing.expectEqual(@as(f64, 0), one.b_to_a);
    try testing.expectApproxEqAbs(@as(f64, 1), one.only_one, 1e-12);
}
