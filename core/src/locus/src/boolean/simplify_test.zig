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
const canonical = @import("../geometry/canonical.zig");
const select = @import("select.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);
/// The gap the builder's cover leaves on an edge whose line runs off its faces' planes, and
/// on its ends (`simplify.coverEdge`): what the tests of a later edit carry over.
const COVERED_GAP: f64 = 3e-6;
/// The length of the short edge the tests leave at a box's corner: under the checker's
/// minimum, two zones.
const SHORT_PIECE: f64 = 1e-5;
/// The test of which end a short edge collapses into: the new vertex the corner's edge up
/// moves to, 1.96e-5 from the corner (`SHORT_FAR`, under the minimum), and the foot of that
/// edge's line at the box's bottom (`SHORT_FOOT`): the line off the box's two side planes
/// by 2.8e-5 each, within the tolerance and the edge's gap (`SHORT_LINE_GAP`), off the
/// corner by 3.96e-5 (a gap past the zone to hold it) and off the new vertex by 2.47e-5
/// (a gap within the zone).
const SHORT_FAR: Vec3 = .{ 1.9e-5, 0.5e-5, 0 };
const SHORT_FOOT: Vec3 = .{ 2.8e-5, 2.8e-5, 0 };
const SHORT_LINE_GAP: f64 = 1e-5;

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

/// The edge of `body` between the vertices at `p` and `q`, either way round.
fn edgeBetween(body: *const Body, p: Vec3, q: Vec3) types.EdgeIndex {
    for (body.edges.items, 0..) |e, i| {
        if (e.flags.tombstone) continue;
        const a = body.point(e.start);
        const b = body.point(e.end);
        if ((vec.distance(a, p) == 0 and vec.distance(b, q) == 0) or (vec.distance(a, q) == 0 and vec.distance(b, p) == 0)) return types.EdgeIndex.of(i);
    }
    unreachable;
}

/// The vertex of `body` at `p`.
fn vertexAt(body: *const Body, p: Vec3) types.VertexIndex {
    for (body.vertices.items, 0..) |v, i| {
        if (!v.tombstone and vec.distance(body.point(types.VertexIndex.of(i)), p) == 0) return types.VertexIndex.of(i);
    }
    unreachable;
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

test "simplify: a short edge collapses into the end nearer the line moved to it, and the result holds its lines" {
    // The 10K session on 6007ab01 (2026-11-18): an edge the minimum feature size long
    // collapsed into a box's corner, and an edge moved there ended 2.0138e-5 off its line,
    // past the tolerance of 2e-5, with no gap; the checker refused the result
    // (`vertex_off_curve`). A box's corner split off by an edge 1.41e-5 long, the edge up
    // moved to the new vertex on a line of its own, 7.1e-6 from that vertex and 2.12e-5
    // from the corner (within the tolerance of both faces about it). Collapsed into the
    // corner, the edge up starts there and the corner's gap must hold it, as the builder
    // gives a vertex it puts on an edge (`simplify.coverLine`); the collapse keeps the end
    // nearer the lines moved to it (`cheaperEnd`, the audit of 2026-11-22), here the new
    // vertex, 1e-5 from the corner's two edges' lines and holding them with no gap
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
    const q: Vec3 = .{ 1e-5, 1e-5, 0 };
    const point = try body.geometry.addPoint(testing.allocator, q);
    const short = try body.geometry.addLine(testing.allocator, curves.Line.through(.{ 0, 0, 0 }, q).?);
    _ = try euler.mevSplitVertex(&body, up, next_around, point, .{ .curve = short, .t0 = 0, .t1 = vec.length(q) });
    // The edge up on its own line, from 1.5e-5 along x and y at the bottom to the top corner
    const foot: Vec3 = .{ 1.5e-5, 1.5e-5, 0 };
    const top: Vec3 = .{ 0, 0, 1 };
    const from_q = body.edges.items[@backingInt(body.coedge(up).edge)].start == body.coedgeStart(up);
    const line = if (from_q) curves.Line.through(foot, top).? else curves.Line.through(top, foot).?;
    const curve = try body.geometry.addLine(testing.allocator, line);
    const up_edge = &body.edges.items[@backingInt(body.coedge(up).edge)];
    up_edge.curve = curve;
    up_edge.t0 = line.project(if (from_q) q else top);
    up_edge.t1 = line.project(if (from_q) top else q);
    try testing.expect(canonical.lineOffset(line, q) < tol.xsect and canonical.lineOffset(line, .{ 0, 0, 0 }) > tol.xsect);
    var before = try check.run(testing.allocator, &body, .geometric);
    defer before.deinit(testing.allocator);
    try testing.expectEqual(diagnostics.Code.edge_too_short, before.first().?.code);
    try simplify.run(&body, &diag, null);
    try expectValid(&body);
    try testing.expectEqual(@as(usize, 8), body.counts().vertices);
    // The new vertex kept, the corner gone (by their points: simplify renumbers)
    var at_q = false;
    for (body.vertices.items, 0..) |v, i| {
        if (v.tombstone) continue;
        const p = body.point(types.VertexIndex.of(i));
        try testing.expect(vec.length(p) != 0);
        at_q = at_q or vec.distance(p, q) == 0;
    }
    try testing.expect(at_q);
}

test "simplify: two faces on planes the same within the tolerance, of two records, stay two" {
    // One record is one plane as the paves decided it (D28: a face's fragments share its
    // record, and the faces the paves found in one plane share their group's), and
    // simplify decides nothing again by geometry. It merged faces of two records on planes
    // the same within the tolerance, and so made one face of two faces of one operand
    // where a cut left little of them (the locus session on 5c1e164e, br). The top's right
    // half given its own record 1e-9 above the left's: two faces, the edge between them
    // and its vertices kept
    var body = try splitTop(0, 0);
    defer body.deinit();
    var tops: [2]types.FaceIndex = undefined;
    var n: usize = 0;
    for (body.faces.items, 0..) |face, i| {
        if (face.surface.kind != .plane) continue;
        const plane = body.geometry.planes.items[face.surface.index];
        if (@abs(plane.frame.z[2]) == 1 and plane.frame.origin[2] == 1) {
            tops[n] = types.FaceIndex.of(i);
            n += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), n);
    var lifted = body.geometry.planes.items[body.face(tops[1]).surface.index];
    lifted.frame.origin[2] += 1e-9;
    try body.geometry.planes.append(testing.allocator, lifted);
    body.face(tops[1]).surface.index = @intCast(body.geometry.planes.items.len - 1);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try simplify.run(&body, &diag, null);
    try expectValid(&body);
    const counts = body.counts();
    try testing.expectEqual(@as(usize, 7), counts.faces);
    try testing.expectEqual(@as(usize, 10), counts.vertices);
}

test "simplify: coverLine's gap holds a vertex to the line as the checker measures it, the line at the vertex's projection" {
    // The 10K session on 6007ab01 (2026-11-18): a vertex an edge was moved to, 2.0138e-5
    // off the edge's line at a tolerance of 2e-5. The checker measures from the line at the
    // vertex's projection, which differs from `canonical.lineOffset` by a rounding at the
    // coordinates' size, and a gap of the offset's excess alone fell 9e-17 short of it.
    // Vertices just past the tolerance off that line, all round it and along it
    var body = Body.init(testing.allocator, tol);
    defer body.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const line: curves.Line = .{ .o = .{ 1.000005, 3, -0.000005 }, .d = .{ 2.0 / 3.0, 1.0 / 3.0, 2.0 / 3.0 } };
    const across = vec.normalized(vec.cross(line.d, .{ 0, 0, 1 })).?;
    const up = vec.cross(line.d, across);
    for (0..400) |i| {
        const k: f64 = @floatFromInt(i);
        const round = vec.add(vec.scale(across, @cos(k * 0.37)), vec.scale(up, @sin(k * 0.37)));
        const p = vec.addScaled(line.eval(0.5 + k * 0.01), round, tol.xsect * (1 + k * 1e-4));
        const v = try body.addVertex(.{ .point = try body.geometry.addPoint(testing.allocator, p) });
        try simplify.coverLine(&body, v, line, .of(.vertex, @backingInt(v)), "the test's vertex", &diag);
        // As `vertex_off_curve` measures and sums it, for an edge with no gap
        try testing.expect(vec.distance(line.eval(line.project(p)), p) <= tol.xsect + 0 + body.vertex(v).gap);
    }
}

test "simplify: a run joined into one edge gives the run's ends the joined edge's gap" {
    // The audit of 2026-11-22: `joinRun` gave the joined edge the largest of its pieces'
    // gaps, and the run's ends kept their own. Along a line whose height over a face grows
    // past the intersection tolerance, the builder's cover gives the far piece and its ends
    // a gap and the near piece none; joined, the edge's gap passed its near end's, and the
    // checker refused the boolean's own result (`gap_order`). A box's bottom edge split at
    // its middle, as the cover leaves such a line: the far half and both its ends covered,
    // the near half and its start not
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var body = try primitives.box(testing.allocator, tol, 1, 1, 1, false, &diag);
    defer body.deinit();
    const near: Vec3 = .{ 0, 0, 0 };
    const far: Vec3 = .{ 1, 0, 0 };
    const e = edgeBetween(&body, near, far);
    const line = body.geometry.curve(body.edge(e).curve).line;
    const t = (body.edge(e).t0 + body.edge(e).t1) / 2;
    const middle = try body.geometry.addPoint(testing.allocator, line.eval(t));
    const split = try euler.mevSplitEdge(&body, body.edge(e).coedge, t, middle);
    const far_piece = if (body.edge(split.edge).end == vertexAt(&body, far) or body.edge(split.edge).start == vertexAt(&body, far)) split.edge else e;
    body.edge(far_piece).gap = COVERED_GAP;
    body.vertex(split.vertex).gap = COVERED_GAP;
    body.vertex(vertexAt(&body, far)).gap = COVERED_GAP;
    try expectValid(&body);
    try simplify.run(&body, &diag, null);
    try expectValid(&body);
    try testing.expectEqual(@as(usize, 8), body.counts().vertices);
    try testing.expect(body.vertex(vertexAt(&body, near)).gap >= COVERED_GAP);
}

test "simplify: a short edge collapsed gives the vertex kept the gaps of the edges moved to it" {
    // The audit of 2026-11-22: `kevMerge` moves the edges of the vertex gone to the vertex
    // kept and leaves their gaps; the collapse grew the kept vertex's gap only to its
    // offsets from their lines (`coverLine`), and an edge moved over with a gap larger
    // than the kept vertex's left the result refused (`gap_order`). A box's corner split
    // off by an edge `SHORT_PIECE` long, the edge up moved to the new vertex (the collapse
    // keeps the corner, the short edge's start), the cover's gap on the edge moved, on the
    // edges staying, or on both
    const Covered = enum { moved, staying, both };
    for ([_]Covered{ .moved, .staying, .both }) |covered| {
        errdefer std.debug.print("the gap on the edges {s}\n", .{@tagName(covered)});
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var body = try primitives.box(testing.allocator, tol, 1, 1, 1, false, &diag);
        defer body.deinit();
        const origin: Vec3 = .{ 0, 0, 0 };
        const corner = vertexAt(&body, origin);
        if (covered != .moved) {
            for ([_]Vec3{ .{ 1, 0, 0 }, .{ 0, 1, 0 } }) |q| {
                body.edge(edgeBetween(&body, origin, q)).gap = COVERED_GAP;
                body.vertex(vertexAt(&body, q)).gap = COVERED_GAP;
            }
            body.vertex(corner).gap = COVERED_GAP;
        }
        var up: types.CoedgeIndex = .none;
        var around = traverse.Umbrella.init(&body, corner);
        while (try around.next()) |c| {
            if (body.point(body.coedgeEnd(c))[2] == 1) up = c;
        }
        var from_up = traverse.Umbrella.initFrom(&body, up);
        _ = try from_up.next();
        const next_around = (try from_up.next()).?;
        const q = vec.scale(vec.normalized(.{ 1, 1, 0 }).?, SHORT_PIECE);
        const point = try body.geometry.addPoint(testing.allocator, q);
        const short = try body.geometry.addLine(testing.allocator, curves.Line.through(origin, q).?);
        const made = try euler.mevSplitVertex(&body, up, next_around, point, .{ .curve = short, .t0 = 0, .t1 = SHORT_PIECE });
        if (covered != .staying) {
            body.edge(body.coedge(up).edge).gap = COVERED_GAP;
            body.vertex(made.vertex).gap = COVERED_GAP;
            body.vertex(vertexAt(&body, .{ 0, 0, 1 })).gap = COVERED_GAP;
        }
        var before = try check.run(testing.allocator, &body, .geometric);
        defer before.deinit(testing.allocator);
        try testing.expectEqual(diagnostics.Code.edge_too_short, before.first().?.code);
        try simplify.run(&body, &diag, null);
        try expectValid(&body);
        try testing.expectEqual(@as(usize, 8), body.counts().vertices);
        // The corner kept (the end nearer the line moved to it, which runs through it),
        // with the gap of the edge moved to it
        try testing.expect(body.vertex(vertexAt(&body, origin)).gap >= COVERED_GAP);
    }
}

/// Edge `e` run the other way: its ends swapped, its line through them the other way, its
/// coedges' senses turned, so each still leaves the vertex it left, and the edge's own
/// coedge the one leaving its new start.
fn reverseEdge(body: *Body, e: types.EdgeIndex) !void {
    const edge = body.edge(e);
    const from = body.point(edge.end);
    const to = body.point(edge.start);
    const line = curves.Line.through(from, to).?;
    const curve = try body.geometry.addLine(testing.allocator, line);
    std.mem.swap(types.VertexIndex, &edge.start, &edge.end);
    edge.curve = curve;
    edge.t0 = line.project(from);
    edge.t1 = line.project(to);
    for (traverse.coedgesOfEdge(body, e)) |c| {
        if (c != .none) body.coedge(c).same_sense = !body.coedge(c).same_sense;
    }
    // The edge's own coedge its partner: the one leaving its new start, as a builder
    // making the edge from that end would record it
    edge.coedge = body.coedge(edge.coedge).partner;
}

test "simplify: a short edge collapses into the same end whichever way it runs" {
    // The audit of 2026-11-22: a short edge collapsed into its start, and which end is its
    // start goes by its source edge's direction (or a section line's sign), which follows
    // the operands' order and placement. The gap the kept vertex needs to hold the lines
    // moved to it, and with it made against refused (`gap_too_large`), goes by the end
    // kept. A box's corner split off by an edge to a vertex 1.96e-5 from it, the edge up
    // moved to that vertex on a line whose foot is off the corner by 3.96e-5: kept, the
    // corner needs a gap past the zone to hold that line, the new vertex none for the
    // corner's two edges. The short edge run each way, the same result either way
    var results: [2]struct { refused: bool, vertices: usize, kept: ?Vec3 } = undefined;
    for ([_]bool{ false, true }) |reversed| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var body = try primitives.box(testing.allocator, tol, 1, 1, 1, false, &diag);
        defer body.deinit();
        const origin: Vec3 = .{ 0, 0, 0 };
        const top: Vec3 = .{ 0, 0, 1 };
        const corner = vertexAt(&body, origin);
        var up: types.CoedgeIndex = .none;
        var around = traverse.Umbrella.init(&body, corner);
        while (try around.next()) |c| {
            if (body.point(body.coedgeEnd(c))[2] == 1) up = c;
        }
        var from_up = traverse.Umbrella.initFrom(&body, up);
        _ = try from_up.next();
        const next_around = (try from_up.next()).?;
        const point = try body.geometry.addPoint(testing.allocator, SHORT_FAR);
        const short = try body.geometry.addLine(testing.allocator, curves.Line.through(origin, SHORT_FAR).?);
        const made = try euler.mevSplitVertex(&body, up, next_around, point, .{ .curve = short, .t0 = 0, .t1 = vec.length(SHORT_FAR) });
        // The edge up on the line from its foot to the top corner, with the gap that holds
        // it to the box's sides, and its ends' gaps the same
        const up_edge = body.coedge(up).edge;
        const from_far = body.edge(up_edge).start == made.vertex;
        const line = if (from_far) curves.Line.through(SHORT_FOOT, top).? else curves.Line.through(top, SHORT_FOOT).?;
        body.edge(up_edge).curve = try body.geometry.addLine(testing.allocator, line);
        body.edge(up_edge).t0 = line.project(if (from_far) SHORT_FAR else top);
        body.edge(up_edge).t1 = line.project(if (from_far) top else SHORT_FAR);
        body.edge(up_edge).gap = SHORT_LINE_GAP;
        body.vertex(made.vertex).gap = SHORT_LINE_GAP;
        body.vertex(vertexAt(&body, top)).gap = SHORT_LINE_GAP;
        if (reversed) try reverseEdge(&body, made.edge);
        var before = try check.run(testing.allocator, &body, .geometric);
        defer before.deinit(testing.allocator);
        try testing.expectEqual(diagnostics.Code.edge_too_short, before.first().?.code);
        const i: usize = @intFromBool(reversed);
        simplify.run(&body, &diag, null) catch |err| {
            try testing.expectEqual(error.Degenerate, err);
            results[i] = .{ .refused = true, .vertices = 0, .kept = null };
            continue;
        };
        try expectValid(&body);
        const kept: ?Vec3 = for (body.vertices.items, 0..) |v, k| {
            const p = body.point(types.VertexIndex.of(k));
            if (!v.tombstone and p[2] == 0 and vec.length(p) < 1e-3) break p;
        } else null;
        results[i] = .{ .refused = false, .vertices = body.counts().vertices, .kept = kept };
    }
    errdefer std.debug.print("start kept: {any}\nend kept: {any}\n", .{ results[0], results[1] });
    try testing.expectEqual(results[0].refused, results[1].refused);
    try testing.expectEqual(results[0].vertices, results[1].vertices);
    try testing.expectEqual(results[0].kept, results[1].kept);
}
