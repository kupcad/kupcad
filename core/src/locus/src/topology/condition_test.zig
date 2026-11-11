//! A shell's condition and singular vertices, from the body, in the checker's report:
//! a box closed; a sheet oriented (its boundary edges have one face); a partner turned
//! the same way regular; two tetrahedra sharing a vertex closed with a singular vertex,
//! which the checker's level 2 warns of on a solid; two squares touching at a corner a
//! sheet with a singular vertex, not warned of.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const tolerance = @import("../tolerance.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const types = @import("types.zig");
const check = @import("check.zig");
const condition = @import("condition.zig");
const primitives = @import("../construct/primitives.zig");
const boolean = @import("../sketch/boolean.zig");
const Vec3 = vec.Vec3;

const tol = tolerance.Tolerance.fromZone(1e-5);

fn onlyShell(report: *const check.Report) condition.Grade {
    std.debug.assert(report.shells.items.len == 1);
    return report.shells.items[0].grade;
}

test "condition: the order of the conditions, and an edge's share" {
    try testing.expect(condition.Condition.closed.atLeast(.oriented));
    try testing.expect(!condition.Condition.regular.atLeast(.oriented));
    try testing.expectEqual(condition.Condition.regular, condition.Condition.meet(.closed, .regular));
    try testing.expectEqual(condition.Condition.irregular, condition.edgeCondition(3, true));
    try testing.expectEqual(condition.Condition.irregular, condition.edgeCondition(0, true));
    try testing.expectEqual(condition.Condition.oriented, condition.edgeCondition(1, true));
    try testing.expectEqual(condition.Condition.regular, condition.edgeCondition(2, false));
    try testing.expectEqual(condition.Condition.closed, condition.edgeCondition(2, true));
    try testing.expectEqualStrings("closed", condition.Condition.closed.word());
}

test "condition: a box is closed, a sheet oriented, a partner turned the same way regular" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer box.deinit();
    var report = try check.run(testing.allocator, &box, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    try testing.expect(onlyShell(&report).isManifoldClosed());

    var square = try primitives.square(testing.allocator, tol, 2, 2, false, &diag);
    defer square.deinit();
    var sheet_report = try check.run(testing.allocator, &square, .global);
    defer sheet_report.deinit(testing.allocator);
    const sheet = onlyShell(&sheet_report);
    try testing.expectEqual(condition.Condition.oriented, sheet.condition);
    try testing.expect(sheet.first_short != null);
    try testing.expectEqual(@as(u32, 0), sheet.singular_vertices);

    // Every curved primitive is closed with no singular vertex: a sphere's poles, a cone's
    // apex and the seams are one fan each
    var sphere = try primitives.sphere(testing.allocator, tol, 2, &diag);
    defer sphere.deinit();
    var cone = try primitives.cone(testing.allocator, tol, 2, 0, 3, false, &diag);
    defer cone.deinit();
    var torus = try primitives.torus(testing.allocator, tol, 3, 1, &diag);
    defer torus.deinit();
    for ([_]*const @import("body.zig").Body{ &sphere, &cone, &torus }) |body| {
        var r = try check.run(testing.allocator, body, .global);
        defer r.deinit(testing.allocator);
        try testing.expect(r.ok());
        try testing.expect(onlyShell(&r).isManifoldClosed());
    }

    // A partner turned the same way: regular, and the structural rule says so first
    var flipped = try box.clone(testing.allocator);
    defer flipped.deinit();
    const c = flipped.edge(types.EdgeIndex.of(0)).coedge;
    const p = flipped.coedge(c).partner;
    flipped.coedge(p).same_sense = flipped.coedge(c).same_sense;
    const grade = try condition.ofShell(testing.allocator, &flipped, flipped.first_shell);
    try testing.expectEqual(condition.Condition.regular, grade.condition);
    try testing.expectEqual(@as(?u32, 0), grade.first_short);
}

test "condition: two tetrahedra sharing a vertex are closed with a singular vertex, warned of; two squares at a corner are not warned of" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const pts = [_]Vec3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 0, -1 } };
    // Each tetrahedron's faces counter-clockwise from outside
    const tris = [_][3]u32{
        .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 0, 3, 2 }, .{ 1, 2, 3 },
        .{ 0, 4, 5 }, .{ 0, 6, 4 }, .{ 0, 5, 6 }, .{ 4, 6, 5 },
    };
    var pair = try primitives.polyhedron(testing.allocator, tol, &pts, &tris, &diag);
    defer pair.deinit();
    var report = try check.run(testing.allocator, &pair, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    // Two shells sharing one vertex record: each closed, each charged with it
    try testing.expectEqual(@as(usize, 2), report.shells.items.len);
    for (report.shells.items) |sg| {
        try testing.expectEqual(condition.Condition.closed, sg.grade.condition);
        try testing.expectEqual(@as(u32, 1), sg.grade.singular_vertices);
        try testing.expect(!sg.grade.isManifoldClosed());
    }
    const shared = report.shells.items[0].grade.first_singular.?;
    try testing.expectEqual(shared, report.shells.items[1].grade.first_singular.?);
    // Alone, neither shell sees it
    try testing.expectEqual(@as(u32, 0), (try condition.ofShell(testing.allocator, &pair, report.shells.items[0].shell)).singular_vertices);
    // Warned of once per shell
    var warned: usize = 0;
    for (report.findings.items) |f| warned += @intFromBool(f.code == .singular_vertex and f.entity.index == shared);
    try testing.expectEqual(@as(usize, 2), warned);
    try testing.expectEqual(@as(usize, 2), report.warnings());

    // Two squares touching at (2, 2): their union is a sheet with a singular vertex
    var a = try primitives.square(testing.allocator, tol, 2, 2, false, &diag);
    defer a.deinit();
    const outer = [_]vec.Vec2{ .{ 2, 2 }, .{ 4, 2 }, .{ 4, 4 }, .{ 2, 4 } };
    var b = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{&outer}, &diag);
    defer b.deinit();
    var joined = try boolean.boolean(testing.allocator, &.{ &a, &b }, .@"union", .{}, &diag);
    defer joined.deinit();
    var sheet_report = try check.run(testing.allocator, &joined, .global);
    defer sheet_report.deinit(testing.allocator);
    try testing.expect(sheet_report.ok());
    // Each region's shell is charged with the one corner they share
    try testing.expect(sheet_report.shells.items.len >= 1);
    for (sheet_report.shells.items) |sg| {
        try testing.expectEqual(@as(u32, 1), sg.grade.singular_vertices);
        try testing.expectEqual(condition.Condition.oriented, sg.grade.condition);
    }
    for (sheet_report.findings.items) |f| try testing.expect(f.code != .singular_vertex);
}
