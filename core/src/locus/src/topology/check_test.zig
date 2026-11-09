//! One negative fixture per rule of the checker: a valid body, broken in one way, and the
//! rule that must name it first.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const types = @import("types.zig");
const Body = @import("body.zig").Body;
const euler = @import("euler.zig");
const check = @import("check.zig");
const traverse_mod = @import("traverse.zig");
const Vec3 = vec.Vec3;

const tol = Tolerance.fromZone(1e-5);

/// A tetrahedron: the smallest closed solid, by Euler operators.
pub fn tetrahedron(allocator: std.mem.Allocator) !Body {
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
    turnOutward(&b);
    return b;
}

/// Every loop run the other way, the senses with them, the vertices' coedges following:
/// the Euler sequences of these tests lay their loops clockwise seen from outside, and
/// the checker wants them counter-clockwise (the face to the left of each coedge).
pub fn turnOutward(b: *Body) void {
    for (b.coedges.items) |*c| {
        if (c.tombstone) continue;
        std.mem.swap(types.CoedgeIndex, &c.next, &c.prev);
        c.same_sense = !c.same_sense;
    }
    for (b.vertices.items) |*v| {
        if (v.tombstone or v.coedge == .none) continue;
        const partner = b.coedge(v.coedge).partner;
        if (partner != .none) v.coedge = partner;
    }
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
    // an edge with three coedges: the moved coedge's partner is on another edge, which
    // the reciprocity rule names first; the count rule itself needs a loop that connects,
    // which three coedges of one edge never do
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.coedge(types.CoedgeIndex.of(2)).edge = types.EdgeIndex.of(0);
        try expectRule(&b, .structural, .partner_not_reciprocal);
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
    // Coordinates too large for the zone: the unit tetrahedron under a zone of 1e-13,
    // below its coordinates' spacing times the guard's margin; and the same body moved
    // a thousand kilometres out, where a zone of 1e-5 is a ten-thousandth of the spacing
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.tol = Tolerance.fromZone(1e-13);
        try expectRule(&b, .geometric, .too_large_for_tolerance);
    }
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        for (b.geometry.points.items) |*p| p[0] += 1e9;
        for (b.geometry.planes.items) |*plane| plane.frame.origin[0] += 1e9;
        for (b.geometry.lines.items) |*line| line.o[0] += 1e9;
        try expectRule(&b, .geometric, .too_large_for_tolerance);
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
    // A face flipped alone: its loop runs the wrong way for its sense
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        b.face(types.FaceIndex.of(0)).same_sense = false;
        try expectRule(&b, .geometric, .loop_winding);
    }
    // The whole shell turned inside out: every loop reversed and every sense flipped,
    // which every local rule allows; the signed volume says so
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        for (b.faces.items) |*f| f.same_sense = !f.same_sense;
        for (b.coedges.items) |*c| {
            std.mem.swap(types.CoedgeIndex, &c.next, &c.prev);
            c.same_sense = !c.same_sense;
        }
        for (b.vertices.items) |*v| v.coedge = b.coedge(v.coedge).partner;
        try expectRule(&b, .geometric, .shell_inside_out);
    }
    // Two vertices at one place
    {
        var b = try tetrahedron(testing.allocator);
        defer b.deinit();
        const p = try b.geometry.addPoint(testing.allocator, .{ 1e-6, 0, 0 });
        _ = try b.addVertex(.{ .point = p });
        try expectRule(&b, .geometric, .vertices_too_close);
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

test "global rules: a hole outside its outer loop; two faces on one plane are a warning, not a failure" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const primitives = @import("../construct/primitives.zig");
    // The even-odd fill makes two faces of two outlines apart (no hole outside an outer
    // loop can be built); a hole moved out afterwards (its points and its lines together,
    // so every local rule still holds) is what level 2 names
    const outer = [_]vec.Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const far = [_]vec.Vec2{ .{ 20, 20 }, .{ 20, 22 }, .{ 22, 22 }, .{ 22, 20 } };
    var apart = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &far }, &diag);
    defer apart.deinit();
    try testing.expectEqual(@as(usize, 2), apart.counts().faces);
    const inner = [_]vec.Vec2{ .{ 2, 2 }, .{ 2, 4 }, .{ 4, 4 }, .{ 4, 2 } };
    var plate = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer plate.deinit();
    var report = try check.run(testing.allocator, &plate, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    try testing.expectEqual(@as(usize, 0), report.warnings());
    var astray = try plate.clone(testing.allocator);
    defer astray.deinit();
    const hole = astray.loop(astray.face(types.FaceIndex.of(0)).first_loop).next_in_face;
    const away = Vec3{ 20, 20, 0 };
    var it = traverse_mod.Coedges.init(&astray, hole);
    while (try it.next()) |c| {
        const start = astray.coedgeStart(c);
        astray.geometry.points.items[@backingInt(astray.vertex(start).point)] = vec.add(astray.point(start), away);
        const line = &astray.geometry.lines.items[astray.edge(astray.coedge(c).edge).curve.index];
        line.o = vec.add(line.o, away);
    }
    try expectRule(&astray, .global, .hole_outside_outer);

    // A pyramid whose base is two coplanar triangles on one plane record
    const pts = [_]Vec3{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 } };
    const tris = [_][3]u32{ .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 4 } };
    var pyramid = try primitives.polyhedron(testing.allocator, tol, &pts, &tris, &diag);
    defer pyramid.deinit();
    var r2 = try check.run(testing.allocator, &pyramid, .global);
    defer r2.deinit(testing.allocator);
    try testing.expect(r2.ok());
    try testing.expectEqual(@as(usize, 1), r2.warnings());
    try testing.expectEqual(check.Rule.redundant_topology, r2.findings.items[0].code);
    // The split cylinder and sphere are not: their shared edges are seams
    var sphere = try primitives.sphere(testing.allocator, tol, 2, &diag);
    defer sphere.deinit();
    var r3 = try check.run(testing.allocator, &sphere, .global);
    defer r3.deinit(testing.allocator);
    try testing.expect(r3.ok());
    try testing.expectEqual(@as(usize, 0), r3.warnings());
}

