//! B-splines in the plane, as a drawing gives them (a DXF `SPLINE`): `Spline`, read
//! by its blossoms (the polar form, de Boor's algorithm with a parameter of its own at
//! each step) and drawn as path segments, exactly where a cubic can be one; and `through`,
//! the spline through given points (a CAD program's fit points).

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
/// The degree of the spline `through` points, as a CAD program's fit-point spline's.
const THROUGH_DEGREE = 3;

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

    /// Its point at `t`, between its first knot span's start and its last's end.
    pub fn pointAt(self: Spline, t: f64) [2]f64 {
        var span = self.degree;
        while (span + 1 < self.controls.len and self.knots[span + 1] <= t) span += 1;
        return self.evaluate(span, t)[0];
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

/// The polynomial spline of degree 3 (less, for too few points) through `points` (two or
/// more, none on the one before it), leaving along `start` and arriving along `end` when
/// they are given (directions of any length but none): Piegl and Tiller's global
/// interpolation (The NURBS Book, 9.2.1, and 9.2.2 for the ends' tangents). Its parameters
/// are the points' chord lengths along them over the whole, its knots their averages (an
/// end with a tangent counted twice), a tangent as long as the whole, as the parameters
/// run 0 to 1 over it. The ends are clamped, so the first and last control points are the
/// ends, and a tangent's sets the one beside it; each point between is the degree and one
/// more basis functions times the rest, which averaged knots keep banded about the
/// diagonal, in a totally positive system, solved without pivoting. Owned by `allocator`;
/// error.Singular for points it can't pass through (by rounding, at most).
pub fn through(allocator: std.mem.Allocator, points: []const [2]f64, start: ?[2]f64, end: ?[2]f64) !Spline {
    const n = points.len - 1;
    const last = n + @intFromBool(start != null) + @intFromBool(end != null);
    const p: usize = @min(THROUGH_DEGREE, last);
    const params = try allocator.alloc(f64, points.len);
    defer allocator.free(params);
    var total: f64 = 0;
    params[0] = 0;
    for (1..points.len) |k| {
        total += std.math.hypot(points[k][0] - points[k - 1][0], points[k][1] - points[k - 1][1]);
        params[k] = total;
    }
    for (params) |*u| u.* /= total;
    params[n] = 1;

    // The knots: the ends' p + 1 times, and between them the averages of p parameters
    // in turn, an end with a tangent's parameter twice
    const extended = try allocator.alloc(f64, last + 1);
    defer allocator.free(extended);
    const first: usize = @intFromBool(start != null);
    if (start != null) extended[0] = 0;
    @memcpy(extended[first..][0..points.len], params);
    if (end != null) extended[last] = 1;
    const knots = try allocator.alloc(f64, last + p + 2);
    errdefer allocator.free(knots);
    for (0..p + 1) |j| {
        knots[j] = 0;
        knots[last + 1 + j] = 1;
    }
    for (1..last - p + 1) |j| {
        var sum: f64 = 0;
        for (extended[j..][0..p]) |u| sum += u;
        knots[j + p] = sum / @as(f64, @floatFromInt(p));
    }

    const controls = try allocator.alloc([2]f64, last + 1);
    errdefer allocator.free(controls);
    controls[0] = points[0];
    controls[last] = points[n];
    // The derivative at an end is p / (its span's length) times the step to the control
    // point beside it
    const degree: f64 = @floatFromInt(p);
    if (start) |t| controls[1] = along(points[0], t, total * knots[p + 1] / degree);
    if (end) |t| controls[last - 1] = along(points[n], t, -total * (1 - knots[last]) / degree);
    try solveBetween(allocator, points, params, knots, p, controls, first + 1, last - 1 - @intFromBool(end != null));
    return .{ .degree = p, .knots = knots, .controls = controls, .weights = null };
}

/// The control points `lo` to `hi` of the spline of degree `p` over `knots` whose other
/// control points `controls` holds, so that it passes through each point but the ends at
/// its parameter: each point's equation, of the basis functions there, a row of a banded
/// system (as far either side of the diagonal as one more than the degree), eliminated
/// without pivoting, as a totally positive system can be.
fn solveBetween(allocator: std.mem.Allocator, points: []const [2]f64, params: []const f64, knots: []const f64, p: usize, controls: [][2]f64, lo: usize, hi: usize) !void {
    if (hi < lo) return;
    const count = hi - lo + 1;
    const w = p + 1;
    const stride = 2 * w + 1;
    const band = try allocator.alloc(f64, count * stride);
    defer allocator.free(band);
    @memset(band, 0);
    const rhs = try allocator.alloc([2]f64, count);
    defer allocator.free(rhs);
    for (rhs, points[1 .. points.len - 1], params[1 .. params.len - 1], 0..) |*right, q, u, r| {
        const span = spanOf(knots, controls.len - 1, p, u);
        var basis: [THROUGH_DEGREE + 1]f64 = undefined;
        basisAt(knots, span, u, p, basis[0 .. p + 1]);
        right.* = q;
        for (basis[0 .. p + 1], span - p..) |b, i| {
            // A control point already known goes to the right side
            if (i < lo or i > hi) {
                right.* = .{ right[0] - b * controls[i][0], right[1] - b * controls[i][1] };
                continue;
            }
            const c = i - lo;
            if (c + w < r or c > r + w) return error.Singular;
            band[r * stride + c + w - r] = b;
        }
    }
    for (0..count) |k| {
        const pivot = band[k * stride + w];
        if (!(@abs(pivot) > 0) or !std.math.isFinite(pivot)) return error.Singular;
        for (k + 1..@min(k + w + 1, count)) |r| {
            const f = band[r * stride + k + w - r] / pivot;
            if (f == 0) continue;
            for (k..@min(k + w + 1, count)) |c| band[r * stride + c + w - r] -= f * band[k * stride + c + w - k];
            rhs[r] = .{ rhs[r][0] - f * rhs[k][0], rhs[r][1] - f * rhs[k][1] };
        }
    }
    var r = count;
    while (r > 0) {
        r -= 1;
        var x = rhs[r];
        for (r + 1..@min(r + w + 1, count)) |c| {
            const a = band[r * stride + c + w - r];
            x = .{ x[0] - a * controls[c + lo][0], x[1] - a * controls[c + lo][1] };
        }
        const d = band[r * stride + w];
        controls[r + lo] = .{ x[0] / d, x[1] / d };
    }
}

/// The knot span `u` is in (the last k from `p` with knots[k] <= u), of a spline whose
/// last control point is `last`.
fn spanOf(knots: []const f64, last: usize, p: usize, u: f64) usize {
    var span = p;
    while (span < last and knots[span + 1] <= u) span += 1;
    return span;
}

/// The p + 1 basis functions of degree p that aren't zero at `u` in span `span`, into
/// `out` (The NURBS Book's A2.2).
fn basisAt(knots: []const f64, span: usize, u: f64, p: usize, out: []f64) void {
    var left: [THROUGH_DEGREE + 1]f64 = undefined;
    var right: [THROUGH_DEGREE + 1]f64 = undefined;
    out[0] = 1;
    for (1..p + 1) |j| {
        left[j] = u - knots[span + 1 - j];
        right[j] = knots[span + j] - u;
        var saved: f64 = 0;
        for (0..j) |r| {
            const temp = out[r] / (right[r + 1] + left[j - r]);
            out[r] = saved + right[r + 1] * temp;
            saved = left[j - r] * temp;
        }
        out[j] = saved;
    }
}

/// `from` moved `distance` along the direction `t`.
fn along(from: [2]f64, t: [2]f64, distance: f64) [2]f64 {
    const length = std.math.hypot(t[0], t[1]);
    return .{ from[0] + t[0] / length * distance, from[1] + t[1] / length * distance };
}
