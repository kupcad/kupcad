//! Certified chords of free-form edges (docs/architecture.md §7.7, KNOWLEDGE §9;
//! research/opengeometry.md §3, §6): the parameters at which an ellipse or a NURBS edge is
//! cut so that every span bows from its chord by no more than the resolution lets a
//! circle's segment bow (`Resolution.chordBow`), decided from an **enclosure** of the
//! span, never from points sampled on it (a bulge between samples is then missed). An
//! ellipse's span is enclosed by interval arithmetic on `c + a cos t x + b sin t y`
//! (`math/interval.zig`); a NURBS span by the convex hull of the Bézier control points of
//! that very span (A5.6 decomposition, then de Casteljau subdivision in homogeneous
//! coordinates, whose hull holds the curve for positive weights). Each span is tested in
//! a frame along its chord (how far the enclosure reaches across the chord, and past its
//! ends), halved until it passes, and the halves' ends are the samples; a span that
//! does not pass within `MAX_DEPTH` halvings (a cusp, a loop smaller than the chord's
//! budget) is refused with a finding, never sampled and hoped for.

const std = @import("std");
const vec = @import("../math/vec.zig");
const interval = @import("../math/interval.zig");
const curves = @import("../geometry/curves.zig");
const nurbs = @import("../geometry/nurbs.zig");
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;
const Interval = interval.Interval;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// How often a span may be halved: a curve whose spans never pass by then has a feature
/// the chord budget cannot hold (a cusp, a loop), and is refused.
pub const MAX_DEPTH: u8 = 24;
/// The most spans one edge gets: a refusal past it, not a mesh of a million chords.
pub const MAX_SPANS: usize = 1 << 16;

/// Appends to `out`, in increasing order, the parameters strictly between `t0` and `t1`
/// at which the edge on `curve` is cut: none for a line or a circle (those have their
/// own grids, `edges.zig`), the knots inside the range and the halvings for a NURBS, the
/// halvings for an ellipse. `error.LimitExceeded` with a finding on `entity` when a span
/// cannot be certified.
pub fn sampleParams(allocator: std.mem.Allocator, curve: curves.Curve, t0: f64, t1: f64, resolution: tolerance.Resolution, out: *std.ArrayList(f64), diag: *Diagnostics, entity: diagnostics.EntityRef) Error!void {
    std.debug.assert(t0 < t1);
    switch (curve) {
        .line, .circle => {},
        .ellipse => |e| {
            var spans: usize = 1;
            try refine(EllipseSpan{ .ellipse = e }, t0, t1, 0, resolution, allocator, out, &spans, diag, entity);
        },
        .nurbs => |n| {
            const segments = try n.decompose(allocator);
            defer {
                for (segments) |s| allocator.free(s);
                allocator.free(segments);
            }
            const distinct = try distinctKnots(allocator, n);
            defer allocator.free(distinct);
            var span = BezierSpan{ .curve = n, .segments = segments, .knots = distinct };
            var spans: usize = 1;
            var a = t0;
            for (distinct[1 .. distinct.len - 1]) |knot| {
                if (knot <= t0 or knot >= t1) continue;
                try refine(&span, a, knot, 0, resolution, allocator, out, &spans, diag, entity);
                try out.append(allocator, knot);
                a = knot;
            }
            try refine(&span, a, t1, 0, resolution, allocator, out, &spans, diag, entity);
        },
    }
}

/// Halves `[a, b]` until each piece's enclosure lies within the chord's budget, the
/// halving points appended in order.
fn refine(ctx: anytype, a: f64, b: f64, depth: u8, resolution: tolerance.Resolution, allocator: std.mem.Allocator, out: *std.ArrayList(f64), spans: *usize, diag: *Diagnostics, entity: diagnostics.EntityRef) Error!void {
    if (passes(ctx, a, b, resolution)) return;
    if (depth >= MAX_DEPTH) return diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .entity = entity, .label = "the halvings of a free-form edge's span (no chord within the resolution)", .measured = @floatFromInt(depth), .threshold = @floatFromInt(MAX_DEPTH) });
    spans.* += 1;
    if (spans.* > MAX_SPANS) return diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .entity = entity, .label = "the chords of a free-form edge", .measured = @floatFromInt(spans.*), .threshold = @floatFromInt(MAX_SPANS) });
    const mid = 0.5 * (a + b);
    try refine(ctx, a, mid, depth + 1, resolution, allocator, out, spans, diag, entity);
    try out.append(allocator, mid);
    try refine(ctx, mid, b, depth + 1, resolution, allocator, out, spans, diag, entity);
}

/// The frame of a chord: from `origin` along the unit `dir`, `n1` and `n2` across it.
const ChordFrame = struct {
    origin: Vec3,
    dir: Vec3,
    n1: Vec3,
    n2: Vec3,
    length: f64,

    fn of(pa: Vec3, pb: Vec3) ?ChordFrame {
        const d = vec.sub(pb, pa);
        const dir = vec.normalized(d) orelse return null;
        const n1 = vec.perpendicular(dir);
        return .{ .origin = pa, .dir = dir, .n1 = n1, .n2 = vec.cross(dir, n1), .length = vec.length(d) };
    }
};

/// How far an enclosure reaches: along the chord (an interval from its start) and across
/// it (a bound on the distance from the chord's line).
const Reach = struct { along: Interval, across: f64 };

/// Whether the span's enclosure lies within the chord's budget: no farther across than
/// the bow the resolution allows a chord of this length, and no farther past either end.
fn passes(ctx: anytype, a: f64, b: f64, resolution: tolerance.Resolution) bool {
    const pa = ctx.point(a);
    const pb = ctx.point(b);
    const frame = ChordFrame.of(pa, pb) orelse return false;
    const budget = resolution.chordBow(frame.length);
    const reach = ctx.reach(a, b, frame);
    return reach.across <= budget and reach.along.lo >= -budget and reach.along.hi <= frame.length + budget;
}

/// A span of an ellipse, enclosed by interval arithmetic in the mean-value form: along
/// each frame axis `n`, `(P(t) − P(a))·n = (t − a)·P'(ξ)·n` for some `ξ` in the span, and
/// `P'(ξ)·n = −a sin ξ (x·n) + b cos ξ (y·n)` is an interval over the span. (The plain
/// form, `P(t)·n` as an interval less `P(a)·n`, cannot see the two terms cancel along
/// the chord and shrinks only linearly with the span, never under the budget.)
const EllipseSpan = struct {
    ellipse: curves.Ellipse,

    fn point(self: EllipseSpan, t: f64) Vec3 {
        return self.ellipse.eval(t);
    }

    fn reach(self: EllipseSpan, a: f64, b: f64, frame: ChordFrame) Reach {
        const range = Interval.span(a, b);
        const cos = range.cos();
        const sin = range.sin();
        const width = Interval.span(0, b - a);
        const along = width.mul(self.slope(frame.dir, cos, sin));
        const p1 = width.mul(self.slope(frame.n1, cos, sin));
        const p2 = width.mul(self.slope(frame.n2, cos, sin));
        return .{ .along = along, .across = @sqrt(farthest(p1) * farthest(p1) + farthest(p2) * farthest(p2)) };
    }

    /// `P'(ξ)·axis` over the span.
    fn slope(self: EllipseSpan, axis: Vec3, cos: Interval, sin: Interval) Interval {
        const e = self.ellipse;
        return sin.scale(-e.a * vec.dot(e.x, axis)).add(cos.scale(e.b * vec.dot(e.y, axis)));
    }
};

fn farthest(i: Interval) f64 {
    return @max(@abs(i.lo), @abs(i.hi));
}

/// A span of a NURBS curve, enclosed by the hull of the Bézier control points of the
/// piece (one knot span holds each piece refined here; `sampleParams` splits at knots).
const BezierSpan = struct {
    curve: nurbs.Curve,
    /// The Bézier segments of the curve, one per distinct knot interval (A5.6).
    segments: []const []const Vec4,
    /// The distinct knots, `segments.len + 1` of them.
    knots: []const f64,

    fn point(self: *const BezierSpan, t: f64) Vec3 {
        return self.curve.eval(t);
    }

    fn reach(self: *const BezierSpan, a: f64, b: f64, frame: ChordFrame) Reach {
        const i = self.segmentOf(0.5 * (a + b));
        const lo = self.knots[i];
        const hi = self.knots[i + 1];
        const p = self.curve.degree;
        var poly: [nurbs.MAX_DEGREE + 1]Vec4 = undefined;
        @memcpy(poly[0 .. p + 1], self.segments[i]);
        // The piece's own control points: the part from `a` on, then the part up to `b`;
        // then the hulls of its two halves, each still holding its half of the curve and
        // together twice as tight as the piece's own (a quadratic arc's apex control
        // point stands twice its sagitta off the chord, the halves' points about once)
        if (a > lo) poly = rightOf(poly, p, (a - lo) / (hi - lo));
        if (b < hi) poly = leftOf(poly, p, (b - a) / (hi - a));
        var out: Reach = .{ .along = Interval.of(0), .across = 0 };
        for ([2][nurbs.MAX_DEGREE + 1]Vec4{ leftOf(poly, p, 0.5), rightOf(poly, p, 0.5) }) |half| {
            for (half[0 .. p + 1]) |q| {
                const d = vec.sub(vec.project4(q), frame.origin);
                out.along = Interval.hull(out.along, Interval.of(vec.dot(d, frame.dir)));
                const c1 = vec.dot(d, frame.n1);
                const c2 = vec.dot(d, frame.n2);
                out.across = @max(out.across, @sqrt(c1 * c1 + c2 * c2));
            }
        }
        return out;
    }

    /// The segment whose knot interval holds `t` (the last for `t` at the end).
    fn segmentOf(self: *const BezierSpan, t: f64) usize {
        var i: usize = 0;
        while (i + 2 < self.knots.len and t >= self.knots[i + 1]) : (i += 1) {}
        return i;
    }
};

/// De Casteljau at `s`: the control points of the part of the Bézier piece from `s` on.
fn rightOf(poly: [nurbs.MAX_DEGREE + 1]Vec4, p: usize, s: f64) [nurbs.MAX_DEGREE + 1]Vec4 {
    var tri = poly;
    var right: [nurbs.MAX_DEGREE + 1]Vec4 = undefined;
    right[p] = tri[p];
    var k: usize = 1;
    while (k <= p) : (k += 1) {
        var i: usize = 0;
        while (i <= p - k) : (i += 1) tri[i] = vec.add4(vec.scale4(tri[i], 1.0 - s), vec.scale4(tri[i + 1], s));
        right[p - k] = tri[p - k];
    }
    return right;
}

/// De Casteljau at `s`: the control points of the part of the Bézier piece up to `s`.
fn leftOf(poly: [nurbs.MAX_DEGREE + 1]Vec4, p: usize, s: f64) [nurbs.MAX_DEGREE + 1]Vec4 {
    var tri = poly;
    var left: [nurbs.MAX_DEGREE + 1]Vec4 = undefined;
    left[0] = tri[0];
    var k: usize = 1;
    while (k <= p) : (k += 1) {
        var i: usize = 0;
        while (i <= p - k) : (i += 1) tri[i] = vec.add4(vec.scale4(tri[i], 1.0 - s), vec.scale4(tri[i + 1], s));
        left[k] = tri[0];
    }
    return left;
}

/// The curve's distinct knots over its domain, in order. Owned by `allocator`.
fn distinctKnots(allocator: std.mem.Allocator, curve: nurbs.Curve) Error![]f64 {
    const p = curve.degree;
    var out: std.ArrayList(f64) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, curve.knots[p]);
    for (curve.knots[p + 1 .. curve.points.len + 1]) |k| {
        if (k > out.items[out.items.len - 1]) try out.append(allocator, k);
    }
    return out.toOwnedSlice(allocator);
}
