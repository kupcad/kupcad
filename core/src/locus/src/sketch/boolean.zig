//! Sketch booleans (docs/architecture.md §7.5): the union, difference and intersection of
//! sheets on the plane `z = 0`, by the overlay engine with winding labels. Each sheet's
//! loops are the overlay's inputs (lines and arcs, every other curve refused until it is
//! needed); the region kept is a predicate on the windings (non-zero for the booleans,
//! odd for `evenOdd`, the fill of raw outlines); its boundary cycles, outer and holes told
//! by their areas and nested, become the faces of a new sheet, sewn and checked.

const std = @import("std");
const vec = @import("../math/vec.zig");
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

/// How far inside a region its probe point sits, in zones.
const PROBE_ZONES: f64 = 4;
/// How far past an arc's start its end may be read and still be a full turn's worth.
const ANGLE_SLACK: f64 = 1e-9;

/// The union, difference (the first less the others) or intersection of `sheets`, as a
/// new sheet; the inputs untouched. An empty result is the empty sheet.
pub fn boolean(allocator: std.mem.Allocator, sheets: []const *const Body, op: Op, options: diagnostics.Options, diag: *Diagnostics) Error!Body {
    try diagnostics.input.nonEmpty(diag, "sheets", sheets.len);
    try options.checkCancel();
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
    o.run() catch |e| return mapError(diag, e);
    const keep = try allocator.alloc(bool, o.faces.items.len);
    defer allocator.free(keep);
    for (keep, 0..) |*k, f| k.* = @mod(o.windingOf(@intCast(f), 0), 2) != 0;
    return build(allocator, tol, &o, keep, diag);
}

/// The sheet's loops as the overlay's current input: each coedge an edge from its start to
/// its end, a circle's as an arc running the way the coedge does.
fn addSheet(o: *Overlay, sheet: *const Body, diag: *Diagnostics) Error!void {
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

/// The kept region as a sheet: its boundary cycles, outer loops and holes told by their
/// signed areas, each hole in the innermost outer containing it, each outer a face.
fn build(allocator: std.mem.Allocator, tol: Tolerance, o: *const Overlay, keep: []const bool, diag: *Diagnostics) Error!Body {
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
    // The vertices once, the edges per cycle, the cycles' areas
    const vertex_of = try allocator.alloc(types.VertexIndex, o.points.items.len);
    defer allocator.free(vertex_of);
    @memset(vertex_of, .none);
    const specs = try allocator.alloc(sew.EdgeSpec, halves.items.len);
    defer allocator.free(specs);
    const areas = try allocator.alloc(f64, n_cycles);
    defer allocator.free(areas);
    for (0..n_cycles) |ci| {
        var area: f64 = 0;
        for (halves.items[starts.items[ci]..starts.items[ci + 1]], starts.items[ci]..) |h, k| {
            const va = o.origin(h);
            const vb = o.target(h);
            if (vertex_of[va] == .none) vertex_of[va] = try b.vertex(o.points.items[va]);
            if (vertex_of[vb] == .none) vertex_of[vb] = try b.vertex(o.points.items[vb]);
            specs[k] = try edgeSpec(&b, o, h, vertex_of[va], vertex_of[vb]);
            area += areaTerm(o, h);
        }
        areas[ci] = area / 2.0;
    }
    // Each hole's face: the innermost outer cycle containing a point of it
    const owner = try allocator.alloc(u32, n_cycles);
    defer allocator.free(owner);
    var n_faces: usize = 0;
    for (0..n_cycles) |ci| {
        owner[ci] = overlay_mod.UNBOUNDED;
        if (areas[ci] > 0) {
            n_faces += 1;
            continue;
        }
        const probe = insidePoint(o, halves.items[starts.items[ci]]);
        var best = std.math.inf(f64);
        for (0..n_cycles) |oi| {
            if (areas[oi] <= 0 or areas[oi] >= best) continue;
            if (containsPoint(o, halves.items[starts.items[oi]..starts.items[oi + 1]], probe)) {
                best = areas[oi];
                owner[ci] = @intCast(oi);
            }
        }
        if (owner[ci] == overlay_mod.UNBOUNDED) return diag.fail(error.NotValid, .{ .code = .hole_outside_outer, .label = "the result" });
    }
    // The faces: each outer cycle with its holes, on the world plane
    const loops = try allocator.alloc(sew.LoopSpec, n_cycles);
    defer allocator.free(loops);
    const face_specs = try allocator.alloc(sew.FaceSpec, n_faces);
    defer allocator.free(face_specs);
    const plane = try b.plane(geometry.Frame.world);
    var li: usize = 0;
    var fi: usize = 0;
    for (0..n_cycles) |oi| {
        if (areas[oi] <= 0) continue;
        const first = li;
        loops[li] = .{ .edges = specs[starts.items[oi]..starts.items[oi + 1]] };
        li += 1;
        var box = geometry.Box2.empty;
        growBox(&box, o, halves.items[starts.items[oi]..starts.items[oi + 1]]);
        for (0..n_cycles) |hi| {
            if (owner[hi] != oi) continue;
            loops[li] = .{ .edges = specs[starts.items[hi]..starts.items[hi + 1]] };
            li += 1;
        }
        face_specs[fi] = .{ .surface = plane, .loops = loops[first..li], .uv_box = box };
        fi += 1;
    }
    return b.finish(face_specs, .sheet);
}

/// An overlay half-edge as an edge specification of the new sheet: a line through its
/// ends, or its circle interned with the angles of its ends as the range, run the way the
/// half-edge does.
fn edgeSpec(b: *Builder, o: *const Overlay, half: u32, start: types.VertexIndex, end: types.VertexIndex) Error!sew.EdgeSpec {
    const arc = o.arcOf(half) orelse return b.straight(start, end);
    const circle = curves.Circle{ .c = .{ arc.c[0], arc.c[1], 0 }, .x = vec.X3, .y = vec.Y3, .r = arc.r };
    const ref = b.interner.circle(b.allocator, &b.body.geometry, circle) catch |e| return b.fail(e);
    const range = rangeOf(o, half);
    return .{ .start = start, .end = end, .curve = ref, .t0 = range[0], .t1 = range[1], .forward = arc.ccw };
}

/// The circle's parameter range an arc half-edge covers, counter-clockwise from the end
/// the arc starts from that way round.
fn rangeOf(o: *const Overlay, half: u32) [2]f64 {
    const arc = o.arcOf(half).?;
    const pa = o.point(o.origin(half));
    const pb = o.point(o.target(half));
    const ta = std.math.atan2(pa[1] - arc.c[1], pa[0] - arc.c[0]);
    const tb = std.math.atan2(pb[1] - arc.c[1], pb[0] - arc.c[0]);
    const from = if (arc.ccw) ta else tb;
    var to = if (arc.ccw) tb else ta;
    if (to <= from + ANGLE_SLACK) to += 2 * std.math.pi;
    return .{ from, to };
}

/// Twice a half-edge's share of its cycle's area, as the overlay reckons it.
fn areaTerm(o: *const Overlay, half: u32) f64 {
    const a = o.point(o.origin(half));
    const b = o.point(o.target(half));
    var twice = a[0] * b[1] - b[0] * a[1];
    if (o.arcOf(half)) |arc| {
        const range = rangeOf(o, half);
        const theta = range[1] - range[0];
        const segment = arc.r * arc.r * (theta - @sin(theta));
        twice += if (arc.ccw) segment else -segment;
    }
    return twice;
}

/// A point just to the left of a half-edge's middle: a few zones in, for a hole into the
/// face about it.
fn insidePoint(o: *const Overlay, half: u32) Vec2 {
    const a = o.point(o.origin(half));
    const b = o.point(o.target(half));
    var middle = vec.scale2(vec.add2(a, b), 0.5);
    var tangent = vec.normalized2(vec.sub2(b, a)) orelse Vec2{ 1, 0 };
    if (o.arcOf(half)) |arc| {
        const range = rangeOf(o, half);
        const angle = (range[0] + range[1]) / 2.0;
        middle = vec.addScaled2(arc.c, .{ @cos(angle), @sin(angle) }, arc.r);
        const radial = vec.sub2(middle, arc.c);
        tangent = vec.normalized2(if (arc.ccw) Vec2{ -radial[1], radial[0] } else Vec2{ radial[1], -radial[0] }).?;
    }
    return vec.addScaled2(middle, .{ -tangent[1], tangent[0] }, PROBE_ZONES * o.tol.zone);
}

/// Whether `p` is inside the cycle of `halves`, by the ray to +x.
fn containsPoint(o: *const Overlay, halves: []const u32, p: Vec2) bool {
    var inside = false;
    for (halves) |h| {
        const a = o.point(o.origin(h));
        const b = o.point(o.target(h));
        if (o.arcOf(h)) |arc| {
            inside = inside != overlay_mod.arcCrossings(a, b, arc, p);
        } else if ((a[1] > p[1]) != (b[1] > p[1])) {
            const x = a[0] + (p[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1]);
            if (p[0] < x) inside = !inside;
        }
    }
    return inside;
}

/// The UV box of a cycle on the world plane: its ends and its arcs' extreme points.
fn growBox(box: *geometry.Box2, o: *const Overlay, halves: []const u32) void {
    for (halves) |h| {
        box.grow(o.point(o.origin(h)));
        if (o.arcOf(h)) |arc| {
            const circle = curves.Circle{ .c = .{ arc.c[0], arc.c[1], 0 }, .x = vec.X3, .y = vec.Y3, .r = arc.r };
            const range = rangeOf(o, h);
            const b3 = circle.bounds(range[0], range[1]);
            box.grow(.{ b3.min[0], b3.min[1] });
            box.grow(.{ b3.max[0], b3.max[1] });
        }
    }
}

fn mapError(diag: *Diagnostics, err: anyerror) Error {
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
