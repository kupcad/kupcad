//! Simplification alone, and Mäntylä's table: a box whose top is two faces on one plane
//! becomes a box of six faces; one whose top's two halves differ in attribute stays in
//! seven; an edge split at a vertex on its line is one edge again; the selection table row
//! by row.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const primitives = @import("../construct/primitives.zig");
const sew = @import("../construct/sew.zig");
const simplify = @import("simplify.zig");
const euler = @import("../topology/euler.zig");
const traverse = @import("../topology/traverse.zig");
const curves = @import("../geometry/curves.zig");
const select = @import("select.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);

/// A unit cube whose top is split along x = 0.5 into two faces on one plane, of
/// attributes `left` and `right`; the front's top edge split there too, at a vertex of
/// the split.
fn splitTop(left: u32, right: u32) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.Builder.init(testing.allocator, tol, .solid, &diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const corners = [_]Vec3{
        .{ 0, 0, 0 },   .{ 1, 0, 0 },   .{ 1, 1, 0 }, .{ 0, 1, 0 },
        .{ 0, 0, 1 },   .{ 1, 0, 1 },   .{ 1, 1, 1 }, .{ 0, 1, 1 },
        .{ 0.5, 0, 1 }, .{ 0.5, 1, 1 },
    };
    var v: [10]types.VertexIndex = undefined;
    for (corners, 0..) |p, i| v[i] = try b.vertex(p);
    // Faces as corner cycles counter-clockwise about their outward normals
    const cycles = [_][]const u8{
        &.{ 0, 3, 2, 1 }, // bottom
        &.{ 4, 8, 9, 7 }, // top left
        &.{ 8, 5, 6, 9 }, // top right
        &.{ 0, 1, 5, 8, 4 }, // front
        &.{ 1, 2, 6, 5 }, // right
        &.{ 2, 3, 7, 9, 6 }, // back
        &.{ 3, 0, 4, 7 }, // left
    };
    const normals = [_]Vec3{ vec.neg(vec.Z3), vec.Z3, vec.Z3, vec.neg(vec.Y3), vec.X3, vec.Y3, vec.neg(vec.X3) };
    const attributes = [_]u32{ 0, left, right, 0, 0, 0, 0 };
    var edges: [7][5]sew.EdgeSpec = undefined;
    var loops: [7][1]sew.LoopSpec = undefined;
    var faces: [7]sew.FaceSpec = undefined;
    for (cycles, normals, attributes, 0..) |cycle, n, attribute, f| {
        for (cycle, 0..) |c, k| edges[f][k] = try b.straight(v[c], v[cycle[(k + 1) % cycle.len]]);
        loops[f] = .{.{ .edges = edges[f][0..cycle.len] }};
        const x = vec.normalized(vec.sub(corners[cycle[1]], corners[cycle[0]])).?;
        var holds: [5]vec.Vec3 = undefined;
        for (cycle, 0..) |c, k| holds[k] = corners[c];
        const plane = try b.facingPlane(geometry.Frame.init(corners[cycle[0]], x, n), holds[0..cycle.len]);
        const frame = b.body.geometry.planes.items[plane.surface.index].frame;
        var uv = geometry.Box2.empty;
        for (cycle) |c| {
            const l = frame.toLocal(corners[c]);
            uv.grow(.{ l[0], l[1] });
        }
        faces[f] = .{ .surface = plane.surface, .same_sense = plane.same_sense, .loops = &loops[f], .uv_box = uv, .attribute = attribute };
    }
    return b.finish(&faces, .outer);
}

fn expectValid(body: *const Body) !void {
    var report = try check.run(testing.allocator, body, .global);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| std.debug.print("checker: {f}\n", .{f});
    try testing.expect(report.ok());
}

test "simplify: two faces on one plane become one, and the vertices left on straight edges go" {
    var body = try splitTop(0, 0);
    defer body.deinit();
    try testing.expectEqual(@as(usize, 7), body.counts().faces);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var log: simplify.Log = .{};
    defer log.deinit(testing.allocator);
    try simplify.run(&body, &diag, &log);
    // One merge, of the two halves of the top (faces 1 and 2, built in that order); the
    // face merged away gone in the renumbering, the other six kept in their order
    try testing.expectEqual(@as(usize, 1), log.merged.items.len);
    const merge = log.merged.items[0];
    try testing.expect((merge[0] == 1 and merge[1] == 2) or (merge[0] == 2 and merge[1] == 1));
    try testing.expectEqual(@as(usize, 7), log.faces.len);
    try testing.expectEqual(@import("../topology/body.zig").Body.Remap.NONE, log.faces[merge[0]]);
    try expectValid(&body);
    // A cube: the split's edge and its two vertices gone
    const counts = body.counts();
    try testing.expectEqual(@as(usize, 6), counts.faces);
    try testing.expectEqual(@as(usize, 12), counts.edges);
    try testing.expectEqual(@as(usize, 8), counts.vertices);
}

test "simplify: two faces on one plane of different attributes stay two" {
    var body = try splitTop(1, 2);
    defer body.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try simplify.run(&body, &diag, null);
    try expectValid(&body);
    const counts = body.counts();
    try testing.expectEqual(@as(usize, 7), counts.faces);
    try testing.expectEqual(@as(usize, 10), counts.vertices);
}

test "select: Mäntylä's table, a coincident face kept once, from the first operand" {
    const rows = [_]struct { op: select.Op, operand: u1, class: @import("classify.zig").Class, want: select.Keep }{
        .{ .op = .@"union", .operand = 0, .class = .outside, .want = .keep },
        .{ .op = .@"union", .operand = 0, .class = .inside, .want = .drop },
        .{ .op = .@"union", .operand = 0, .class = .on_same, .want = .keep },
        .{ .op = .@"union", .operand = 0, .class = .on_opposite, .want = .drop },
        .{ .op = .@"union", .operand = 1, .class = .outside, .want = .keep },
        .{ .op = .@"union", .operand = 1, .class = .on_same, .want = .drop },
        .{ .op = .difference, .operand = 0, .class = .outside, .want = .keep },
        .{ .op = .difference, .operand = 0, .class = .on_same, .want = .drop },
        .{ .op = .difference, .operand = 0, .class = .on_opposite, .want = .keep },
        .{ .op = .difference, .operand = 1, .class = .inside, .want = .flip },
        .{ .op = .difference, .operand = 1, .class = .outside, .want = .drop },
        .{ .op = .difference, .operand = 1, .class = .on_opposite, .want = .drop },
        .{ .op = .intersection, .operand = 0, .class = .inside, .want = .keep },
        .{ .op = .intersection, .operand = 0, .class = .on_same, .want = .keep },
        .{ .op = .intersection, .operand = 0, .class = .on_opposite, .want = .drop },
        .{ .op = .intersection, .operand = 1, .class = .inside, .want = .keep },
        .{ .op = .intersection, .operand = 1, .class = .on_same, .want = .drop },
    };
    for (rows) |row| try testing.expectEqual(row.want, select.keep(row.op, row.operand, row.class));
}

test "simplify: an edge shorter than the minimum feature size collapses into its start" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var body = try primitives.box(testing.allocator, tol, 1, 1, 1, false, &diag);
    defer body.deinit();
    // The corner at the origin split: its edge up moved onto a vertex 1.4 zones off, an
    // edge that short between them (what two vertices of an operand merged toward each
    // other leave)
    const corner = for (body.vertices.items, 0..) |_, i| {
        if (vec.length(body.point(types.VertexIndex.of(i))) == 0) break types.VertexIndex.of(i);
    } else unreachable;
    var up: types.CoedgeIndex = .none;
    var around = traverse.Umbrella.init(&body, corner);
    while (try around.next()) |c| {
        if (body.point(body.coedgeEnd(c))[2] == 1) up = c;
    }
    var from_up = traverse.Umbrella.initFrom(&body, up);
    _ = try from_up.next();
    const next_around = (try from_up.next()).?;
    const off: Vec3 = .{ 1e-5, 1e-5, 0 };
    const point = try body.geometry.addPoint(testing.allocator, off);
    const line = try body.geometry.addLine(testing.allocator, curves.Line.through(.{ 0, 0, 0 }, off).?);
    _ = try euler.mevSplitVertex(&body, up, next_around, point, .{ .curve = line, .t0 = 0, .t1 = vec.length(off) });
    var before = try check.run(testing.allocator, &body, .geometric);
    defer before.deinit(testing.allocator);
    try testing.expectEqual(diagnostics.Code.edge_too_short, before.first().?.code);
    try simplify.run(&body, &diag, null);
    try expectValid(&body);
    const counts = body.counts();
    try testing.expectEqual(@as(usize, 6), counts.faces);
    try testing.expectEqual(@as(usize, 12), counts.edges);
    try testing.expectEqual(@as(usize, 8), counts.vertices);
}

test "simplify: an edge the checker finds too short by its chord collapses, though its ends are further apart" {
    // The checker measures an edge by its curve's chord over its range, simplify measured
    // the distance between its vertices: a vertex off its line by 1.05e-5 (within the
    // tolerance) made an edge whose ends are 2.06e-5 apart and whose chord is 1.77e-5, at
    // a minimum of 2e-5. The checker found it too short and simplify left it, so a
    // boolean's result failed its own check. One measure, the checker's
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var body = try primitives.box(testing.allocator, tol, 1, 1, 1, false, &diag);
    defer body.deinit();
    const corner = for (body.vertices.items, 0..) |_, i| {
        if (vec.length(body.point(types.VertexIndex.of(i))) == 0) break types.VertexIndex.of(i);
    } else unreachable;
    var up: types.CoedgeIndex = .none;
    var around = traverse.Umbrella.init(&body, corner);
    while (try around.next()) |c| {
        if (body.point(body.coedgeEnd(c))[2] == 1) up = c;
    }
    var from_up = traverse.Umbrella.initFrom(&body, up);
    _ = try from_up.next();
    const next_around = (try from_up.next()).?;
    // The new vertex 2.06e-5 from the corner, within the tolerance of the box's edges and
    // faces there; the edge to it along (1, 1, 0), its chord 1.77e-5
    const p: Vec3 = .{ 1.25e-5, 1.25e-5, 1.05e-5 };
    const ends_apart = vec.length(p);
    const along = vec.dot(p, vec.normalized(.{ 1, 1, 0 }).?);
    const point = try body.geometry.addPoint(testing.allocator, p);
    const line = try body.geometry.addLine(testing.allocator, curves.Line.through(.{ 0, 0, 0 }, .{ 1, 1, 0 }).?);
    _ = try euler.mevSplitVertex(&body, up, next_around, point, .{ .curve = line, .t0 = 0, .t1 = along });
    // The edge up, moved onto the new vertex: its range from where the vertex projects
    const up_edge = &body.edges.items[@backingInt(body.coedge(up).edge)];
    const up_line = body.geometry.curve(up_edge.curve).line;
    if (up_edge.start == body.coedgeStart(up)) up_edge.t0 = up_line.project(p) else up_edge.t1 = up_line.project(p);
    var before = try check.run(testing.allocator, &body, .geometric);
    defer before.deinit(testing.allocator);
    try testing.expectEqual(diagnostics.Code.edge_too_short, before.first().?.code);
    try testing.expect(ends_apart > 2 * tol.zone and along < 2 * tol.zone);
    try simplify.run(&body, &diag, null);
    try expectValid(&body);
    try testing.expectEqual(@as(usize, 8), body.counts().vertices);
}
