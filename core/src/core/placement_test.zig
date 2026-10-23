//! Placements (placement.zig) put a copy where the kernel does: each is checked against the
//! mesh the mesh engine makes for the same translates and rotates.

const std = @import("std");
const testing = std.testing;
const placement_mod = @import("placement.zig");
const Placement = placement_mod.Placement;
const kernel = @import("../kernel/kernel.zig");
const geom = @import("geometry_handle.zig");

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

test "placement: a turn about any axis is the rotation of its three angles" {
    const Case = struct { axis: [3]f64, deg: f64 };
    const cases = [_]Case{
        .{ .axis = .{ 1, 1, 1 }, .deg = 120 },
        .{ .axis = .{ 0.3, -0.5, 2 }, .deg = 37 },
        .{ .axis = .{ 1, 0, 0 }, .deg = -15 },
        // Straight up or down in y: x and z turn about one line
        .{ .axis = .{ 0, 1, 0 }, .deg = 90 },
        .{ .axis = .{ 0, -3, 0 }, .deg = 90 },
        .{ .axis = .{ 2, 1, 0 }, .deg = 200 },
    };
    const probes = [_][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 1, 2, 3 } };
    for (cases) |case| {
        errdefer std.debug.print("axis {any} by {d}\n", .{ case.axis, case.deg });
        const angles = placement_mod.eulerOfAxisAngle(case.axis, case.deg);
        const turned = Placement.rotation(angles[0], angles[1], angles[2]);
        // Rodrigues: v cos θ + (k × v) sin θ + k (k·v)(1 − cos θ)
        const len = @sqrt(case.axis[0] * case.axis[0] + case.axis[1] * case.axis[1] + case.axis[2] * case.axis[2]);
        const k = [3]f64{ case.axis[0] / len, case.axis[1] / len, case.axis[2] / len };
        const theta = std.math.degreesToRadians(case.deg);
        for (probes) |v| {
            const kv = k[0] * v[0] + k[1] * v[1] + k[2] * v[2];
            const kxv = [3]f64{ k[1] * v[2] - k[2] * v[1], k[2] * v[0] - k[0] * v[2], k[0] * v[1] - k[1] * v[0] };
            const got = turned.apply(v);
            for (0..3) |i| {
                const expected = v[i] * @cos(theta) + kxv[i] * @sin(theta) + k[i] * kv * (1 - @cos(theta));
                try testing.expectApproxEqAbs(expected, got[i], 1e-12);
            }
        }
    }
    // A quarter turn about an axis stays the kernel's exact quarter turn
    try testing.expectEqual([3]f64{ 0, 0, 90 }, placement_mod.eulerOfAxisAngle(.{ 0, 0, 1 }, 90));
    try testing.expectEqual([3]f64{ 90, 0, 0 }, placement_mod.eulerOfAxisAngle(.{ 5, 0, 0 }, 90));
}
