//! Coverage over the corpus (M4's exit, research/opengeometry.md §4: OpenGeometry's golden
//! scenes must exercise every handler of a closed enum): every pipeline branch, each
//! interference class of the paves (`pave.INTERFERENCES`) and each row of the selection
//! table (`select.keep`, by operation, operand and class), and every refusal reason and
//! warning of the boolean (`pipeline.REFUSALS`, `pipeline.WARNINGS`) is exercised by some
//! case of the corpus; and every guard (`pipeline.GUARDS`), which no valid input reaches,
//! is made to fire by a case that breaks what it guards. The test fails naming whatever
//! is uncovered. A source test holds the lists closed: every finding code the boolean's
//! files raise is in one of them.
//!
//! The corpus is the box configurations of corpus_test.zig, every operation, and the
//! cases below: one per refusal reason, each asserting it is refused with that reason, and
//! one per guard. (The fuzzer's finds and the other configurations are degeneracy_test.zig's.)

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const sew = @import("../construct/sew.zig");
const geometry = @import("../geometry/types.zig");
const pave = @import("pave.zig");
const imprint = @import("imprint.zig");
const classify = @import("classify.zig");
const select = @import("select.zig");
const pipeline = @import("pipeline.zig");
const trim = @import("trim.zig");
const helpers = @import("pipeline_test.zig");
const corpus = @import("corpus_test.zig");
const Vec3 = vec.Vec3;
const Code = diagnostics.Code;
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);
const OPS = std.enums.values(select.Op);
const CLASSES = std.enums.values(classify.Class);
/// The pyramid's sides in the case of edges crowding one vertex: past the 64 edges the
/// paves keep apart near one point.
const CROWD_SIDES = 200;

/// What the corpus exercised.
const Coverage = struct {
    interferences: [pave.INTERFERENCES.len]bool = @splat(false),
    /// By operation, operand and class: the selection table's rows.
    rules: [OPS.len][2][CLASSES.len]bool = @splat(@splat(@splat(false))),
    codes: std.EnumSet(Code) = .empty,

    /// What a boolean's report and findings show.
    fn record(self: *Coverage, report: *const pipeline.Report, diag: *const Diagnostics) void {
        for (report.interferences, 0..) |n, i| self.interferences[i] = self.interferences[i] or n > 0;
        for (report.fragments, 0..) |row, operand| for (row, 0..) |n, class| {
            if (n > 0) self.rules[@intFromEnum(report.op)][operand][class] = true;
        };
        self.findings(diag);
    }

    fn findings(self: *Coverage, diag: *const Diagnostics) void {
        for (diag.findings.items) |f| self.codes.insert(f.code);
    }

    /// `op` of `a` and `b`, recorded: a result or a refusal, which `expect` names when given.
    fn boolean(self: *Coverage, a: *const Body, b: *const Body, op: select.Op, options: pipeline.Options, expect: ?Code) !void {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var report = pipeline.Report.init(testing.allocator);
        defer report.deinit();
        if (pipeline.boolean(testing.allocator, a, b, op, options, &diag, &report)) |made| {
            var result = made;
            result.deinit();
            try testing.expectEqual(@as(?Code, null), expect);
        } else |err| {
            if (err == error.OutOfMemory) return err;
            try testing.expectEqual(expect, diag.first().?.code);
        }
        self.record(&report, &diag);
    }

    /// A refusal outside the boolean's own run (a cut's argument, a chain), recorded.
    fn refused(self: *Coverage, result: anytype, diag: *Diagnostics, expect: Code) !void {
        if (result) |made| {
            var body = made;
            body.deinit();
            return error.TestUnexpectedResult;
        } else |err| {
            if (err == error.OutOfMemory) return err;
            try testing.expectEqual(expect, diag.first().?.code);
        }
        self.findings(diag);
    }
};

fn box(lo: Vec3, hi: Vec3) !Body {
    return helpers.box(lo, hi);
}

fn polyhedron(points: []const Vec3, triangles: []const [3]u32) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return primitives.polyhedron(testing.allocator, tol, points, triangles, &diag);
}

/// A tetrahedron on `apex` and three other corners, wound outward (as degeneracy_test.zig's).
fn tetrahedron(apex: Vec3, p: Vec3, q: Vec3, r: Vec3) !Body {
    // Outward: the base seen from the apex runs clockwise
    const n = vec.cross(vec.sub(q, p), vec.sub(r, p));
    const flip = vec.dot(n, vec.sub(apex, p)) > 0;
    const base: [3]u32 = if (flip) .{ 1, 3, 2 } else .{ 1, 2, 3 };
    return polyhedron(&.{ apex, p, q, r }, &.{ base, .{ 0, base[1], base[0] }, .{ 0, base[2], base[1] }, .{ 0, base[0], base[2] } });
}

// --- the cases of the refusal reasons ---

fn notASolid(cov: *Coverage) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sheet = try primitives.square(testing.allocator, tol, 1, 1, false, &diag);
    defer sheet.deinit();
    var b = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer b.deinit();
    try cov.boolean(&sheet, &b, .@"union", .{}, .empty_input);
}

fn chainOfNone(cov: *Coverage) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try cov.refused(pipeline.chain(testing.allocator, &.{}, .@"union", .{}, &diag, null), &diag, .empty_input);
}

fn badTolerance(cov: *Coverage) !void {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer b.deinit();
    try cov.boolean(&a, &b, .@"union", .{ .common = .{ .tolerance = Tolerance.fromZone(std.math.nan(f64)) } }, .bad_tolerance);
}

fn cutNotFinite(cov: *Coverage) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    try cov.refused(trim.trimByPlane(testing.allocator, &a, .{ 0, 0, 1 }, std.math.nan(f64), .{}, &diag, null), &diag, .not_finite);
}

fn cutNormalOfNoLength(cov: *Coverage) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    try cov.refused(trim.trimByPlane(testing.allocator, &a, .{ 0, 0, 0 }, 1, .{}, &diag, null), &diag, .not_positive);
}

fn curvedOperand(cov: *Coverage) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var c = try primitives.cylinder(testing.allocator, tol, 0.5, 3, false, &diag);
    defer c.deinit();
    try cov.boolean(&a, &c, .difference, .{}, .not_implemented);
}

fn pastTheTolerance(cov: *Coverage) !void {
    // A million from the origin at a zone of 1e-12: a coordinate's last bit is coarser than
    // the welder's cell
    var a = try box(.{ 1e6, 0, 0 }, .{ 1e6 + 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1e6 + 1, 1, 1 }, .{ 1e6 + 3, 3, 3 });
    defer b.deinit();
    try cov.boolean(&a, &b, .@"union", .{ .common = .{ .tolerance = Tolerance.fromZone(1e-12) } }, .too_large_for_tolerance);
}

fn edgesCrowdingOneVertex(cov: *Coverage) !void {
    // A pyramid of CROWD_SIDES sides, and a small box just under its apex, a corner on its
    // axis: every side runs from the apex, so the corner lies in every side's box
    var points: [CROWD_SIDES + 2]Vec3 = undefined;
    points[0] = .{ 0, 0, 1 };
    points[1] = .{ 0, 0, 0 };
    for (0..CROWD_SIDES) |i| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / CROWD_SIDES;
        points[2 + i] = .{ @cos(t), @sin(t), 0 };
    }
    var triangles: [2 * CROWD_SIDES][3]u32 = undefined;
    for (0..CROWD_SIDES) |i| {
        const here: u32 = @intCast(2 + i);
        const next: u32 = @intCast(2 + (i + 1) % CROWD_SIDES);
        triangles[2 * i] = .{ 0, here, next };
        triangles[2 * i + 1] = .{ 1, next, here };
    }
    var pyramid = try polyhedron(&points, &triangles);
    defer pyramid.deinit();
    var b = try box(.{ 0, 0, 0.8 }, .{ 0.01, 0.01, 0.9 });
    defer b.deinit();
    try cov.boolean(&pyramid, &b, .@"union", .{}, .limit_exceeded);
}

fn atTheTolerance(cov: *Coverage) !void {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 1 + tol.xsect, 0, 0 }, .{ 2, 1, 1 });
    defer b.deinit();
    try cov.boolean(&a, &b, .@"union", .{}, .at_tolerance);
}

fn gapPastTheZone(cov: *Coverage) !void {
    // A corner with the gap an earlier boolean recorded, merged with another the zone away
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 1 + 1e-5, 1, 1 }, .{ 2, 2, 2 });
    defer b.deinit();
    for (a.vertices.items, 0..) |*v, i| {
        if (vec.distance(a.point(types.VertexIndex.of(i)), .{ 1, 1, 1 }) == 0) v.gap = 0.8e-5;
    }
    try cov.boolean(&a, &b, .@"union", .{}, .gap_too_large);
}

fn edgeTooShort(cov: *Coverage) !void {
    // A box three tolerances thin, crossed by another's face half-way up its short edges
    const xsect = tol.xsect;
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 3 * xsect });
    defer a.deinit();
    var b = try box(.{ 0.25, 0.25, 1.5 * xsect }, .{ 2, 2, 1 });
    defer b.deinit();
    try cov.boolean(&a, &b, .@"union", .{}, .edge_too_short);
}

fn pinched(cov: *Coverage) !void {
    // A tetrahedron through a box's bottom, its apex on the box's side from within
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var through = try tetrahedron(.{ 2, 1, 1 }, .{ 0.5, 0.5, -1 }, .{ 0.5, 1.5, -1 }, .{ 1.5, 1, -1 });
    defer through.deinit();
    try cov.boolean(&a, &through, .difference, .{}, .pinched);
}

fn nearlyCoplanar(cov: *Coverage) !void {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 1 + 1e-4, 0, 0 }, .{ 2, 1, 1 });
    defer b.deinit();
    try cov.boolean(&a, &b, .@"union", .{}, null);
}

// --- the cases of the guards ---

fn corruptLoop(cov: *Coverage) !void {
    // A box whose first coedge runs on into another face's loop: its loop never closes
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer b.deinit();
    const first = types.CoedgeIndex.of(0);
    for (a.coedges.items, 0..) |c, i| if (c.loop != a.coedge(first).loop) {
        a.coedge(first).next = types.CoedgeIndex.of(i);
        break;
    };
    try cov.boolean(&a, &b, .@"union", .{}, .loop_not_closed);
}

fn overlappingFace(cov: *Coverage) !void {
    // A prism on a pentagram: its top face's one loop goes round the centre twice. A box
    // through one of the star's arms (wound once, so the paves find it crossing the face;
    // the centre, wound twice, is outside by parity) puts the face through the overlay
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var star = try pentagramPrism(&diag);
    defer star.deinit();
    var other = try box(.{ -0.05, 0.7, -1 }, .{ 0.05, 0.8, 2 });
    defer other.deinit();
    try cov.boolean(&star, &other, .difference, .{}, .faces_overlap);
}

/// A prism 1 high on the pentagram of a unit circle's fifths taken every second: a closed
/// shell whose top and bottom faces each cover the inner pentagon twice.
fn pentagramPrism(diag: *Diagnostics) !Body {
    var b = try primitives.Builder.init(testing.allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    var top: [5]types.VertexIndex = undefined;
    var bottom: [5]types.VertexIndex = undefined;
    for (0..5) |i| {
        // In the star's order: every second fifth
        const t = std.math.pi / 2.0 + 2 * std.math.pi * @as(f64, @floatFromInt((2 * i) % 5)) / 5.0;
        top[i] = try b.vertex(.{ @cos(t), @sin(t), 1 });
        bottom[i] = try b.vertex(.{ @cos(t), @sin(t), 0 });
    }
    var top_edges: [5]sew.EdgeSpec = undefined;
    var bottom_edges: [5]sew.EdgeSpec = undefined;
    var side_edges: [5][4]sew.EdgeSpec = undefined;
    var side_loops: [5][1]sew.LoopSpec = undefined;
    var faces: [7]sew.FaceSpec = undefined;
    for (0..5) |i| {
        const j = (i + 1) % 5;
        top_edges[i] = try b.straight(top[i], top[j]);
        bottom_edges[i] = try b.straight(bottom[(5 - i) % 5], bottom[(9 - i) % 5]);
        side_edges[i] = .{ try b.straight(top[j], top[i]), try b.straight(top[i], bottom[i]), try b.straight(bottom[i], bottom[j]), try b.straight(bottom[j], top[j]) };
        side_loops[i] = .{.{ .edges = &side_edges[i] }};
        const p = b.body.point(top[i]);
        const q = b.body.point(top[j]);
        const along = vec.normalized(vec.sub(q, p)).?;
        const facing = try b.facingPlane(geometry.Frame.init(p, along, vec.cross(along, vec.Z3)));
        faces[2 + i] = .{ .surface = facing.surface, .same_sense = facing.same_sense, .loops = &side_loops[i] };
    }
    const top_loop = [_]sew.LoopSpec{.{ .edges = &top_edges }};
    const bottom_loop = [_]sew.LoopSpec{.{ .edges = &bottom_edges }};
    const up = try b.facingPlane(geometry.Frame.init(.{ 0, 0, 1 }, vec.X3, vec.Z3));
    const down = try b.facingPlane(geometry.Frame.init(.{ 0, 0, 0 }, vec.X3, vec.neg(vec.Z3)));
    faces[0] = .{ .surface = up.surface, .same_sense = up.same_sense, .loops = &top_loop };
    faces[1] = .{ .surface = down.surface, .same_sense = down.same_sense, .loops = &bottom_loop };
    for (&faces) |*f| f.uv_box = .{ .min = .{ -2, -2 }, .max = .{ 2, 2 } };
    return b.finish(&faces, .outer);
}

/// The paves of two cubes overlapping at a corner.
fn cornerPaves(a: *const Body, b: *const Body, diag: *Diagnostics) !pave.Paves {
    var stage: pave.Stage = .operands;
    return pave.run(testing.allocator, a, b, tol, .{}, diag, &stage);
}

/// The merged vertex at `p`.
fn mergedAt(paves: *const pave.Paves, p: Vec3) u32 {
    for (paves.points.items, 0..) |q, i| if (vec.distance(p, q) == 0) return @intCast(i);
    unreachable;
}

fn crossingMissed(cov: *Coverage) !void {
    // A section across the first cube's face x = 2 from (2, 0, 2) to (2, 2, 1), crossing
    // the section y = 1 at (2, 1, 1.5), a point the paves never found
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var paves = try cornerPaves(&a, &b, &diag);
    defer paves.deinit();
    const face = helpers.facing(&a, .{ 1, 0, 0 });
    const u = mergedAt(&paves, .{ 2, 0, 2 });
    const w = mergedAt(&paves, .{ 2, 2, 1 });
    try paves.sections[0][face].append(testing.allocator, .{ @min(u, w), @max(u, w) });
    try cov.refused(imprint.run(testing.allocator, &paves, .{}, &diag), &diag, .imprint_unmatched);
}

fn coplanarForgotten(cov: *Coverage) !void {
    // Boxes sharing their top and bottom planes, the paves' record of it dropped: the
    // shared faces' pieces lie on the other operand's boundary and on none of its faces
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 0 }, .{ 3, 3, 2 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var paves = try cornerPaves(&a, &b, &diag);
    defer paves.deinit();
    paves.coplanar.clearRetainingCapacity();
    var fragments = try imprint.run(testing.allocator, &paves, .{}, &diag);
    defer fragments.deinit();
    var stats: classify.Stats = .{};
    const classes = classify.run(testing.allocator, &paves, &fragments, .{}, true, &diag, &stats);
    if (classes) |c| {
        testing.allocator.free(c);
        return error.TestUnexpectedResult;
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try testing.expectEqual(Code.unclassified, diag.first().?.code);
    }
    cov.findings(&diag);
}

fn edgeUsedThrice(cov: *Coverage) !void {
    // Three fragments' uses of one edge: no pairing of faces about it
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.Builder.init(testing.allocator, tol, .solid, &diag);
    defer b.deinit();
    defer b.body.deinit();
    const p = try b.vertex(.{ 0, 0, 0 });
    const q = try b.vertex(.{ 0, 0, 1 });
    var specs = [_]sew.EdgeSpec{ try b.straight(p, q), try b.straight(q, p), try b.straight(p, q) };
    const uses = [_]pipeline.Use{ .{ .spec = 0, .face = 0 }, .{ .spec = 1, .face = 1 }, .{ .spec = 2, .face = 2 } };
    const normals = [_]Vec3{ vec.X3, vec.Y3, vec.neg(vec.X3) };
    try testing.expectError(error.NotValid, pipeline.pairTouching(testing.allocator, &b.body, &specs, &uses, &normals, &diag));
    try testing.expectEqual(Code.edge_coedge_count, diag.first().?.code);
    cov.findings(&diag);
}

const CASES = [_]struct { name: []const u8, run: *const fn (*Coverage) anyerror!void }{
    .{ .name = "an operand that is no solid", .run = notASolid },
    .{ .name = "a chain of no operands", .run = chainOfNone },
    .{ .name = "a tolerance that isn't one", .run = badTolerance },
    .{ .name = "a cut's offset not finite", .run = cutNotFinite },
    .{ .name = "a cut's normal of no length", .run = cutNormalOfNoLength },
    .{ .name = "a curved operand", .run = curvedOperand },
    .{ .name = "coordinates past the tolerance", .run = pastTheTolerance },
    .{ .name = "edges crowding one vertex", .run = edgesCrowdingOneVertex },
    .{ .name = "faces the tolerance apart to rounding", .run = atTheTolerance },
    .{ .name = "vertices merged past the zone", .run = gapPastTheZone },
    .{ .name = "an edge too short to split", .run = edgeTooShort },
    .{ .name = "a pinch at a point", .run = pinched },
    .{ .name = "walls a hair apart", .run = nearlyCoplanar },
    .{ .name = "an operand's loop that does not close", .run = corruptLoop },
    .{ .name = "an operand's face covering its plane twice", .run = overlappingFace },
    .{ .name = "a crossing the paves missed", .run = crossingMissed },
    .{ .name = "a coplanar pair the paves forgot", .run = coplanarForgotten },
    .{ .name = "an edge three fragments use", .run = edgeUsedThrice },
};

test "coverage: every interference class, selection rule, refusal reason, warning and guard is exercised by the corpus" {
    var cov: Coverage = .{};
    for (corpus.CASES) |case| {
        errdefer std.debug.print("corpus case \"{s}\"\n", .{case.name});
        var a = try box(case.a[0], case.a[1]);
        defer a.deinit();
        var b = try box(case.b[0], case.b[1]);
        defer b.deinit();
        for (OPS) |op| try cov.boolean(&a, &b, op, .{}, null);
    }
    for (CASES) |case| {
        errdefer std.debug.print("coverage case \"{s}\"\n", .{case.name});
        try case.run(&cov);
    }

    var uncovered: usize = 0;
    for (pave.INTERFERENCES, cov.interferences) |stage, seen| if (!seen) {
        std.debug.print("uncovered: the interference class {s}\n", .{@tagName(stage)});
        uncovered += 1;
    };
    for (OPS, 0..) |op, o| for (0..2) |operand| for (CLASSES, 0..) |class, c| {
        if (cov.rules[o][operand][c]) continue;
        std.debug.print("uncovered: the selection rule {s}, {s} {s} ({s})\n", .{ @tagName(op), if (operand == 0) "a" else "b", @tagName(class), @tagName(select.keep(op, @intCast(operand), class)) });
        uncovered += 1;
    };
    for ([_][]const Code{ &pipeline.REFUSALS, &pipeline.WARNINGS, &pipeline.GUARDS }, [_][]const u8{ "refusal reason", "warning", "guard" }) |list, what| {
        for (list) |code| if (!cov.codes.contains(code)) {
            std.debug.print("uncovered: the {s} {s}\n", .{ what, @tagName(code) });
            uncovered += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), uncovered);
}

test "coverage: every finding code the boolean's files raise is a refusal reason, a warning or a guard" {
    const sources = [_][]const u8{
        @embedFile("pave.zig"),     @embedFile("imprint.zig"),  @embedFile("classify.zig"),
        @embedFile("select.zig"),   @embedFile("simplify.zig"), @embedFile("pipeline.zig"),
        @embedFile("trim.zig"),
    };
    const marker = ".code = .";
    var unlisted: usize = 0;
    for (sources) |text| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, marker)) |i| {
            const start = i + marker.len;
            var end = start;
            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
            at = end;
            const code = std.meta.stringToEnum(Code, text[start..end]) orelse continue;
            const listed = for ([_][]const Code{ &pipeline.REFUSALS, &pipeline.WARNINGS, &pipeline.GUARDS }) |list| {
                if (std.mem.indexOfScalar(Code, list, code) != null) break true;
            } else false;
            if (!listed) {
                std.debug.print("unlisted: {s}, raised by a boolean's file but in none of pipeline.REFUSALS, WARNINGS, GUARDS\n", .{@tagName(code)});
                unlisted += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), unlisted);
}
