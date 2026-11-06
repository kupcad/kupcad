//! The offset of a sketch (docs/architecture.md §7.5): every edge moved by `delta` to the
//! region's right (a line to a parallel line, an arc to a concentric one, its radius grown
//! where the region is inside its circle and shrunk where outside; an arc shrunk to
//! nothing is its centre), the corners that open joined as asked (an arc about the corner,
//! the offset lines' meeting point within the miter limit, a chord, or a cap at the offset
//! distance), the corners that cross connected as they are, and the raw outline resolved
//! by the overlay with the positive fill, which drops the inverted bits a crossing makes.
//! A positive `delta` grows the region, a negative one shrinks it (to nothing, past its
//! half-width).

const std = @import("std");
const vec = @import("../math/vec.zig");
const diagnostics = @import("../diagnostics.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const overlay_mod = @import("overlay.zig");
const boolean = @import("boolean.zig");
const Body = body_mod.Body;
const Overlay = overlay_mod.Overlay;
const Arc = overlay_mod.Arc;
const Vec2 = vec.Vec2;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

pub const Join = enum { round, miter, bevel, square };

/// The least a miter may be limited to, in multiples of the offset (what the scripts get).
pub const LEAST_MITER_LIMIT: f64 = 2;

/// The sheet grown by `delta` (shrunk when negative); `miter_limit` times `delta` is how
/// far a miter may reach before it is squared off. The input is untouched.
pub fn offset(allocator: std.mem.Allocator, sheet: *const Body, delta: f64, join: Join, miter_limit: f64, options: diagnostics.Options, diag: *Diagnostics) Error!Body {
    try diagnostics.input.finite(diag, "delta", delta);
    try diagnostics.input.finite(diag, "miter_limit", miter_limit);
    try options.checkCancel();
    if (sheet.kind != .sheet) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "the sketch: a sheet" });
    const tol = options.tolerance orelse sheet.tol;
    if (@abs(delta) <= tol.zone) return sheet.clone(allocator) catch return error.OutOfMemory;
    var o = Overlay.init(allocator, tol);
    defer o.deinit();
    _ = o.addInput() catch |e| return boolean.mapError(diag, e);
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
                try loopPieces(sheet, l, &pieces, diag);
                const moved = try allocator.alloc(Piece, pieces.items.len);
                defer allocator.free(moved);
                for (pieces.items, moved) |piece, *m| m.* = movePiece(piece, delta, tol.zone);
                try emitLoop(&o, moved, delta, join, @max(miter_limit, LEAST_MITER_LIMIT), tol.zone, diag);
            }
        }
    }
    try options.checkCancel();
    o.run() catch |e| return boolean.mapError(diag, e);
    const keep = try allocator.alloc(bool, o.faces.items.len);
    defer allocator.free(keep);
    for (keep, 0..) |*k, f| k.* = o.windingOf(@intCast(f), 0) > 0;
    return boolean.build(allocator, tol, &o, keep, diag);
}

/// An edge of a loop as the loop runs it: from `a` to `b`, straight or an arc; a piece
/// whose arc has shrunk to nothing is the point `a == b`.
const Piece = struct {
    a: Vec2,
    b: Vec2,
    arc: ?Arc,

    fn isPoint(self: Piece) bool {
        return self.arc == null and self.a[0] == self.b[0] and self.a[1] == self.b[1];
    }

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

/// The loop's edges as pieces in its order.
fn loopPieces(sheet: *const Body, l: anytype, pieces: *std.ArrayList(Piece), diag: *Diagnostics) Error!void {
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
        try pieces.append(sheet.allocator, piece);
    }
}

fn flat(p: vec.Vec3) Vec2 {
    return .{ p[0], p[1] };
}

/// The piece moved by `delta` to its right: the region's outside for a positive delta.
fn movePiece(piece: Piece, delta: f64, zone: f64) Piece {
    if (piece.arc) |arc| {
        // The region is inside a counter-clockwise arc's circle, outside a clockwise one's
        const radius = if (arc.ccw) arc.r + delta else arc.r - delta;
        if (radius <= zone) return .{ .a = arc.c, .b = arc.c, .arc = null };
        const scale = radius / arc.r;
        return .{
            .a = vec.addScaled2(arc.c, vec.sub2(piece.a, arc.c), scale),
            .b = vec.addScaled2(arc.c, vec.sub2(piece.b, arc.c), scale),
            .arc = .{ .c = arc.c, .r = radius, .ccw = arc.ccw },
        };
    }
    const right = vec.scale2(vec.perp2(piece.startTangent()), -1);
    return .{ .a = vec.addScaled2(piece.a, right, delta), .b = vec.addScaled2(piece.b, right, delta), .arc = null };
}

/// The moved pieces of one loop as the overlay's edges, joined at the corners: where the
/// turn and the delta open a gap, the join asked for; where they cross, the ends connected
/// straight (the overlay's positive fill drops the inverted bit).
fn emitLoop(o: *Overlay, moved: []const Piece, delta: f64, join: Join, miter_limit: f64, zone: f64, diag: *Diagnostics) Error!void {
    for (moved, 0..) |piece, i| {
        if (!piece.isPoint()) o.addEdge(.{ .a = piece.a, .b = piece.b, .arc = piece.arc }) catch |e| return boolean.mapError(diag, e);
        const next = moved[(i + 1) % moved.len];
        if (vec.distance2(piece.b, next.a) <= zone) continue;
        // The corner: the original ends met at `corner`; the offset ends are `delta` from it
        if (piece.isPoint() or next.isPoint()) {
            try straight(o, piece.b, next.a, diag);
            continue;
        }
        const t1 = piece.endTangent();
        const t2 = next.startTangent();
        const turn = vec.cross2(t1, t2);
        const corner = vec.addScaled2(piece.b, vec.scale2(vec.perp2(t1), -1), -delta);
        if (turn * delta <= 0 or @abs(turn) <= zone) {
            try straight(o, piece.b, next.a, diag);
            continue;
        }
        switch (join) {
            .round => o.addEdge(.{ .a = piece.b, .b = next.a, .arc = .{ .c = corner, .r = @abs(delta), .ccw = turn > 0 } }) catch |e| return boolean.mapError(diag, e),
            .bevel => try straight(o, piece.b, next.a, diag),
            .miter => {
                // The offset lines' meeting point, when within the limit; a cap otherwise
                if (linesMeet(piece.b, t1, next.a, t2)) |meet| {
                    if (vec.distance2(meet, corner) <= miter_limit * @abs(delta)) {
                        try straight(o, piece.b, meet, diag);
                        try straight(o, meet, next.a, diag);
                        continue;
                    }
                }
                try squareCap(o, piece.b, t1, next.a, t2, corner, delta, diag);
            },
            .square => try squareCap(o, piece.b, t1, next.a, t2, corner, delta, diag),
        }
    }
}

fn straight(o: *Overlay, a: Vec2, b: Vec2, diag: *Diagnostics) Error!void {
    o.addEdge(.{ .a = a, .b = b }) catch |e| return boolean.mapError(diag, e);
}

/// A cap across the corner: the line at the offset distance from the corner along the
/// bisector of the two offsets, between its crossings with the offset lines extended.
fn squareCap(o: *Overlay, end1: Vec2, t1: Vec2, start2: Vec2, t2: Vec2, corner: Vec2, delta: f64, diag: *Diagnostics) Error!void {
    const bisector = vec.normalized2(vec.add2(vec.sub2(end1, corner), vec.sub2(start2, corner))) orelse {
        try straight(o, end1, start2, diag);
        return;
    };
    const on_cap = vec.addScaled2(corner, bisector, @abs(delta));
    const along_cap = vec.perp2(bisector);
    const c1 = linesMeet(end1, t1, on_cap, along_cap) orelse end1;
    const c2 = linesMeet(start2, t2, on_cap, along_cap) orelse start2;
    try straight(o, end1, c1, diag);
    try straight(o, c1, c2, diag);
    try straight(o, c2, start2, diag);
}

/// Where the line through `p` along `u` meets the one through `q` along `v`; null when
/// parallel.
fn linesMeet(p: Vec2, u: Vec2, q: Vec2, v: Vec2) ?Vec2 {
    const denominator = vec.cross2(u, v);
    if (@abs(denominator) <= PARALLEL) return null;
    const t = vec.cross2(vec.sub2(q, p), v) / denominator;
    return vec.addScaled2(p, u, t);
}

/// How small the cross of two unit directions is before they are taken as parallel.
const PARALLEL: f64 = 1e-12;

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the sketch" });
}
