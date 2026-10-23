//! B-splines in the plane, as a drawing gives them (a DXF `SPLINE`): `Spline`, read
//! by its blossoms (the polar form, de Boor's algorithm with a parameter of its own at
//! each step) and drawn as path segments, exactly where a cubic can be one.

const std = @import("std");
const path = @import("path.zig");
const bezier = @import("bezier.zig");

/// The highest degree read: AutoCAD draws up to 11; the evaluation takes as many points as
/// the degree, and a corrupt file shouldn't ask for millions.
pub const MAX_DEGREE = 32;
/// How many times a knot span is halved at most, fitting its cubics.
const MAX_DEPTH = 16;
/// Where along a fitted cubic (its parameter) it is held to the spline.
const FIT_CHECKS = [_]f64{ 0.25, 0.5, 0.75 };

/// A B-spline of `degree` over `knots` (as many as its control points and its degree and
/// one more), rational when it has `weights`.
pub const Spline = struct {
    degree: usize,
    knots: []const f64,
    controls: []const [2]f64,
    weights: ?[]const f64,

    /// Its pieces from its first knot span's start to its last's end, appended to
    /// `segments`, and where they start (null for a spline of no span): a span of a
    /// polynomial one of degree 3 at most as it is (`bezierOf`), any other as fitted
    /// cubics (`appendFitted`). Pieces of no length are left out.
    pub fn appendSegments(self: Spline, allocator: std.mem.Allocator, segments: *std.ArrayList(path.Segment), tolerance: f64) !?[2]f64 {
        var start: ?[2]f64 = null;
        var from: [2]f64 = undefined;
        for (self.degree..self.controls.len) |span| {
            const t0 = self.knots[span];
            const t1 = self.knots[span + 1];
            if (t1 <= t0) continue;
            if (start == null) {
                from = self.evaluate(span, t0)[0];
                start = from;
            }
            const to = self.evaluate(span, t1)[0];
            if (self.weights == null and self.degree <= 3) {
                try appendUnlessPoint(allocator, segments, from, self.bezierOf(span, from, to));
            } else try self.appendFitted(allocator, segments, span, .{ t0, t1 }, from, to, tolerance, 0);
            from = to;
        }
        return start;
    }

    /// Span `span`'s piece from `from` to `to`, its ends, exactly: its Bézier controls (its
    /// blossoms at its ends' knots, each so many times), a quadratic's raised to a cubic's,
    /// a straight one a line (path.curve).
    fn bezierOf(self: Spline, span: usize, from: [2]f64, to: [2]f64) path.Segment {
        const t0 = self.knots[span];
        const t1 = self.knots[span + 1];
        return switch (self.degree) {
            1 => .{ .to = to },
            2 => path.curve(from, bezier.quadraticAsCubic(from, self.blossom(span, &.{ t0, t1 }), to), to),
            else => path.curve(from, .{ .c1 = self.blossom(span, &.{ t0, t0, t1 }), .c2 = self.blossom(span, &.{ t0, t1, t1 }) }, to),
        };
    }

    /// Span `span`'s piece between the parameters `range`, from `from` to `to` (its points
    /// there), as the cubic through them along the spline's tangents there (Hermite's),
    /// halved until it keeps within `tolerance` of the spline (at FIT_CHECKS) or
    /// MAX_DEPTH times.
    fn appendFitted(self: Spline, allocator: std.mem.Allocator, segments: *std.ArrayList(path.Segment), span: usize, range: [2]f64, from: [2]f64, to: [2]f64, tolerance: f64, depth: usize) !void {
        const t0, const t1 = range;
        // A cubic's controls are its ends' derivatives a third of the way out
        const third = (t1 - t0) / 3;
        const d0 = self.evaluate(span, t0)[1];
        const d1 = self.evaluate(span, t1)[1];
        const cubic = bezier.Cubic{ .c1 = .{ from[0] + d0[0] * third, from[1] + d0[1] * third }, .c2 = .{ to[0] - d1[0] * third, to[1] - d1[1] * third } };
        if (depth < MAX_DEPTH) for (FIT_CHECKS) |s| {
            const want = self.evaluate(span, t0 + (t1 - t0) * s)[0];
            const got = bezier.pointOn(from, cubic, to, s);
            if (std.math.hypot(want[0] - got[0], want[1] - got[1]) <= tolerance) continue;
            const mid = (t0 + t1) / 2;
            const at_mid = self.evaluate(span, mid)[0];
            try self.appendFitted(allocator, segments, span, .{ t0, mid }, from, at_mid, tolerance, depth + 1);
            try self.appendFitted(allocator, segments, span, .{ mid, t1 }, at_mid, to, tolerance, depth + 1);
            return;
        };
        try appendUnlessPoint(allocator, segments, from, path.curve(from, cubic, to));
    }

    /// The point at `t` of span `span` (between its knots) and the derivative in t there.
    /// The blossom is affine in each argument, so the derivative is the degree times its
    /// slope in one, between the span's knots.
    fn evaluate(self: Spline, span: usize, t: f64) struct { [2]f64, [2]f64 } {
        const p = self.degree;
        var args: [MAX_DEGREE]f64 = undefined;
        @memset(args[0..p], t);
        const h = self.homogeneous(span, args[0..p]);
        const lo = self.knots[span];
        const hi = self.knots[span + 1];
        args[p - 1] = hi;
        const h_hi = self.homogeneous(span, args[0..p]);
        args[p - 1] = lo;
        const h_lo = self.homogeneous(span, args[0..p]);
        var dh: [3]f64 = undefined;
        for (&dh, h_hi, h_lo) |*d, a, b| d.* = @as(f64, @floatFromInt(p)) * (a - b) / (hi - lo);
        // Out of homogeneous coordinates: (x / w)' = (x' - (x / w) w') / w
        const point = [2]f64{ h[0] / h[2], h[1] / h[2] };
        return .{ point, .{ (dh[0] - point[0] * dh[2]) / h[2], (dh[1] - point[1] * dh[2]) / h[2] } };
    }

    /// The blossom (the polar form) of span `span`'s polynomial at `args` (as many as the
    /// degree), a point.
    fn blossom(self: Spline, span: usize, args: []const f64) [2]f64 {
        const h = self.homogeneous(span, args);
        return .{ h[0] / h[2], h[1] / h[2] };
    }

    /// The blossom of span `span`'s polynomial at `args` in homogeneous coordinates (each
    /// control point times its weight, and the weight): de Boor's algorithm with its r-th
    /// step at args[r - 1]; with every argument t, the point at t.
    fn homogeneous(self: Spline, span: usize, args: []const f64) [3]f64 {
        const p = self.degree;
        const k = span;
        var d: [MAX_DEGREE + 1][3]f64 = undefined;
        for (d[0 .. p + 1], 0..) |*point, j| {
            const c = self.controls[j + k - p];
            const w = if (self.weights) |weights| weights[j + k - p] else 1;
            point.* = .{ c[0] * w, c[1] * w, w };
        }
        for (1..p + 1) |r| {
            const t = args[r - 1];
            var j = p;
            while (j >= r) : (j -= 1) {
                const lo = self.knots[j + k - p];
                const hi = self.knots[j + 1 + k - r];
                const alpha = if (hi > lo) (t - lo) / (hi - lo) else 0;
                for (0..3) |axis| d[j][axis] = (1 - alpha) * d[j - 1][axis] + alpha * d[j][axis];
            }
        }
        return d[p];
    }
};

/// Appends `segment` from `from` unless it is only a point: its end and controls on `from`.
fn appendUnlessPoint(allocator: std.mem.Allocator, segments: *std.ArrayList(path.Segment), from: [2]f64, segment: path.Segment) !void {
    const still = std.meta.eql(segment.to, from) and if (segment.cubic) |c| std.meta.eql(c.c1, from) and std.meta.eql(c.c2, from) else true;
    if (!still) try segments.append(allocator, segment);
}
