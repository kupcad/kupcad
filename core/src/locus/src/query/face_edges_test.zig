const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const types = @import("../topology/types.zig");
const in_face = @import("in_face.zig");
const face_edges = @import("face_edges.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;

const tol = Tolerance.fromZone(1e-5);
/// Corners of the outer ring and the hole, and points along each grid line.
const SIDES = 64;
const GRID = 41;
/// How far from the boundary distances are asked: some points well within, some beyond.
const REACH = 0.05;

test "face edges: a 64-gon with a hole answers as in_face's scans, distances within the reach and where points lie" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var outer: [SIDES]Vec2 = undefined;
    var hole: [SIDES]Vec2 = undefined;
    for (&outer, &hole, 0..) |*o, *h, k| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / SIDES;
        o.* = .{ 3 * @cos(t), 2 * @sin(t) };
        // The hole clockwise, off centre
        h.* = .{ 0.5 + @cos(-t), 0.25 + 0.75 * @sin(-t) };
    }
    var sheet = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &hole }, &diag);
    defer sheet.deinit();
    var solid = try sweep.extrude(testing.allocator, &sheet, .{ 0, 0, 1 }, .{}, &diag);
    defer solid.deinit();
    // The bottom face, with its hole
    var bottom: ?types.FaceIndex = null;
    for (solid.faces.items, 0..) |f, i| {
        if (f.flags.tombstone or f.surface.kind != .plane) continue;
        const loops = solid.loop(f.first_loop).next_in_face != .none;
        if (loops and solid.geometry.planes.items[f.surface.index].frame.origin[2] == 0) bottom = types.FaceIndex.of(i);
    }
    const f = bottom.?;
    var index = try face_edges.FaceEdges.build(testing.allocator, &solid, f, REACH, &diag);
    defer index.deinit(testing.allocator);
    try testing.expect(index.flat != null);
    var inside: usize = 0;
    var near: usize = 0;
    for (0..GRID) |i| for (0..GRID) |j| {
        // A grid over the face's box and past it, its lines through ring corners' heights too
        const p: Vec3 = .{ -3.5 + 7 * @as(f64, @floatFromInt(i)) / (GRID - 1), -2.5 + 5 * @as(f64, @floatFromInt(j)) / (GRID - 1), 0 };
        const uv = in_face.uvOf(&solid, f, p);
        const scanned = try in_face.boundaryDistance(&solid, f, p, &diag);
        const indexed = index.boundaryDistance(&solid, p, REACH);
        if (scanned <= REACH) {
            try testing.expectEqual(scanned, indexed);
            near += 1;
        } else try testing.expect(std.math.isInf(indexed));
        const place = try in_face.classify(&solid, f, p, uv, 0, &diag);
        try testing.expectEqual(place, try index.classify(&solid, p, uv, &diag));
        inside += @intFromBool(place == .inside);
    };
    // The grid reached all three answers' ground
    try testing.expect(inside > 0 and inside < GRID * GRID and near > 0);
    // And a ring's corners, exactly on the boundary
    for (outer[0..4]) |c| try testing.expectEqual(in_face.Place.boundary, try index.classify(&solid, .{ c[0], c[1], 0 }, in_face.uvOf(&solid, f, .{ c[0], c[1], 0 }), &diag));
}
