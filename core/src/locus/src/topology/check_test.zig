//! One negative fixture per rule of the checker: a valid body, broken in one way, and the
//! rule that must name it first.

const std = @import("std");
const builtin = @import("builtin");
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
const body_json = @import("../io/body_json.zig");
const malformed = @import("../fixtures/malformed.zig");
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

/// A body broken in one way, the rule that must name it, and its place in the malformed
/// corpus (fixtures/malformed.zig): the defects this file builds in code, each also a file
/// a reader takes in (M4's exit; research/opengeometry.md §6, OpenGeometry's verdicts).
const Malformed = struct {
    name: []const u8,
    /// The defect in words, the verdict file's `what`.
    what: []const u8,
    base: Base = .tetrahedron,
    /// The break, in code; null for a defect only a file can carry (`edit`).
    breaks: ?*const fn (*Body) anyerror!void = null,
    /// An edit of the body's JSON text: the defect only a file can carry.
    edit: ?[2][]const u8 = null,
    level: check.Level = .structural,
    /// The checker's first finding on the body broken in code; null for an `edit` case.
    rule: ?check.Rule = null,
    /// The reader refuses the file (`body_json.Error.Malformed`), the verdict instead of a
    /// finding: an index past its table, a version or a kind it does not know.
    refused: bool = false,
};

const Base = enum { tetrahedron, plate };

fn baseBody(base: Base) !Body {
    return switch (base) {
        .tetrahedron => tetrahedron(testing.allocator),
        .plate => plate(),
    };
}

/// A 10 × 10 plate with a 2 × 2 hole, by the even-odd fill.
fn plate() !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const outer = [_]vec.Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner = [_]vec.Vec2{ .{ 2, 2 }, .{ 2, 4 }, .{ 4, 4 }, .{ 4, 2 } };
    return @import("../construct/primitives.zig").polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
}

const MALFORMED = [_]Malformed{
    // What the reader refuses
    .{ .name = "point_index_past_table", .what = "a vertex naming point 99 of a table of four", .breaks = pointPastTable, .rule = .index_out_of_range, .refused = true },
    .{ .name = "version_unknown", .what = "a body in a format version the reader does not know", .edit = .{ "\"version\": 1", "\"version\": 99" }, .refused = true },
    .{ .name = "curve_kind_unknown", .what = "an edge on a curve of a kind no table holds", .edit = .{ "\"kind\": \"line\"", "\"kind\": \"helix\"" }, .refused = true },
    .{ .name = "point_not_finite", .what = "a vertex's point not a number", .breaks = pointNotFinite, .level = .geometric, .rule = .not_finite, .refused = true },
    // Structural
    .{ .name = "next_prev_not_reciprocal", .what = "a coedge whose next's prev is another", .breaks = nextPrevNotReciprocal, .rule = .next_prev_not_reciprocal },
    .{ .name = "partner_not_reciprocal", .what = "a coedge whose partner is not its own", .breaks = partnerNotReciprocal, .rule = .partner_not_reciprocal },
    .{ .name = "partner_same_sense", .what = "partners running their edge the same way", .breaks = partnerSameSense, .rule = .partner_same_sense },
    .{ .name = "loop_not_connected", .what = "an edge's vertices swapped: its loops do not connect", .breaks = loopNotConnected, .rule = .loop_not_connected },
    .{ .name = "loop_not_closed", .what = "a loop whose second coedge is its own next and prev", .breaks = loopNotClosed, .rule = .loop_not_closed },
    .{ .name = "loop_empty", .what = "a loop with neither coedges nor a vertex", .breaks = loopEmpty, .rule = .loop_empty },
    .{ .name = "coedge_loop_disagrees", .what = "a coedge naming another loop than the one it runs in", .breaks = coedgeLoopDisagrees, .rule = .coedge_loop_disagrees },
    .{ .name = "edge_three_coedges", .what = "an edge a third coedge names (its partner then on another edge)", .breaks = edgeThreeCoedges, .rule = .partner_not_reciprocal },
    .{ .name = "degenerate_edge_vertices", .what = "an edge flagged degenerate between two vertices", .breaks = degenerateEdgeVertices, .rule = .degenerate_edge_vertices },
    .{ .name = "edge_range_reversed", .what = "an edge's range the wrong way round", .breaks = edgeRangeReversed, .rule = .edge_range_reversed },
    .{ .name = "vertex_coedge_not_leaving", .what = "a vertex naming a coedge that arrives at it", .breaks = vertexCoedgeNotLeaving, .rule = .vertex_coedge_not_leaving },
    .{ .name = "face_shell_disagrees", .what = "a face naming a shell whose list it is not in", .breaks = faceShellDisagrees, .rule = .face_shell_disagrees },
    .{ .name = "loop_face_disagrees", .what = "a loop naming another face than the one it bounds", .breaks = loopFaceDisagrees, .rule = .loop_face_disagrees },
    .{ .name = "face_without_loop", .what = "a face with no loop", .breaks = faceWithoutLoop, .rule = .face_without_loop },
    .{ .name = "face_shell_count", .what = "a face in no shell's list", .breaks = faceShellCount, .rule = .face_shell_count },
    .{ .name = "euler_poincare", .what = "an extra face of one vertex loop: V − E + F − (L − F) − 2(S − G) off", .breaks = eulerPoincare, .rule = .euler_poincare },
    // Orientation and geometric
    .{ .name = "open_edge_in_closed_shell", .what = "an edge with one coedge in a closed shell", .breaks = openEdgeInClosedShell, .level = .geometric, .rule = .open_edge_in_closed_shell },
    .{ .name = "vertex_off_curve", .what = "a vertex moved a tenth off its edges' lines", .breaks = vertexOffCurve, .level = .geometric, .rule = .vertex_off_curve },
    .{ .name = "edge_too_short", .what = "a unit tetrahedron under a zone of 0.6: its edges shorter than twice it", .breaks = edgeTooShort, .level = .geometric, .rule = .edge_too_short },
    .{ .name = "too_large_for_zone", .what = "a unit tetrahedron under a zone of 1e-13, below its coordinates' spacing", .breaks = tooLargeForZone, .level = .geometric, .rule = .too_large_for_tolerance },
    .{ .name = "too_large_far_out", .what = "the tetrahedron moved a thousand kilometres out at a zone of 1e-5", .breaks = tooLargeFarOut, .level = .geometric, .rule = .too_large_for_tolerance },
    .{ .name = "gap_too_large", .what = "a vertex's gap a hundred times the zone", .breaks = gapTooLarge, .level = .geometric, .rule = .gap_too_large },
    .{ .name = "edge_off_surface", .what = "a face's plane moved a hundredth off its edges", .breaks = edgeOffSurface, .level = .geometric, .rule = .edge_off_surface },
    .{ .name = "loop_winding", .what = "a face flipped alone: its loop runs the wrong way for its sense", .breaks = loopWinding, .level = .geometric, .rule = .loop_winding },
    .{ .name = "shell_inside_out", .what = "the whole shell turned inside out: every local rule holds, its volume is negative", .breaks = shellInsideOut, .level = .geometric, .rule = .shell_inside_out },
    .{ .name = "vertices_too_close", .what = "a second vertex 1e-6 from the first", .breaks = verticesTooClose, .level = .geometric, .rule = .vertices_too_close },
    // Global
    .{ .name = "hole_outside_outer", .what = "a plate's hole moved out of its outer loop, its points and lines together", .base = .plate, .breaks = holeOutsideOuter, .level = .global, .rule = .hole_outside_outer },
};

fn pointPastTable(b: *Body) !void {
    b.vertex(types.VertexIndex.of(0)).point = geometry.PointIndex.of(99);
}

fn pointNotFinite(b: *Body) !void {
    // A NaN passed every rule written `measured > limit` and the reader took it (the
    // research review, 2026-11-14): the reader refuses it, the checker names it
    b.geometry.points.items[@backingInt(b.vertex(types.VertexIndex.of(0)).point)][0] = std.math.nan(f64);
}

fn nextPrevNotReciprocal(b: *Body) !void {
    const c = types.CoedgeIndex.of(0);
    b.coedge(b.coedge(c).next).prev = b.coedge(c).prev;
}

fn partnerNotReciprocal(b: *Body) !void {
    b.coedge(types.CoedgeIndex.of(0)).partner = types.CoedgeIndex.of(3);
}

fn partnerSameSense(b: *Body) !void {
    const c = b.coedge(types.CoedgeIndex.of(0));
    b.coedge(c.partner).same_sense = c.same_sense;
}

fn loopNotConnected(b: *Body) !void {
    const e = b.edge(types.EdgeIndex.of(0));
    std.mem.swap(types.VertexIndex, &e.start, &e.end);
}

fn loopNotClosed(b: *Body) !void {
    const second = b.coedge(b.loop(types.LoopIndex.of(0)).first).next;
    b.coedge(second).next = second;
    b.coedge(second).prev = second;
}

fn loopEmpty(b: *Body) !void {
    const extra = try b.addLoop(.{ .face = types.FaceIndex.of(0) });
    b.appendLoop(types.FaceIndex.of(0), extra);
}

fn coedgeLoopDisagrees(b: *Body) !void {
    b.coedge(types.CoedgeIndex.of(0)).loop = types.LoopIndex.of(1);
}

fn edgeThreeCoedges(b: *Body) !void {
    // The count rule itself needs a loop that connects, which three coedges of one edge
    // never do: the moved coedge's partner on another edge is named first
    b.coedge(types.CoedgeIndex.of(2)).edge = types.EdgeIndex.of(0);
}

fn degenerateEdgeVertices(b: *Body) !void {
    b.edge(types.EdgeIndex.of(0)).flags.degenerate = true;
}

fn edgeRangeReversed(b: *Body) !void {
    b.edge(types.EdgeIndex.of(0)).t1 = -1;
}

fn vertexCoedgeNotLeaving(b: *Body) !void {
    const v = b.vertex(types.VertexIndex.of(0));
    v.coedge = b.coedge(v.coedge).partner;
}

fn faceShellDisagrees(b: *Body) !void {
    const extra = try b.addShell(.{});
    b.face(types.FaceIndex.of(0)).shell = extra;
}

fn loopFaceDisagrees(b: *Body) !void {
    b.loop(types.LoopIndex.of(0)).face = types.FaceIndex.of(1);
}

fn faceWithoutLoop(b: *Body) !void {
    b.face(types.FaceIndex.of(0)).first_loop = .none;
}

fn faceShellCount(b: *Body) !void {
    const f = types.FaceIndex.of(0);
    b.removeFace(b.face(f).shell, f);
}

fn eulerPoincare(b: *Body) !void {
    // A face of one vertex loop on an existing vertex: every reference holds, the count
    // does not
    const extra_face = try b.addFace(.{ .surface = geometry.SurfaceRef.of(.plane, 0), .shell = types.ShellIndex.of(0) });
    b.appendFace(types.ShellIndex.of(0), extra_face);
    const extra_loop = try b.addLoop(.{ .face = extra_face, .vertex = types.VertexIndex.of(0) });
    b.appendLoop(extra_face, extra_loop);
}

fn openEdgeInClosedShell(b: *Body) !void {
    // Both coedges forget their partner, which the structural rules allow (a sheet edge
    // has one coedge); the orientation rule wants two in a closed shell
    const c = types.CoedgeIndex.of(0);
    const p = b.coedge(c).partner;
    b.coedge(c).partner = .none;
    b.coedge(p).partner = .none;
}

fn vertexOffCurve(b: *Body) !void {
    b.geometry.points.items[0] = .{ 0.1, 0, 0 };
}

fn edgeTooShort(b: *Body) !void {
    b.tol = Tolerance.fromZone(0.6);
}

fn tooLargeForZone(b: *Body) !void {
    b.tol = Tolerance.fromZone(1e-13);
}

fn tooLargeFarOut(b: *Body) !void {
    for (b.geometry.points.items) |*p| p[0] += 1e9;
    for (b.geometry.planes.items) |*pl| pl.frame.origin[0] += 1e9;
    for (b.geometry.lines.items) |*line| line.o[0] += 1e9;
}

fn gapTooLarge(b: *Body) !void {
    b.vertex(types.VertexIndex.of(0)).gap = 1e-3;
}

fn edgeOffSurface(b: *Body) !void {
    b.geometry.planes.items[0].frame.origin = .{ 0, 0, 0.01 };
}

fn loopWinding(b: *Body) !void {
    b.face(types.FaceIndex.of(0)).same_sense = false;
}

fn shellInsideOut(b: *Body) !void {
    for (b.faces.items) |*f| f.same_sense = !f.same_sense;
    for (b.coedges.items) |*c| {
        std.mem.swap(types.CoedgeIndex, &c.next, &c.prev);
        c.same_sense = !c.same_sense;
    }
    for (b.vertices.items) |*v| v.coedge = b.coedge(v.coedge).partner;
}

fn verticesTooClose(b: *Body) !void {
    const p = try b.geometry.addPoint(b.allocator, .{ 1e-6, 0, 0 });
    _ = try b.addVertex(.{ .point = p });
}

fn holeOutsideOuter(b: *Body) !void {
    // The even-odd fill makes two faces of two outlines apart (no hole outside an outer
    // loop can be built); a hole moved out afterwards, its points and lines together, so
    // every local rule still holds, is what level 2 names
    const hole = b.loop(b.face(types.FaceIndex.of(0)).first_loop).next_in_face;
    const away = Vec3{ 20, 20, 0 };
    var it = traverse_mod.Coedges.init(b, hole);
    while (try it.next()) |c| {
        const start = b.coedgeStart(c);
        b.geometry.points.items[@backingInt(b.vertex(start).point)] = vec.add(b.point(start), away);
        const line = &b.geometry.lines.items[b.edge(b.coedge(c).edge).curve.index];
        line.o = vec.add(line.o, away);
    }
}

/// The case's body broken in code.
fn brokenBody(case: Malformed) !Body {
    var b = try baseBody(case.base);
    errdefer b.deinit();
    if (case.breaks) |breaks| try breaks(&b);
    return b;
}

/// The case's file: the broken body as JSON, edited when the case says.
fn caseText(case: Malformed) ![]u8 {
    var b = try brokenBody(case);
    defer b.deinit();
    const text = try body_json.dump(testing.allocator, &b);
    const edit = case.edit orelse return text;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, edit[0]) != null);
    return std.mem.replaceOwned(u8, testing.allocator, text, edit[0], edit[1]);
}

/// The case's verdict file.
fn verdictText(case: Malformed) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const w = &out.writer;
    if (case.refused) {
        try w.print("{f}", .{std.json.fmt(.{ .what = case.what, .reader = "refuses" }, .{ .whitespace = .indent_2 })});
    } else {
        try w.print("{f}", .{std.json.fmt(.{ .what = case.what, .level = @tagName(case.level), .first = @tagName(case.rule.?) }, .{ .whitespace = .indent_2 })});
    }
    try w.writeByte('\n');
    return out.toOwnedSlice();
}

/// A verdict file, read.
const Verdict = struct { what: []const u8, reader: ?[]const u8 = null, level: ?[]const u8 = null, first: ?[]const u8 = null };

test "checker: each malformed case, broken in code, is named first by its rule" {
    for (MALFORMED) |case| {
        const rule = case.rule orelse continue;
        errdefer std.debug.print("case {s}: {s}\n", .{ case.name, case.what });
        var b = try brokenBody(case);
        defer b.deinit();
        try expectRule(&b, case.level, rule);
    }
}

test "checker: UV boxes outside a cylinder's domain, and one that wraps" {
    var b = try tetrahedron(testing.allocator);
    defer b.deinit();
    // A UV box outside the domain, and one that wraps: on a cylinder
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

test "malformed corpus: each file is its case's body and verdict, as the table makes them" {
    const update = @import("test_paths").update_snapshots;
    if (update and builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    try testing.expectEqual(MALFORMED.len, malformed.NAMES.len);
    for (MALFORMED, malformed.CASES) |case, file| {
        errdefer std.debug.print("case {s}: rerun with -Dupdate-snapshots and review the diff\n", .{case.name});
        try testing.expectEqualStrings(case.name, file.name);
        const text = try caseText(case);
        defer testing.allocator.free(text);
        const verdict = try verdictText(case);
        defer testing.allocator.free(verdict);
        if (update) {
            for ([_][]const u8{ ".json", ".verdict.json" }, [_][]const u8{ text, verdict }) |ext, data| {
                const path = try std.mem.concat(testing.allocator, u8, &.{ @import("test_paths").locus_dir, "/src/fixtures/malformed/", case.name, ext });
                defer testing.allocator.free(path);
                var out = try std.Io.Dir.cwd().createFile(testing.io, path, .{});
                defer out.close(testing.io);
                try out.writeStreamingAll(testing.io, data);
            }
            continue;
        }
        try testing.expectEqualStrings(file.body, text);
        try testing.expectEqualStrings(file.verdict, verdict);
    }
}

test "malformed corpus: each file, read, is refused or named first as its verdict says" {
    // The data alone: the file read as a host's would be, and its verdict file's word
    for (malformed.CASES) |file| {
        errdefer std.debug.print("case {s}\n", .{file.name});
        const parsed = try std.json.parseFromSlice(Verdict, testing.allocator, file.verdict, .{});
        defer parsed.deinit();
        const verdict = parsed.value;
        try testing.expect(verdict.what.len > 0);
        if (verdict.reader) |reader| {
            try testing.expectEqualStrings("refuses", reader);
            try testing.expectError(error.Malformed, body_json.load(testing.allocator, file.body));
            continue;
        }
        var body = try body_json.load(testing.allocator, file.body);
        defer body.deinit();
        const level = std.meta.stringToEnum(check.Level, verdict.level.?) orelse return error.TestUnexpectedResult;
        const rule = std.meta.stringToEnum(check.Rule, verdict.first.?) orelse return error.TestUnexpectedResult;
        try expectRule(&body, level, rule);
    }
}

test "global rules: two faces on one plane are a warning, not a failure" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const primitives = @import("../construct/primitives.zig");
    // A plate with a hole passes, no warning (the hole moved out of it is the malformed
    // corpus's `hole_outside_outer`)
    const outer = [_]vec.Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner = [_]vec.Vec2{ .{ 2, 2 }, .{ 2, 4 }, .{ 4, 4 }, .{ 4, 2 } };
    var holed = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer holed.deinit();
    var report = try check.run(testing.allocator, &holed, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    try testing.expectEqual(@as(usize, 0), report.warnings());

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

test "global rules: the pcurves of every curved primitive and of a rounded extrusion lie in their boxes and join; a box too small and a pcurve astray are named" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const primitives = @import("../construct/primitives.zig");
    const sweep = @import("../construct/sweep.zig");
    var cylinder = try primitives.cylinder(testing.allocator, tol, 3, 5, false, &diag);
    defer cylinder.deinit();
    var cone = try primitives.cone(testing.allocator, tol, 3, 1, 5, false, &diag);
    defer cone.deinit();
    var sphere = try primitives.sphere(testing.allocator, tol, 3, &diag);
    defer sphere.deinit();
    var torus = try primitives.torus(testing.allocator, tol, 5, 1, &diag);
    defer torus.deinit();
    const Arc = primitives.OutlineArc;
    const stadium = [_]primitives.OutlineEdge{
        .{ .a = .{ -2, -1 }, .b = .{ 2, -1 } },
        .{ .a = .{ 2, -1 }, .b = .{ 2, 1 }, .arc = Arc{ .c = .{ 2, 0 }, .r = 1, .ccw = true } },
        .{ .a = .{ 2, 1 }, .b = .{ -2, 1 } },
        .{ .a = .{ -2, 1 }, .b = .{ -2, -1 }, .arc = Arc{ .c = .{ -2, 0 }, .r = 1, .ccw = true } },
    };
    var slot = try primitives.outlines(testing.allocator, tol, &.{&stadium}, &diag);
    defer slot.deinit();
    var slab = try sweep.extrude(testing.allocator, &slot, .{ 0, 0, 2 }, .{}, &diag);
    defer slab.deinit();
    // The stadium on the positive side of an axis along y through (−5, 0, 0)
    var ring = sweep.revolve(testing.allocator, &slot, .{ -5, 0, 0 }, .{ 0, 1, 0 }, std.math.pi, .{}, &diag) catch |err| {
        std.debug.print("revolve: {s} {f}\n", .{ @errorName(err), diag });
        return err;
    };
    defer ring.deinit();
    for ([_]*const Body{ &cylinder, &cone, &sphere, &torus, &slab, &ring }) |body| {
        var report = try check.run(testing.allocator, body, .global);
        defer report.deinit(testing.allocator);
        if (report.first()) |f| std.debug.print("checker: {f}\n", .{f});
        try testing.expect(report.ok());
    }

    // The cylinder's first side face given a UV box of a quarter turn: its pcurves leave
    // it (a level-1 rule still holds: the box is inside the domain, without wrap)
    {
        var small = try cylinder.clone(testing.allocator);
        defer small.deinit();
        for (small.faces.items) |*f| {
            if (f.surface.kind != .cylinder) continue;
            f.uv_box.max[0] = f.uv_box.min[0] + std.math.pi / 2.0;
            break;
        }
        var geometric = try check.run(testing.allocator, &small, .geometric);
        defer geometric.deinit(testing.allocator);
        try testing.expect(geometric.ok());
        try expectRule(&small, .global, .pcurve_outside_box);
    }
    // The bottom circle's pcurve moved up by 1.2 zones: within the lift's slack once the
    // edges and vertices carry a gap of a zone (level 1 holds), but a zone and a fifth
    // from the seams' pcurves it should meet (level 2 names the coedge after it)
    {
        var astray = try cylinder.clone(testing.allocator);
        defer astray.deinit();
        astray.geometry.lines2.items[0].o[1] += 1.2 * tol.zone;
        for (astray.edges.items) |*e| e.gap = tol.zone;
        for (astray.vertices.items) |*v| v.gap = tol.zone;
        var geometric = try check.run(testing.allocator, &astray, .geometric);
        defer geometric.deinit(testing.allocator);
        try testing.expect(geometric.ok());
        try expectRule(&astray, .global, .pcurves_disjoint);
    }
}

test "check: a planar face narrower than the zone is a sliver, its edges long and its vertices apart" {
    // A tetrahedron on a triangle 1 long and 1.5e-5 high: its base is a sliver (area
    // 7.5e-6 against the zone times half its perimeter, 1e-5), which no rule of edges or
    // vertices sees: its edges are long, its corners apart, its third corner beyond the
    // zone of the opposite edge
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0.5, 1.5e-5, 0 }, .{ 0.5, -0.3, 1 } };
    const triangles = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 2, 0, 3 } };
    // The builder checks what it makes, so the sliver is refused as it is built
    try testing.expectError(error.NotValid, @import("../construct/primitives.zig").polyhedron(testing.allocator, tol, &points, &triangles, &diag));
    const first = diag.first().?;
    try testing.expectEqual(@import("../diagnostics.zig").Code.sliver_face, first.code);
    try testing.expectApproxEqRel(@as(f64, 7.5e-6), first.measured, 1e-6);
}
