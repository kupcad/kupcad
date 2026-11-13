//! The offset of a sketch (docs/architecture.md §7.5, D25): the sheet grown by `delta`
//! is the sheet united with the band its boundary sweeps; shrunk, the sheet less that
//! band. The band is a union of simple regions: each edge's sweep (a line's rectangle; an
//! arc's annular sector between it and its concentric offset, or, when the offset passes
//! the centre, the pie to the centre and the reflected pie beyond it) and, at each corner
//! that opens on the offset side, the join asked for (a pie about the corner, a chord, the
//! offset lines' meeting point within the miter limit, or a cap at the offset distance).
//! The sheet is one input of the overlay and the band's regions another, so a face lies
//! in the band where that input's winding is positive. The classic recipe, the outline
//! displaced and filled by its winding, is wrong where a feature is thinner than the
//! offset: a sliver shrunk past its width turns its outline inside out with positive
//! winding and leaves a region where it should vanish (the fuzzer, 2026-11-08). A
//! positive `delta` grows the region, a negative one shrinks it (to nothing, past its
//! half-width).

const std = @import("std");
const vec = @import("../math/vec.zig");
const diagnostics = @import("../diagnostics.zig");
const trace = @import("../io/trace.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const overlay_mod = @import("overlay.zig");
const boolean = @import("boolean.zig");
const Body = body_mod.Body;
const Overlay = overlay_mod.Overlay;
const Arc = overlay_mod.Arc;
const InputEdge = overlay_mod.InputEdge;
const Vec2 = vec.Vec2;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

pub const Join = enum { round, miter, bevel, square };

/// The least a miter may be limited to, in multiples of the offset (what the scripts get).
pub const LEAST_MITER_LIMIT: f64 = 2;
/// How small the cross of two unit directions is before they are taken as parallel.
const PARALLEL: f64 = 1e-12;
/// The overlay's input the sheet is, and the one the band is.
const SHEET: u32 = 0;
const BAND: u32 = 1;

/// The sheet grown by `delta` (shrunk when negative); `miter_limit` times `delta` is how
/// far a miter may reach before it is squared off. The input is untouched.
pub fn offset(allocator: std.mem.Allocator, sheet: *const Body, delta: f64, join: Join, miter_limit: f64, options: diagnostics.Options, diag: *Diagnostics) Error!Body {
    try diagnostics.input.finite(diag, "delta", delta);
    try diagnostics.input.finite(diag, "miter_limit", miter_limit);
    try options.checkCancel();
    try trace.arguments(allocator, &options, "offset", .{ .delta = delta, .join = join, .miter_limit = miter_limit });
    if (sheet.kind != .sheet) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "the sketch: a sheet" });
    const tol = options.tolerance orelse sheet.tol;
    if (@abs(delta) <= tol.zone) return sheet.clone(allocator) catch return error.OutOfMemory;
    var o = Overlay.init(allocator, tol);
    defer o.deinit();
    _ = o.addInput() catch |e| return boolean.mapError(diag, e);
    try boolean.addSheet(&o, sheet, diag);
    _ = o.addInput() catch |e| return boolean.mapError(diag, e);
    var band: Band = .{ .o = &o, .delta = delta, .join = join, .miter_limit = @max(miter_limit, LEAST_MITER_LIMIT), .zone = tol.zone, .diag = diag };
    var pieces = std.ArrayList(Piece).empty;
    defer pieces.deinit(allocator);
    var shells = traverse.Shells.init(sheet);
    while (shells.next() catch return corrupt(diag)) |s| {
        var faces = traverse.Faces.init(sheet, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            var loops = traverse.Loops.init(sheet, f);
            while (loops.next() catch return corrupt(diag)) |l| {
                try options.checkCancel();
                pieces.clearRetainingCapacity();
                try loopPieces(allocator, sheet, l, &pieces, diag);
                try band.loop(pieces.items);
            }
        }
    }
    try options.checkCancel();
    o.run() catch |e| return boolean.mapError(diag, e);
    const keep = try allocator.alloc(bool, o.faces.items.len);
    defer allocator.free(keep);
    for (keep, 0..) |*k, f| {
        const in_sheet = o.windingOf(@intCast(f), SHEET) != 0;
        const in_band = o.windingOf(@intCast(f), BAND) > 0;
        k.* = if (delta > 0) in_sheet or in_band else in_sheet and !in_band;
    }
    return boolean.build(allocator, tol, &o, keep, diag);
}

/// An edge of a loop as the loop runs it: from `a` to `b`, straight or an arc.
const Piece = struct {
    a: Vec2,
    b: Vec2,
    arc: ?Arc,

    /// The unit tangent at the start and at the end, the way the piece runs.
    fn startTangent(self: Piece) Vec2 {
        if (self.arc) |arc| return arcTangent(self.a, arc);
        return vec.normalized2(vec.sub2(self.b, self.a)) orelse .{ 1, 0 };
    }

    fn endTangent(self: Piece) Vec2 {
        if (self.arc) |arc| return arcTangent(self.b, arc);
        return vec.normalized2(vec.sub2(self.b, self.a)) orelse .{ 1, 0 };
    }
};

fn arcTangent(p: Vec2, arc: Arc) Vec2 {
    const radial = vec.normalized2(vec.sub2(p, arc.c)) orelse return .{ 1, 0 };
    return if (arc.ccw) vec.perp2(radial) else vec.scale2(vec.perp2(radial), -1);
}

/// The loop's edges as pieces in its order, appended to `pieces` (which `allocator` owns).
fn loopPieces(allocator: std.mem.Allocator, sheet: *const Body, l: anytype, pieces: *std.ArrayList(Piece), diag: *Diagnostics) Error!void {
    var it = traverse.Coedges.init(sheet, l);
    while (it.next() catch return corrupt(diag)) |c| {
        const coedge = sheet.coedge(c);
        const e = sheet.edge(coedge.edge);
        const a = flat(sheet.point(sheet.coedgeStart(c)));
        const b = flat(sheet.point(sheet.coedgeEnd(c)));
        const piece: Piece = switch (sheet.geometry.curve(e.curve)) {
            .line => .{ .a = a, .b = b, .arc = null },
            .circle => |circle| .{ .a = a, .b = b, .arc = .{ .c = flat(circle.c), .r = circle.r, .ccw = (circle.normal()[2] > 0) == coedge.same_sense } },
            else => return diag.fail(error.NotRepresentable, .{ .code = .not_implemented, .entity = .of(.edge, @backingInt(coedge.edge)), .label = "a sketch edge that is neither a line nor an arc" }),
        };
        try pieces.append(allocator, piece);
    }
}

fn flat(p: vec.Vec3) Vec2 {
    return .{ p[0], p[1] };
}

/// The band a boundary sweeps, as regions of the overlay's current input: every region a
/// closed loop of edges running counter-clockwise, so the input's winding counts how
/// many regions cover a face and is positive on the band.
const Band = struct {
    o: *Overlay,
    delta: f64,
    join: Join,
    miter_limit: f64,
    zone: f64,
    diag: *Diagnostics,

    /// The sweeps of a loop's pieces and the joins at its corners.
    fn loop(self: *Band, pieces: []const Piece) Error!void {
        for (pieces, 0..) |piece, i| {
            try self.sweep(piece);
            try self.corner(piece, pieces[(i + 1) % pieces.len]);
        }
    }

    /// The points within the offset of the piece on the offset side (the region's right
    /// for a positive delta, its left for a negative one): a line's rectangle; an arc's
    /// annular sector between it and its concentric offset, or, when the offset passes
    /// the centre, the pie to the centre and the reflected pie beyond it (the points
    /// past the centre nearer the arc than the offset along the ray through it).
    fn sweep(self: *Band, piece: Piece) Error!void {
        const delta = self.delta;
        // Each loop below runs the piece its own way with the sweep on its left: that is
        // counter-clockwise when the sweep is on the left, else it is turned around
        const forward = delta < 0;
        if (piece.arc) |arc| {
            // The region is inside a counter-clockwise arc's circle, outside a clockwise
            // one's; the moved radius is signed, negative past the centre
            const radius = if (arc.ccw) arc.r + delta else arc.r - delta;
            const a_moved = vec.addScaled2(arc.c, vec.sub2(piece.a, arc.c), radius / arc.r);
            const b_moved = vec.addScaled2(arc.c, vec.sub2(piece.b, arc.c), radius / arc.r);
            if (radius > self.zone) {
                try self.region(&.{
                    .{ .a = piece.a, .b = piece.b, .arc = arc },
                    .{ .a = piece.b, .b = b_moved },
                    .{ .a = b_moved, .b = a_moved, .arc = .{ .c = arc.c, .r = radius, .ccw = !arc.ccw } },
                    .{ .a = a_moved, .b = piece.a },
                }, forward);
                return;
            }
            try self.region(&.{
                .{ .a = piece.a, .b = piece.b, .arc = arc },
                .{ .a = piece.b, .b = arc.c },
                .{ .a = arc.c, .b = piece.a },
            }, forward);
            if (-radius > self.zone) {
                try self.region(&.{
                    .{ .a = arc.c, .b = a_moved },
                    .{ .a = a_moved, .b = b_moved, .arc = .{ .c = arc.c, .r = -radius, .ccw = arc.ccw } },
                    .{ .a = b_moved, .b = arc.c },
                }, forward);
            }
            return;
        }
        const right = vec.scale2(vec.perp2(piece.startTangent()), -1);
        const a_moved = vec.addScaled2(piece.a, right, delta);
        const b_moved = vec.addScaled2(piece.b, right, delta);
        try self.region(&.{
            .{ .a = piece.a, .b = piece.b },
            .{ .a = piece.b, .b = b_moved },
            .{ .a = b_moved, .b = a_moved },
            .{ .a = a_moved, .b = piece.a },
        }, forward);
    }

    /// The join at the corner `piece` and `next` share, where the turn opens a gap
    /// between their sweeps on the offset side; where they cross, the sweeps overlap
    /// and nothing is needed.
    fn corner(self: *Band, piece: Piece, next: Piece) Error!void {
        const delta = self.delta;
        const t1 = piece.endTangent();
        const t2 = next.startTangent();
        const turn = vec.cross2(t1, t2);
        if (turn * delta <= 0) return;
        const v = piece.b;
        const end1 = vec.addScaled2(v, vec.scale2(vec.perp2(t1), -1), delta);
        const start2 = vec.addScaled2(v, vec.scale2(vec.perp2(t2), -1), delta);
        if (vec.distance2(end1, start2) <= self.zone) return;
        // Each loop below runs from the corner out to the end of the first sweep, across
        // to the start of the next and back: counter-clockwise when the gap is on the
        // region's right, else turned around
        const forward = delta > 0;
        switch (self.join) {
            .round => try self.region(&.{
                .{ .a = v, .b = end1 },
                .{ .a = end1, .b = start2, .arc = .{ .c = v, .r = @abs(delta), .ccw = turn > 0 } },
                .{ .a = start2, .b = v },
            }, forward),
            .bevel => try self.region(&.{ .{ .a = v, .b = end1 }, .{ .a = end1, .b = start2 }, .{ .a = start2, .b = v } }, forward),
            .miter => {
                // The offset lines' meeting point, when within the limit; a cap otherwise
                if (linesMeet(end1, t1, start2, t2)) |meet| {
                    if (vec.distance2(meet, v) <= self.miter_limit * @abs(delta)) {
                        try self.region(&.{ .{ .a = v, .b = end1 }, .{ .a = end1, .b = meet }, .{ .a = meet, .b = start2 }, .{ .a = start2, .b = v } }, forward);
                        return;
                    }
                }
                try self.squareCap(v, end1, t1, start2, t2, forward);
            },
            .square => try self.squareCap(v, end1, t1, start2, t2, forward),
        }
    }

    /// The corner capped: the line at the offset distance from the corner along the
    /// bisector of the two offsets, between its crossings with the offset lines extended.
    fn squareCap(self: *Band, v: Vec2, end1: Vec2, t1: Vec2, start2: Vec2, t2: Vec2, forward: bool) Error!void {
        const bisector = vec.normalized2(vec.add2(vec.sub2(end1, v), vec.sub2(start2, v))) orelse {
            try self.region(&.{ .{ .a = v, .b = end1 }, .{ .a = end1, .b = start2 }, .{ .a = start2, .b = v } }, forward);
            return;
        };
        const on_cap = vec.addScaled2(v, bisector, @abs(self.delta));
        const along_cap = vec.perp2(bisector);
        const c1 = linesMeet(end1, t1, on_cap, along_cap) orelse end1;
        const c2 = linesMeet(start2, t2, on_cap, along_cap) orelse start2;
        try self.region(&.{ .{ .a = v, .b = end1 }, .{ .a = end1, .b = c1 }, .{ .a = c1, .b = c2 }, .{ .a = c2, .b = start2 }, .{ .a = start2, .b = v } }, forward);
    }

    /// A region as the closed loop `edges`: as given when `forward`, else each edge
    /// turned around in the opposite order. An edge whose ends weld to one vertex is
    /// nothing (the overlay drops it), so a loop may have degenerate edges.
    fn region(self: *Band, edges: []const InputEdge, forward: bool) Error!void {
        if (forward) {
            for (edges) |e| try self.edge(e);
            return;
        }
        var i = edges.len;
        while (i > 0) {
            i -= 1;
            const e = edges[i];
            const arc: ?Arc = if (e.arc) |arc| .{ .c = arc.c, .r = arc.r, .ccw = !arc.ccw } else null;
            try self.edge(.{ .a = e.b, .b = e.a, .arc = arc });
        }
    }

    fn edge(self: *Band, e: InputEdge) Error!void {
        self.o.addEdge(e) catch |err| return boolean.mapError(self.diag, err);
    }
};

/// Where the line through `p` along `u` meets the one through `q` along `v`; null when
/// parallel.
fn linesMeet(p: Vec2, u: Vec2, q: Vec2, v: Vec2) ?Vec2 {
    const denominator = vec.cross2(u, v);
    if (@abs(denominator) <= PARALLEL) return null;
    const t = vec.cross2(vec.sub2(q, p), v) / denominator;
    return vec.addScaled2(p, u, t);
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the sketch" });
}
