//! Sketch booleans (docs/architecture.md §7.5): the union, difference and intersection of
//! sheets on the plane `z = 0`, by the overlay engine with winding labels. Each sheet's
//! loops are the overlay's inputs (lines and arcs, every other curve refused until it is
//! needed); the region kept is a predicate on the windings (non-zero for the booleans,
//! odd for `evenOdd`, the fill of raw outlines); its boundary cycles, outer and holes told
//! by their areas and nested, become the faces of a new sheet, sewn and checked.

const std = @import("std");
const vec = @import("../math/vec.zig");
const trace = @import("../io/trace.zig");
const predicates = @import("../math/predicates.zig");
const trig = @import("../math/trig.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const sew = @import("../construct/sew.zig");
const primitives = @import("../construct/primitives.zig");
const overlay_mod = @import("overlay.zig");
const Body = body_mod.Body;
const Builder = primitives.Builder;
const Overlay = overlay_mod.Overlay;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

pub const Op = enum { @"union", difference, intersection };

/// How far past an arc's start its end may be read and still be a full turn's worth.
const ANGLE_SLACK: f64 = 1e-9;

/// The union, difference (the first less the others) or intersection of `sheets`, as a
/// new sheet; the inputs untouched. An empty result is the empty sheet.
pub fn boolean(allocator: std.mem.Allocator, sheets: []const *const Body, op: Op, options: diagnostics.Options, diag: *Diagnostics) Error!Body {
    try diagnostics.input.nonEmpty(diag, "sheets", sheets.len);
    try options.checkCancel();
    try trace.arguments(allocator, &options, "boolean", .{ .op = op, .sheets = sheets.len });
    var tol = options.tolerance orelse sheets[0].tol;
    for (sheets) |s| {
        if (s.kind != .sheet) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "an operand: a sheet" });
        if (options.tolerance == null) tol = tol.merge(s.tol);
    }
    var o = Overlay.init(allocator, tol);
    defer o.deinit();
    for (sheets) |s| {
        _ = o.addInput() catch |e| return mapError(diag, e);
        try addSheet(&o, s, diag);
    }
    try options.checkCancel();
    o.run() catch |e| return mapError(diag, e);
    const keep = try allocator.alloc(bool, o.faces.items.len);
    defer allocator.free(keep);
    for (keep, 0..) |*k, f| {
        const first = o.windingOf(@intCast(f), 0) != 0;
        var any_other = false;
        var all = first;
        for (1..o.inputs) |i| {
            const inside = o.windingOf(@intCast(f), @intCast(i)) != 0;
            any_other = any_other or inside;
            all = all and inside;
        }
        k.* = switch (op) {
            .@"union" => first or any_other,
            .difference => first and !any_other,
            .intersection => all,
        };
    }
    return build(allocator, tol, &o, keep, diag);
}

/// The region the outlines fill by the even-odd rule, whichever way each runs, as a
/// sheet: what a polygon of several outlines means (an outline inside another is a hole,
/// one inside the hole an island; a self-crossing outline fills both its lobes). Each
/// outline is a closed polygon of points.
pub fn evenOdd(allocator: std.mem.Allocator, tol: Tolerance, outlines: []const []const Vec2, diag: *Diagnostics) Error!Body {
    var o = Overlay.init(allocator, tol);
    defer o.deinit();
    _ = o.addInput() catch |e| return mapError(diag, e);
    for (outlines) |outline| {
        for (outline, 0..) |p, i| o.addEdge(.{ .a = p, .b = outline[(i + 1) % outline.len] }) catch |e| return mapError(diag, e);
    }
    return evenOddFill(allocator, tol, &o, diag);
}

/// The region closed outlines of lines and arcs (`overlay.InputEdge`, each outline's edges
/// head to tail) fill by the even-odd rule, as a sheet: `evenOdd` with arcs (a closed path,
/// a rounded rectangle). An outline's direction does not matter.
pub fn evenOddEdges(allocator: std.mem.Allocator, tol: Tolerance, outlines: []const []const overlay_mod.InputEdge, diag: *Diagnostics) Error!Body {
    var o = Overlay.init(allocator, tol);
    defer o.deinit();
    _ = o.addInput() catch |e| return mapError(diag, e);
    for (outlines) |outline| {
        for (outline) |edge| o.addEdge(edge) catch |e| return mapError(diag, e);
    }
    return evenOddFill(allocator, tol, &o, diag);
}

/// The faces of the one input's overlay with an odd winding, as a sheet.
fn evenOddFill(allocator: std.mem.Allocator, tol: Tolerance, o: *Overlay, diag: *Diagnostics) Error!Body {
    o.run() catch |e| return mapError(diag, e);
    const keep = try allocator.alloc(bool, o.faces.items.len);
    defer allocator.free(keep);
    for (keep, 0..) |*k, f| k.* = @mod(o.windingOf(@intCast(f), 0), 2) != 0;
    return build(allocator, tol, o, keep, diag);
}

/// The sheet's loops as the overlay's current input: each coedge an edge from its start to
/// its end, a circle's as an arc running the way the coedge does.
pub fn addSheet(o: *Overlay, sheet: *const Body, diag: *Diagnostics) Error!void {
    var shells = traverse.Shells.init(sheet);
    while (shells.next() catch return corrupt(diag)) |s| {
        var faces = traverse.Faces.init(sheet, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            var loops = traverse.Loops.init(sheet, f);
            while (loops.next() catch return corrupt(diag)) |l| {
                var it = traverse.Coedges.init(sheet, l);
                while (it.next() catch return corrupt(diag)) |c| {
                    const coedge = sheet.coedge(c);
                    const e = sheet.edge(coedge.edge);
                    const a = flat(sheet.point(sheet.coedgeStart(c)));
                    const b = flat(sheet.point(sheet.coedgeEnd(c)));
                    const edge: overlay_mod.InputEdge = switch (sheet.geometry.curve(e.curve)) {
                        .line => .{ .a = a, .b = b },
                        .circle => |circle| .{ .a = a, .b = b, .arc = .{ .c = flat(circle.c), .r = circle.r, .ccw = (circle.normal()[2] > 0) == coedge.same_sense } },
                        else => return diag.fail(error.NotRepresentable, .{ .code = .not_implemented, .entity = .of(.edge, @backingInt(coedge.edge)), .label = "a sketch edge that is neither a line nor an arc" }),
                    };
                    o.addEdge(edge) catch |err| return mapError(diag, err);
                }
            }
        }
    }
}

fn flat(p: Vec3) Vec2 {
    return .{ p[0], p[1] };
}

/// The kept region of an overlay as a sheet: its boundary cycles, outer loops and holes
/// told by their signed areas, each hole in the innermost outer containing it, each outer
/// a face; consecutive pieces of one line or one circle (what a cut at a crossing left,
/// or a miter's meeting point) are one edge. What the booleans, the even-odd fill and the
/// offset end with.
pub fn build(allocator: std.mem.Allocator, tol: Tolerance, o: *const Overlay, keep: []const bool, diag: *Diagnostics) Error!Body {
    var halves = std.ArrayList(u32).empty;
    defer halves.deinit(allocator);
    var starts = std.ArrayList(u32).empty;
    defer starts.deinit(allocator);
    o.boundary(keep, &halves, &starts) catch |e| return mapError(diag, e);
    const n_cycles = starts.items.len - 1;

    var b = try Builder.init(allocator, tol, .sheet, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    if (n_cycles == 0) return b.body;
    // Each cycle's pieces merged along one curve, then its vertices (once) and edges, and
    // its area
    // How many boundary half-edges leave each vertex: pieces merge across a vertex only
    // when the boundary passes it once, never across one another passage of the boundary
    // (a pinch, a hole touching the outer loop) also uses, which would leave an edge
    // running through a vertex
    const uses = try allocator.alloc(u32, o.points.items.len);
    defer allocator.free(uses);
    @memset(uses, 0);
    for (halves.items) |h| uses[o.origin(h)] += 1;
    const pieces = try allocator.alloc(Piece, halves.items.len);
    defer allocator.free(pieces);
    const piece_starts = try allocator.alloc(u32, n_cycles + 1);
    defer allocator.free(piece_starts);
    var n_pieces: u32 = 0;
    for (0..n_cycles) |ci| {
        piece_starts[ci] = n_pieces;
        n_pieces += mergePieces(o, halves.items[starts.items[ci]..starts.items[ci + 1]], pieces[n_pieces..], uses, tol);
    }
    piece_starts[n_cycles] = n_pieces;
    const vertex_of = try allocator.alloc(types.VertexIndex, o.points.items.len);
    defer allocator.free(vertex_of);
    @memset(vertex_of, .none);
    // An arc piece across its circle's seam is two edges (`edgeSpecs`)
    const specs = try allocator.alloc(sew.EdgeSpec, 2 * n_pieces);
    defer allocator.free(specs);
    const spec_starts = try allocator.alloc(u32, n_cycles + 1);
    defer allocator.free(spec_starts);
    var seams: std.AutoHashMapUnmanaged(u32, types.VertexIndex) = .empty;
    defer seams.deinit(allocator);
    const areas = try allocator.alloc(f64, n_cycles);
    defer allocator.free(areas);
    var si: u32 = 0;
    for (0..n_cycles) |ci| {
        spec_starts[ci] = si;
        var area: f64 = 0;
        for (pieces[piece_starts[ci]..piece_starts[ci + 1]]) |piece| {
            if (vertex_of[piece.a] == .none) vertex_of[piece.a] = try b.vertex(o.points.items[piece.a]);
            if (vertex_of[piece.b] == .none) vertex_of[piece.b] = try b.vertex(o.points.items[piece.b]);
            var two: [2]sew.EdgeSpec = undefined;
            const made = try edgeSpecs(&b, o, piece, vertex_of[piece.a], vertex_of[piece.b], &seams, &two);
            for (two[0..made]) |spec| {
                specs[si] = spec;
                si += 1;
            }
            area += areaTerm(o, piece);
        }
        areas[ci] = area / 2.0;
    }
    spec_starts[n_cycles] = si;
    // Each hole's face: the outer cycle it lies in (`nestCycles`); the region is on
    // every piece's left and nothing is known beyond it
    const segments = try allocator.alloc(overlay_mod.Segment, n_pieces);
    defer allocator.free(segments);
    for (0..n_cycles) |ci| {
        for (pieces[piece_starts[ci]..piece_starts[ci + 1]], piece_starts[ci]..) |piece, k| {
            segments[k] = .{ .a = o.point(piece.a), .b = o.point(piece.b), .arc = piece.arc, .cycle = @intCast(ci), .slot_a = o.slot.items[piece.first], .slot_b = o.slot.items[piece.last ^ 1] };
        }
    }
    const owner = try allocator.alloc(u32, n_cycles);
    defer allocator.free(owner);
    try overlay_mod.nestCycles(allocator, segments, piece_starts, areas, tol.zone, owner);
    var n_faces: usize = 0;
    for (0..n_cycles) |ci| {
        if (areas[ci] > 0) {
            n_faces += 1;
            continue;
        }
        if (owner[ci] == overlay_mod.UNBOUNDED) return diag.fail(error.NotValid, .{ .code = .hole_outside_outer, .label = "the result" });
    }
    // The faces: each outer cycle with its holes, on the world plane
    const loops = try allocator.alloc(sew.LoopSpec, n_cycles);
    defer allocator.free(loops);
    const face_specs = try allocator.alloc(sew.FaceSpec, n_faces);
    defer allocator.free(face_specs);
    // The sketch's one plane
    const plane = try b.plane(geometry.Frame.world, &.{});
    var li: usize = 0;
    var fi: usize = 0;
    for (0..n_cycles) |oi| {
        if (areas[oi] <= 0) continue;
        const first = li;
        loops[li] = .{ .edges = specs[spec_starts[oi]..spec_starts[oi + 1]] };
        li += 1;
        var box = geometry.Box2.empty;
        growBox(&box, o, pieces[piece_starts[oi]..piece_starts[oi + 1]]);
        for (0..n_cycles) |hi| {
            if (owner[hi] != oi) continue;
            loops[li] = .{ .edges = specs[spec_starts[hi]..spec_starts[hi + 1]] };
            li += 1;
        }
        face_specs[fi] = .{ .surface = plane, .loops = loops[first..li], .uv_box = box };
        fi += 1;
    }
    return b.finish(face_specs, .sheet);
}

/// A piece of a cycle's boundary: from vertex `a` to `b` of the overlay, straight or an
/// arc the way the cycle runs it; what consecutive half-edges on one curve merge into.
/// A run of boundary half-edges on one curve from vertex `a` to `b`: the first leaves `a`,
/// the last arrives at `b`.
const Piece = struct { a: u32, b: u32, arc: ?overlay_mod.Arc, first: u32, last: u32 };

/// The cycle's half-edges as pieces, consecutive ones on one line (collinear, the same
/// way) or on one circle (the same centre, radius and sense) merged where the boundary
/// passes their shared vertex once (`uses`), the merge wrapping
/// round the cycle's start. Returns how many pieces `out` got.
fn mergePieces(o: *const Overlay, halves: []const u32, out: []Piece, uses: []const u32, tol: Tolerance) u32 {
    var n: u32 = 0;
    for (halves) |h| {
        const piece = Piece{ .a = o.origin(h), .b = o.target(h), .arc = o.arcOf(h), .first = h, .last = h };
        if (n > 0 and uses[piece.a] == 1 and continues(o, out[n - 1], piece, tol)) {
            out[n - 1].b = piece.b;
            out[n - 1].last = h;
        } else {
            out[n] = piece;
            n += 1;
        }
    }
    // The last and the first
    while (n > 1 and uses[out[0].a] == 1 and continues(o, out[n - 1], out[0], tol)) {
        out[0].a = out[n - 1].a;
        out[0].first = out[n - 1].first;
        n -= 1;
    }
    return n;
}

/// Whether `next` carries on `prev`'s curve: the same line the same way, or the same
/// circle the same way round, short of closing it (a full circle stays two arcs, D7).
fn continues(o: *const Overlay, prev: Piece, next: Piece, tol: Tolerance) bool {
    if (prev.arc) |pa| {
        const na = next.arc orelse return false;
        if (prev.a == next.b) return false;
        return pa.ccw == na.ccw and @abs(pa.r - na.r) <= tol.zone and vec.distance2(pa.c, na.c) <= tol.zone;
    }
    if (next.arc != null) return false;
    const a = o.point(prev.a);
    const b = o.point(prev.b);
    const c = o.point(next.b);
    // The shared vertex within the zone of the line from the first end to the last (the
    // turn is twice the triangle's area, that distance times the line's length), and
    // the same way: not the angle tolerance, which merged pieces a fraction of a degree
    // apart into a line the vertex was far off
    const turn = predicates.orient2d(a, b, c);
    if (@abs(turn) > tol.zone * vec.distance2(a, c)) return false;
    return vec.dot2(vec.sub2(b, a), vec.sub2(c, b)) > 0;
}

/// A piece as edge specifications of the new sheet, into `out`: a line through its ends,
/// or its circle interned with the angles of its ends as the range, run the way the piece
/// does. An arc across its circle's seam (the parameter's start, the point to +x of the
/// centre) is two edges meeting at a vertex there (one per circle, `seams`), so that no
/// edge's range leaves its circle's period and no face swept from it is periodic (D7); an
/// end within the zone of the seam is taken as on it. Returns how many were written.
fn edgeSpecs(b: *Builder, o: *const Overlay, piece: Piece, start: types.VertexIndex, end: types.VertexIndex, seams: *std.AutoHashMapUnmanaged(u32, types.VertexIndex), out: *[2]sew.EdgeSpec) Error!usize {
    const arc = piece.arc orelse {
        out[0] = try b.straight(start, end);
        return 1;
    };
    const circle = curves.Circle{ .c = .{ arc.c[0], arc.c[1], 0 }, .x = vec.X3, .y = vec.Y3, .r = arc.r };
    const ref = b.interner.circle(b.allocator, &b.body.geometry, circle) catch |e| return b.fail(e);
    const range = rangeOf(o, piece);
    var from = range[0];
    var to = range[1];
    const slack = b.body.tol.zone / arc.r;
    if (from >= geometry.TWO_PI - slack) {
        from = 0;
        to -= geometry.TWO_PI;
    }
    if (to <= geometry.TWO_PI + slack) {
        out[0] = .{ .start = start, .end = end, .curve = ref, .t0 = from, .t1 = @min(to, geometry.TWO_PI), .forward = arc.ccw };
        return 1;
    }
    const gop = try seams.getOrPut(b.allocator, @as(u32, ref.index));
    if (!gop.found_existing) gop.value_ptr.* = try b.vertex(.{ arc.c[0] + arc.r, arc.c[1], 0 });
    const seam = gop.value_ptr.*;
    if (arc.ccw) {
        out[0] = .{ .start = start, .end = seam, .curve = ref, .t0 = from, .t1 = geometry.TWO_PI, .forward = true };
        out[1] = .{ .start = seam, .end = end, .curve = ref, .t0 = 0, .t1 = to - geometry.TWO_PI, .forward = true };
    } else {
        out[0] = .{ .start = start, .end = seam, .curve = ref, .t0 = 0, .t1 = to - geometry.TWO_PI, .forward = false };
        out[1] = .{ .start = seam, .end = end, .curve = ref, .t0 = from, .t1 = geometry.TWO_PI, .forward = false };
    }
    return 2;
}

/// The circle's parameter range an arc piece covers, counter-clockwise from the end the
/// arc starts from that way round: the start in `[0, 2π)`, the end past it by the sweep.
fn rangeOf(o: *const Overlay, piece: Piece) [2]f64 {
    const arc = piece.arc.?;
    const pa = o.point(piece.a);
    const pb = o.point(piece.b);
    const ta = @mod(trig.atan2(pa[1] - arc.c[1], pa[0] - arc.c[0]), geometry.TWO_PI);
    const tb = @mod(trig.atan2(pb[1] - arc.c[1], pb[0] - arc.c[0]), geometry.TWO_PI);
    const from = if (arc.ccw) ta else tb;
    var to = if (arc.ccw) tb else ta;
    if (to <= from + ANGLE_SLACK) to += geometry.TWO_PI;
    return .{ from, to };
}

/// Twice a piece's share of its cycle's area, as the overlay reckons it.
fn areaTerm(o: *const Overlay, piece: Piece) f64 {
    const a = o.point(piece.a);
    const b = o.point(piece.b);
    var twice = a[0] * b[1] - b[0] * a[1];
    if (piece.arc) |arc| {
        const range = rangeOf(o, piece);
        const theta = range[1] - range[0];
        const segment = arc.r * arc.r * (theta - @sin(theta));
        twice += if (arc.ccw) segment else -segment;
    }
    return twice;
}

/// The UV box of a cycle on the world plane: its ends and its arcs' extreme points.
fn growBox(box: *geometry.Box2, o: *const Overlay, pieces: []const Piece) void {
    for (pieces) |piece| {
        box.grow(o.point(piece.a));
        if (piece.arc) |arc| {
            const circle = curves.Circle{ .c = .{ arc.c[0], arc.c[1], 0 }, .x = vec.X3, .y = vec.Y3, .r = arc.r };
            const range = rangeOf(o, piece);
            const b3 = circle.bounds(range[0], range[1]);
            box.grow(.{ b3.min[0], b3.min[1] });
            box.grow(.{ b3.max[0], b3.max[1] });
        }
    }
}

pub fn mapError(diag: *Diagnostics, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooMany => diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "the sketch's edges" }),
        error.OutOfRange => diag.fail(error.InvalidInput, .{ .code = .too_large_for_tolerance, .label = "a coordinate" }),
        else => unreachable,
    };
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "an operand" });
}
