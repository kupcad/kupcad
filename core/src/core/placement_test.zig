//! Placements (placement.zig) put a copy where the kernel does: each is checked against the
//! mesh the mesh engine makes for the same translates and rotates.

const std = @import("std");
const testing = std.testing;
const Placement = @import("placement.zig").Placement;
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../kernel/geometry_handle.zig");

/// A mesh's vertex positions, sorted, so two meshes of one shape compare whatever order
/// their vertices come in.
fn sortedVertices(handle: geom.GeometryHandle) ![][3]f64 {
    const mesh = kernel.getMesh(testing.allocator, handle) orelse return error.NoMesh;
    defer testing.allocator.free(mesh.vert_props);
    defer testing.allocator.free(mesh.tri_verts);
    const count = mesh.vert_props.len / mesh.num_prop;
    const points = try testing.allocator.alloc([3]f64, count);
    for (points, 0..) |*p, i| {
        for (p, mesh.vert_props[i * mesh.num_prop ..][0..3]) |*c, v| c.* = v;
    }
    sortPoints(points);
    return points;
}

fn sortPoints(points: [][3]f64) void {
    std.mem.sortUnstable([3]f64, points, {}, struct {
        fn lessThan(_: void, a: [3]f64, b: [3]f64) bool {
            for (a, b) |x, y| if (x != y) return x < y;
            return false;
        }
    }.lessThan);
}

/// Whether `placement` puts `base`'s vertices where `placed`'s are.
fn expectPlaces(placement: Placement, base: geom.GeometryHandle, placed: geom.GeometryHandle) !void {
    const expected = try sortedVertices(placed);
    defer testing.allocator.free(expected);
    const got = try sortedVertices(base);
    defer testing.allocator.free(got);
    for (got) |*p| p.* = placement.apply(p.*);
    // Rounded to the f32 the meshes hold, so near-ties sort alike
    for (got) |*p| for (p) |*c| {
        c.* = @as(f32, @floatCast(c.*));
    };
    sortPoints(got);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| for (e, g) |a, b| try testing.expectApproxEqAbs(a, b, 1e-4);
}

test "placement: a rotation is exact at quarter turns" {
    const quarter = Placement.rotation(0, 0, 90);
    try testing.expectEqual([3]f64{ 0, 1, 0 }, quarter.m[0]);
    try testing.expectEqual([3]f64{ -1, 0, 0 }, quarter.m[1]);
    const half = Placement.rotation(180, 0, 0);
    try testing.expectEqual([3]f64{ 0, -1, 0 }, half.m[1]);
    try testing.expectEqual([3]f64{ 0, 0, -1 }, half.m[2]);
    // -270° about y is +90°: x turns to -z
    try testing.expectEqual([3]f64{ 0, 0, -1 }, Placement.rotation(0, -270, 0).m[0]);
}

test "placement: rotations and translations place a shape where the mesh engine does" {
    const base = kernel.cube(&.{}, 1, 2, 3, false) orelse return error.KernelFailed;
    defer kernel.destruct(base);
    const angles = [_][3]f64{ .{ 37, -12, 200 }, .{ 90, 45, 30 }, .{ 0, 0, 135 }, .{ -30, 60, -90 }, .{ 405, 0, 0 } };
    for (angles) |a| {
        errdefer std.debug.print("rotate({d}, {d}, {d})\n", .{ a[0], a[1], a[2] });
        const turned = kernel.rotate(base, a[0], a[1], a[2]) orelse return error.KernelFailed;
        defer kernel.destruct(turned);
        try expectPlaces(Placement.rotation(a[0], a[1], a[2]), base, turned);
        // The outer one places what the inner one placed: translate(rotate(cube))
        const moved = kernel.translate(turned, 4, -5, 6) orelse return error.KernelFailed;
        defer kernel.destruct(moved);
        try expectPlaces(Placement.translation(4, -5, 6).then(Placement.rotation(a[0], a[1], a[2])), base, moved);
    }
}
