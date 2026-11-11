//! The mesh validator's verdicts, in the checker's words: a tetrahedron closed, one
//! triangle short oriented, a triangle turned over regular, three triangles on one edge
//! irregular, two tetrahedra at one vertex closed and singular, a repeated corner
//! degenerate; every tessellated primitive closed with no singular vertex.

const std = @import("std");
const testing = std.testing;
const tolerance = @import("../tolerance.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const primitives = @import("../construct/primitives.zig");
const tessellate = @import("tessellate.zig");
const validate = @import("validate.zig");
const condition = @import("../topology/condition.zig");

const tol = tolerance.Tolerance.fromZone(1e-5);
const TETRA = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 0, 3, 2 }, .{ 1, 2, 3 } };

fn verdictOf(triangles: []const [3]u32, n: usize) !validate.Verdict {
    return validate.grade(testing.allocator, triangles, n);
}

test "validate: a tetrahedron closed; short a triangle oriented; one turned over regular; a fin irregular" {
    const whole = try verdictOf(&TETRA, 4);
    try testing.expect(whole.isManifoldClosed());

    const open = try verdictOf(TETRA[0..3], 4);
    try testing.expectEqual(condition.Condition.oriented, open.grade.condition);
    try testing.expectEqual(@as(u32, 0), open.grade.singular_vertices);

    var flipped = TETRA;
    flipped[3] = .{ 1, 3, 2 };
    const turned = try verdictOf(&flipped, 4);
    try testing.expectEqual(condition.Condition.regular, turned.grade.condition);

    // A fin: a third triangle on the edge 0–1
    const fin = TETRA ++ [_][3]u32{.{ 0, 1, 4 }};
    const finned = try verdictOf(&fin, 5);
    try testing.expectEqual(condition.Condition.irregular, finned.grade.condition);
    try testing.expectEqual(@as(?u32, 0), finned.grade.first_short);
}

test "validate: two tetrahedra at one vertex are closed and singular; a repeated corner is degenerate" {
    const pair = TETRA ++ [_][3]u32{ .{ 0, 4, 5 }, .{ 0, 6, 4 }, .{ 0, 5, 6 }, .{ 4, 6, 5 } };
    const v = try verdictOf(&pair, 7);
    try testing.expectEqual(condition.Condition.closed, v.grade.condition);
    try testing.expectEqual(@as(u32, 1), v.grade.singular_vertices);
    try testing.expectEqual(@as(?u32, 0), v.grade.first_singular);
    try testing.expect(!v.isManifoldClosed());

    const bad = TETRA ++ [_][3]u32{.{ 1, 1, 2 }};
    const d = try verdictOf(&bad, 4);
    try testing.expectEqual(@as(u32, 1), d.degenerate_triangles);
    try testing.expectEqual(condition.Condition.closed, d.grade.condition);
    try testing.expect(!d.isManifoldClosed());
}

test "validate: every tessellated primitive is closed with no singular vertex, poles and apexes included" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var bodies = [_]@import("../topology/body.zig").Body{
        try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag),
        try primitives.cylinder(testing.allocator, tol, 2, 3, false, &diag),
        try primitives.cone(testing.allocator, tol, 2, 0, 3, false, &diag),
        try primitives.sphere(testing.allocator, tol, 2, &diag),
        try primitives.torus(testing.allocator, tol, 3, 1, &diag),
    };
    defer for (&bodies) |*b| b.deinit();
    for (&bodies) |*body| {
        var mesh = try tessellate.tessellate(testing.allocator, body, .{ .segments = 16 }, .{}, &diag);
        defer mesh.deinit(testing.allocator);
        const v = try validate.grade(testing.allocator, mesh.triangles, mesh.positions.len);
        try testing.expect(v.isManifoldClosed());
    }
}

test "validate: a lens thinner than its chords, extruded, is refined into a closed mesh, not two quads on one another" {
    // The fuzzer's find of 2026-11-12: two arcs of radius 10 between (0, 0) and (1, 0),
    // each under the 12° a grid step spans, chord onto the same two vertices; the cap's
    // ring was pruned as a spike and the two sides collapsed onto one quad, whose
    // diagonal four triangles used. A pruned spike now refines the face's arcs
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const sweep = @import("../construct/sweep.zig");
    const mass = @import("../measure/mass.zig");
    const r: f64 = 10;
    const d = @sqrt(r * r - 0.25);
    const Arc = primitives.OutlineArc;
    const lens = [_]primitives.OutlineEdge{
        .{ .a = .{ 0, 0 }, .b = .{ 1, 0 }, .arc = Arc{ .c = .{ 0.5, d }, .r = r, .ccw = true } },
        .{ .a = .{ 1, 0 }, .b = .{ 0, 0 }, .arc = Arc{ .c = .{ 0.5, -d }, .r = r, .ccw = true } },
    };
    var sheet = try primitives.outlines(testing.allocator, tol, &.{&lens}, &diag);
    defer sheet.deinit();
    var slab = try sweep.extrude(testing.allocator, &sheet, .{ 0, 0, 2 }, .{}, &diag);
    defer slab.deinit();
    var mesh = try tessellate.tessellate(testing.allocator, &slab, .{}, .{}, &diag);
    defer mesh.deinit(testing.allocator);
    for (mesh.faces) |range| try testing.expect(!range.spikes_pruned);
    const v = try validate.grade(testing.allocator, mesh.triangles, mesh.positions.len);
    try testing.expect(v.isManifoldClosed());
    // Its volume: the lens (two circular segments) times the height, the chords' share off
    var volume: f64 = 0;
    for (mesh.triangles) |t| {
        const vec = @import("../math/vec.zig");
        volume += vec.dot(mesh.positions[t[0]], vec.cross(mesh.positions[t[1]], mesh.positions[t[2]])) / 6;
    }
    const exact = (try mass.mass(&slab, .{}, &diag)).volume;
    try testing.expect(volume > 0.5 * exact and volume <= exact * (1 + 1e-12));
}
