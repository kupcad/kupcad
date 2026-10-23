//! Cubic Bézier curves: flattens quadratic and cubic ones into line segments by De
//! Casteljau subdivision (`flattenQuadratic`, `flattenCubic`), used by text.zig for glyph
//! outlines, keeps the curve a run of points was flattened from (`Flattened`), so a
//! drawing can write it exactly again, and draws an ellipse's arc (a circle's) as cubics
//! (`Ellipse.cubic`, `Ellipse.arc`), as a DXF spline writes an arc and the drawing imports
//! read an ellipse.

const std = @import("std");
const affine2 = @import("affine2.zig");

/// The most an arc's cubic piece turns (`arcPieceCount`): within an eighth of a turn a
/// cubic keeps within 4.2e-6 of the radius.
pub const ARC_PIECE_TURN = std.math.pi / 4.0;
/// How far off its chord (a share of the chord's length) a cubic's controls can be and it
/// still be the straight line (`isStraight`): past what a drawing's digits round to.
const STRAIGHT_SLACK = 1e-9;

/// A cubic Bézier curve's two control points; its ends are the points it runs between.
pub const Cubic = struct {
    c1: [2]f64,
    c2: [2]f64,

    /// The same curve run the other way.
    pub fn reversed(self: Cubic) Cubic {
        return .{ .c1 = self.c2, .c2 = self.c1 };
    }
};

/// An ellipse: its centre, its radii along its own x and y, its x along `axis` (a unit
/// vector; (1, 0) unturned). A circle has its radii equal.
pub const Ellipse = struct {
    center: [2]f64,
    rx: f64,
    ry: f64,
    axis: [2]f64 = .{ 1, 0 },

    pub fn circle(center: [2]f64, radius: f64) Ellipse {
        return .{ .center = center, .rx = radius, .ry = radius };
    }

    /// Its point at the parameter `t` (radians; the angle itself on a circle).
    pub fn at(self: Ellipse, t: f64) [2]f64 {
        return self.placed(.{ self.rx * @cos(t), self.ry * @sin(t) }, self.center);
    }

    /// The derivative of `at` in t: the way it runs as t grows.
    pub fn tangentAt(self: Ellipse, t: f64) [2]f64 {
        return self.placed(.{ -self.rx * @sin(t), self.ry * @cos(t) }, .{ 0, 0 });
    }

    /// The cubic close to it from `from`, its point at `t0`, to `to`, its point at `t1`
    /// (either way round; within a quarter turn it keeps within 2.7e-4 of the radius):
    /// the controls along its tangents there, 4/3 tan((t1 - t0) / 4) of them out. The ends
    /// are the caller's, so a piece ends exactly where the next starts.
    pub fn cubic(self: Ellipse, t0: f64, t1: f64, from: [2]f64, to: [2]f64) Cubic {
        const alpha = 4.0 / 3.0 * @tan((t1 - t0) / 4);
        const d0 = self.tangentAt(t0);
        const d1 = self.tangentAt(t1);
        return .{ .c1 = .{ from[0] + alpha * d0[0], from[1] + alpha * d0[1] }, .c2 = .{ to[0] - alpha * d1[0], to[1] - alpha * d1[1] } };
    }

    /// Its arc from the parameter `t0` on by `sweep` (radians; negative the other way
    /// round) as `count` cubics of an equal turn each, one by one, from `from` to `to`, its
    /// points there (the caller's, so the arc ends exactly where what is next to it does).
    pub fn arc(self: Ellipse, t0: f64, sweep: f64, from: [2]f64, to: [2]f64, count: usize) Arc {
        return .{ .ellipse = self, .t = t0, .step = sweep / @as(f64, @floatFromInt(count)), .left = count, .at = from, .end = to };
    }

    /// `v`, in its own axes, turned onto the plane's and moved by `by`.
    fn placed(self: Ellipse, v: [2]f64, by: [2]f64) [2]f64 {
        return .{ by[0] + self.axis[0] * v[0] - self.axis[1] * v[1], by[1] + self.axis[1] * v[0] + self.axis[0] * v[1] };
    }
};

/// An ellipse's arc's cubics (`Ellipse.arc`), one by one.
pub const Arc = struct {
    ellipse: Ellipse,
    t: f64,
    step: f64,
    left: usize,
    at: [2]f64,
    end: [2]f64,

    pub fn next(self: *Arc) ?Piece {
        if (self.left == 0) return null;
        self.left -= 1;
        const t1 = self.t + self.step;
        const to = if (self.left == 0) self.end else self.ellipse.at(t1);
        const piece = Piece{ .cubic = self.ellipse.cubic(self.t, t1, self.at, to), .to = to };
        self.t = t1;
        self.at = to;
        return piece;
    }
};

/// A cubic and the point it runs to (from where the one before it ends).
pub const Piece = struct { cubic: Cubic, to: [2]f64 };

/// How many cubics of at most ARC_PIECE_TURN each an arc of `sweep` radians (either way
/// round) is drawn as.
pub fn arcPieceCount(sweep: f64) usize {
    return @intFromFloat(@max(1, @ceil(@abs(sweep) / ARC_PIECE_TURN)));
}

/// A curve a run of a polygon's points was flattened from: `count` points of contour
/// `contour` from `first` (the first and the last its ends), and the cubic between them.
pub const Flattened = struct {
    contour: u32,
    first: u32,
    count: u32,
    cubic: Cubic,
};

/// The quadratic from `p0` through the control `q` to `p2` as a cubic: the same curve (a
/// degree elevation is exact).
pub fn quadraticAsCubic(p0: [2]f64, q: [2]f64, p2: [2]f64) Cubic {
    return .{
        .c1 = .{ p0[0] + 2.0 / 3.0 * (q[0] - p0[0]), p0[1] + 2.0 / 3.0 * (q[1] - p0[1]) },
        .c2 = .{ p2[0] + 2.0 / 3.0 * (q[0] - p2[0]), p2[1] + 2.0 / 3.0 * (q[1] - p2[1]) },
    };
}

/// Whether the cubic from `p0` to `p3` is the straight line between them, as a drawing
/// writes a line among its curves: its controls on the chord, between its ends (within
/// STRAIGHT_SLACK).
pub fn isStraight(p0: [2]f64, cubic: Cubic, p3: [2]f64) bool {
    const dx = p3[0] - p0[0];
    const dy = p3[1] - p0[1];
    const length_sq = dx * dx + dy * dy;
    if (length_sq == 0) return false;
    for ([_][2]f64{ cubic.c1, cubic.c2 }) |c| {
        const vx = c[0] - p0[0];
        const vy = c[1] - p0[1];
        const along = (vx * dx + vy * dy) / length_sq;
        const off = (vx * dy - vy * dx) / length_sq;
        if (@abs(off) > STRAIGHT_SLACK or along < -STRAIGHT_SLACK or along > 1 + STRAIGHT_SLACK) return false;
    }
    return true;
}

/// The point of the cubic from `p0` to `p3` at `t`, 0 at `p0` and 1 at `p3`.
pub fn pointOn(p0: [2]f64, cubic: Cubic, p3: [2]f64, t: f64) [2]f64 {
    const u = 1 - t;
    const w0 = u * u * u;
    const w1 = 3 * u * u * t;
    const w2 = 3 * u * t * t;
    const w3 = t * t * t;
    return .{
        w0 * p0[0] + w1 * cubic.c1[0] + w2 * cubic.c2[0] + w3 * p3[0],
        w0 * p0[1] + w1 * cubic.c1[1] + w2 * cubic.c2[1] + w3 * p3[1],
    };
}

inline fn midpoint(a: [2]f64, b: [2]f64) [2]f64 {
    return .{ (a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0 };
}

/// Recursively flattens a Quadratic Bézier curve.
/// We do NOT append p0, because the previous curve/line/moveTo will have already appended it.
pub fn flattenQuadratic(
    allocator: std.mem.Allocator,
    points: *std.ArrayList([2]f64),
    p0: [2]f64,
    p1: [2]f64,
    p2: [2]f64,
    toleranceSq: f64,
) !void {
    const d = affine2.segmentDistanceSq(p0, p2, p1);

    // If the control point is close enough to the straight line p0-p2, it's flat!
    if (d <= toleranceSq) {
        try points.append(allocator, p2);
        return;
    }

    // De Casteljau subdivision
    const p01 = midpoint(p0, p1);
    const p12 = midpoint(p1, p2);
    const p012 = midpoint(p01, p12); // Point on the curve at t=0.5

    try flattenQuadratic(allocator, points, p0, p01, p012, toleranceSq);
    try flattenQuadratic(allocator, points, p012, p12, p2, toleranceSq);
}

/// Recursively flattens a Cubic Bézier curve.
pub fn flattenCubic(
    allocator: std.mem.Allocator,
    points: *std.ArrayList([2]f64),
    p0: [2]f64,
    p1: [2]f64,
    p2: [2]f64,
    p3: [2]f64,
    toleranceSq: f64,
) !void {
    const d1 = affine2.segmentDistanceSq(p0, p3, p1);
    const d2 = affine2.segmentDistanceSq(p0, p3, p2);

    // If both control points are close to the straight line p0-p3, it's flat!
    if (d1 <= toleranceSq and d2 <= toleranceSq) {
        try points.append(allocator, p3);
        return;
    }

    // De Casteljau subdivision
    const p01 = midpoint(p0, p1);
    const p12 = midpoint(p1, p2);
    const p23 = midpoint(p2, p3);

    const p012 = midpoint(p01, p12);
    const p123 = midpoint(p12, p23);

    const p0123 = midpoint(p012, p123); // Point on the curve at t=0.5

    try flattenCubic(allocator, points, p0, p01, p012, p0123, toleranceSq);
    try flattenCubic(allocator, points, p0123, p123, p23, p3, toleranceSq);
}
