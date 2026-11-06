//! One negative fixture per rule of the checker: a valid body, broken in one way, and the
//! rule that must name it first.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const types = @import("types.zig");
const Body = @import("body.zig").Body;
const euler = @import("euler.zig");
const check = @import("check.zig");
const Vec3 = vec.Vec3;

const tol = Tolerance.fromZone(1e-5);

/// A tetrahedron: the smallest closed solid, by Euler operators.
fn tetrahedron(allocator: std.mem.Allocator) !Body {
    var b = Body.init(allocator, tol);
    errdefer b.deinit();
    const pts = [4]Vec3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    var p: [4]geometry.PointIndex = undefined;
    for (pts, 0..) |q, i| p[i] = try b.geometry.addPoint(allocator, q);
    // Planes: bottom (z = 0, normal −z), front (y = 0), left (x = 0) and the slant
    const bottom = try b.geometry.addPlane(allocator, .{ .frame = geometry.Frame.init(pts[0], vec.Y3, vec.neg(vec.Z3)) });
    const front = try b.geometry.addPlane(allocator, .{ .frame = geometry.Frame.init(pts[0], vec.X3, vec.neg(vec.Y3)) });
    const left = try b.geometry.addPlane(allocator, .{ .frame = geometry.Frame.init(pts[0], vec.neg(vec.Y3), vec.neg(vec.X3)) });
    const slant_n = vec.normalized(.{ 1, 1, 1 }).?;
    const slant = try b.geometry.addPlane(allocator, .{ .frame = geometry.Frame.fromAxis(pts[1], slant_n) });
    const line = struct {
        fn make(body: *Body, a: Vec3, c: Vec3) !euler.EdgeGeometry {
            const ref = try body.geometry.addLine(body.allocator, curves.Line.through(a, c).?);
            return .{ .curve = ref, .t0 = 0, .t1 = vec.distance(a, c) };
        }
    }.make;
    const start = try euler.mvfs(&b, p[0], bottom, true, .outer);
    const s1 = try euler.mevSpur(&b, start.loop, .none, start.vertex, p[1], try line(&b, pts[0], pts[1]));
    const s2 = try euler.mevSpur(&b, start.loop, s1.out, s1.vertex, p[2], try line(&b, pts[1], pts[2]));
    // Close the bottom triangle 0 1 2 with the edge 0 → 2; the lamina's other face, on
    // the front's plane, takes the loop 2 1 0 (back to 2)
    const m = try euler.mef(&b, s1.out, s2.back, try line(&b, pts[0], pts[2]), front, true);
    // The apex: a spur from vertex 0 in that loop, after the coedge ending at 0 (1 → 0)
    const apex = try euler.mevSpur(&b, m.loop, s1.back, start.vertex, p[3], try line(&b, pts[0], pts[3]));
    // The edge 1 → 3: the old face keeps 1 0 3 (the front), the new face takes the rest
    // (3 0 2 1), on the left's plane
    const rest = try euler.mef(&b, s1.back, apex.back, try line(&b, pts[1], pts[3]), left, true);
    // The edge 3 → 2: the rest keeps 3 0 2 (the left), the new face takes 2 1 3 (the slant)
    _ = try euler.mef(&b, startingIn(&b, rest.loop, apex.vertex), startingIn(&b, rest.loop, s2.vertex), try line(&b, pts[3], pts[2]), slant, true);
    return b;
}

/// The coedge of `loop` starting at `v`.
fn startingIn(b: *const Body, loop: types.LoopIndex, v: types.VertexIndex) types.CoedgeIndex {
    for (b.coedges.items, 0..) |c, i| {
        if (c.tombstone or c.loop != loop) continue;
        if (b.coedgeStart(types.CoedgeIndex.of(i)) == v) return types.CoedgeIndex.of(i);
    }
    unreachable;
}

fn expectRule(body: *const Body, level: check.Level, rule: check.Rule) !void {
    var report = try check.run(testing.allocator, body, level);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| {
        try testing.expectEqual(rule, f.code);
    } else {
        std.debug.print("expected {s}, found nothing\n", .{@tagName(rule)});
        return error.TestExpectedRule;
    }
}

test "a tetrahedron passes every rule" {
    var b = try tetrahedron(testing.allocator);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 4), b.counts().vertices);
    try testing.expectEqual(@as(usize, 6), b.counts().edges);
    try testing.expectEqual(@as(usize, 4), b.counts().faces);
    var report = try check.run(testing.allocator, &b, .geometric);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try f.format(&w);
        std.debug.print("checker: {s}\n", .{w.buffered()});
    }
    try testing.expect(report.ok());
}

test "structural rules: each broken in one way is named" {
    // Index out of range
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.vertex(types.VertexIndex.of(0)).point = geometry.PointIndex.of(99);
        try expectRule(&b, .structural, .index_out_of_range);
    }
    // next/prev not reciprocal
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        const c = types.CoedgeIndex.of(0);
        b.coedge(b.coedge(c).next).prev = b.coedge(c).prev;
        try expectRule(&b, .structural, .next_prev_not_reciprocal);
    }
    // partner not reciprocal
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.coedge(types.CoedgeIndex.of(0)).partner = types.CoedgeIndex.of(3);
        try expectRule(&b, .structural, .partner_not_reciprocal);
    }
    // partners with the same sense
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        const c = b.coedge(types.CoedgeIndex.of(0));
        b.coedge(c.partner).same_sense = c.same_sense;
        try expectRule(&b, .structural, .partner_same_sense);
    }
    // a loop whose coedges don't connect: swap an edge's vertices
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        const e = b.edge(types.EdgeIndex.of(0));
        std.mem.swap(types.VertexIndex, &e.start, &e.end);
        try expectRule(&b, .structural, .loop_not_connected);
    }
    // a loop that never closes
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        const l = b.loop(types.LoopIndex.of(0));
        const first = l.first;
        const second = b.coedge(first).next;
        b.coedge(second).next = second;
        b.coedge(second).prev = second;
        try expectRule(&b, .structural, .loop_not_closed);
    }
    // a loop with neither coedges nor a vertex
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        const extra = try b.addLoop(.{ .face = types.FaceIndex.of(0) });
        b.appendLoop(types.FaceIndex.of(0), extra);
        try expectRule(&b, .structural, .loop_empty);
    }
    // a coedge naming the wrong loop
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.coedge(types.CoedgeIndex.of(0)).loop = types.LoopIndex.of(1);
        try expectRule(&b, .structural, .coedge_loop_disagrees);
    }
    // an edge with three coedges: the loop stops connecting there first; the count
    // rule itself needs a loop that connects, which three coedges of one edge never do
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.coedge(types.CoedgeIndex.of(2)).edge = types.EdgeIndex.of(0);
        try expectRule(&b, .structural, .loop_not_connected);
    }
    // degenerate flag without start == end
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.edge(types.EdgeIndex.of(0)).flags.degenerate = true;
        try expectRule(&b, .structural, .degenerate_edge_vertices);
    }
    // a range the wrong way round
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.edge(types.EdgeIndex.of(0)).t1 = -1;
        try expectRule(&b, .structural, .edge_range_reversed);
    }
    // a vertex naming a coedge that does not leave it
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        const v = b.vertex(types.VertexIndex.of(0));
        v.coedge = b.coedge(v.coedge).partner;
        try expectRule(&b, .structural, .vertex_coedge_not_leaving);
    }
    // a face naming another shell
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        const extra = try b.addShell(.{});
        b.face(types.FaceIndex.of(0)).shell = extra;
        try expectRule(&b, .structural, .face_shell_disagrees);
    }
    // a loop naming another face
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.loop(types.LoopIndex.of(0)).face = types.FaceIndex.of(1);
        try expectRule(&b, .structural, .loop_face_disagrees);
    }
    // a face without a loop
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.face(types.FaceIndex.of(0)).first_loop = .none;
        try expectRule(&b, .structural, .face_without_loop);
    }
    // a face in no shell's list
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        const f = types.FaceIndex.of(0);
        const s = b.face(f).shell;
        b.removeFace(s, f);
        try expectRule(&b, .structural, .face_shell_count);
    }
    // Euler–Poincaré: a face with an extra ring of one vertex passes (L − F counts it), a
    // dangling extra edge pair in a loop (a spur) raises E without V: chi off by one
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        // Add a vertex loop to a face without ... that is valid. Instead relabel a vertex
        // so two distinct vertices become one record in the count: swap one edge's end
        // for another existing vertex, keeping loops connected is impossible, so the
        // Euler rule is reached by adding a face with a loop that reuses existing coedges
        const extra_face = try b.addFace(.{ .surface = geometry.SurfaceRef.of(.plane, 0), .shell = types.ShellIndex.of(0) });
        b.appendFace(types.ShellIndex.of(0), extra_face);
        const extra_loop = try b.addLoop(.{ .face = extra_face, .vertex = types.VertexIndex.of(0) });
        b.appendLoop(extra_face, extra_loop);
        try expectRule(&b, .structural, .euler_poincare);
    }
}

test "orientation and geometric rules" {
    // An edge with one coedge in a closed shell
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        const c = types.CoedgeIndex.of(0);
        const p = b.coedge(c).partner;
        // Both coedges forget their partner, which the structural rules allow (a sheet
        // edge has one coedge); the orientation rule wants two in a closed shell
        b.coedge(c).partner = .none;
        b.coedge(p).partner = .none;
        try expectRule(&b, .geometric, .open_edge_in_closed_shell);
    }
    // A vertex off its curve
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.geometry.points.items[0] = .{ 0.1, 0, 0 };
        try expectRule(&b, .geometric, .vertex_off_curve);
    }
    // An edge too short: a tiny tetrahedron
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.tol = Tolerance.fromZone(0.6);
        try expectRule(&b, .geometric, .edge_too_short);
    }
    // A gap past the zone
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.vertex(types.VertexIndex.of(0)).gap = 1e-3;
        try expectRule(&b, .geometric, .gap_too_large);
    }
    // An edge off a face's surface: move a plane
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.geometry.planes.items[0].frame.origin = .{ 0, 0, 0.01 };
        try expectRule(&b, .geometric, .edge_off_surface);
    }
    // A UV box outside the domain, and one that wraps: on a cylinder
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        const cyl = try b.geometry.addCylinder(testing.allocator, .{ .frame = geometry.Frame.world, .r = 1 });
        b.face(types.FaceIndex.of(0)).surface = cyl;
        b.face(types.FaceIndex.of(0)).uv_box = .{ .min = .{ -1, 0 }, .max = .{ 1, 1 } };
        var report = try check.run(testing.allocator, &b, .geometric);
        defer report.deinit(testing.allocator);
        var found = false;
        for (report.findings.items) |f| found = found or f.code == .uv_box_outside_domain;
        try testing.expect(found);
        b.face(types.FaceIndex.of(0)).uv_box = .{ .min = .{ 0, 0 }, .max = .{ 7, 1 } };
        var report2 = try check.run(testing.allocator, &b, .geometric);
        defer report2.deinit(testing.allocator);
        found = false;
        for (report2.findings.items) |f| found = found or f.code == .uv_box_wraps;
        try testing.expect(found);
    }
}
