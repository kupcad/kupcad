//! 2D affine transforms as the geometry graph stores one: `[6]f64`, column-major, so
//! x' = a x + c y + tx and y' = b x + d y + ty for `.{ a, b, c, d, tx, ty }`. One place for
//! how a move, a scale, a turn and a mirror are written, how two compose, where one puts a
//! point and whether it keeps a circle a circle; and how far a point is from a segment.

const std = @import("std");

/// How far from a similarity a matrix may be, relative to its scale, and still keep a
/// circle a circle (rounding in the turns and mirrors that make one).
const SIMILARITY_TOLERANCE = 1e-9;

pub const Matrix = [6]f64;

pub const identity: Matrix = .{ 1, 0, 0, 1, 0, 0 };

pub fn translation(x: f64, y: f64) Matrix {
    return .{ 1, 0, 0, 1, x, y };
}

pub fn scaling(sx: f64, sy: f64) Matrix {
    return .{ sx, 0, 0, sy, 0, 0 };
}

/// A turn of `degrees` counter-clockwise about the origin.
pub fn rotation(degrees: f64) Matrix {
    const rad = degrees * std.math.pi / 180.0;
    const c = @cos(rad);
    const s = @sin(rad);
    return .{ c, s, -s, c, 0, 0 };
}

/// A mirror across the line through the origin with normal (`nx`, `ny`), of any length
/// but zero: I - 2nnᵀ for the unit normal (symmetric, so its columns are its rows).
pub fn reflection(nx: f64, ny: f64) Matrix {
    const len = std.math.hypot(nx, ny);
    const x = nx / len;
    const y = ny / len;
    return .{ 1 - 2 * x * x, -2 * x * y, -2 * x * y, 1 - 2 * y * y, 0, 0 };
}

/// `outer` applied after `inner`.
pub fn compose(outer: Matrix, inner: Matrix) Matrix {
    const o = outer;
    return .{
        o[0] * inner[0] + o[2] * inner[1],
        o[1] * inner[0] + o[3] * inner[1],
        o[0] * inner[2] + o[2] * inner[3],
        o[1] * inner[2] + o[3] * inner[3],
        o[0] * inner[4] + o[2] * inner[5] + o[4],
        o[1] * inner[4] + o[3] * inner[5] + o[5],
    };
}

/// `p` as `m` places it.
pub fn apply(m: Matrix, p: [2]f64) [2]f64 {
    return .{ m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5] };
}

/// The factor `m` scales a length by, when it keeps a circle a circle (a move, a turn, a
/// uniform scale, a mirror: its two columns equally long and perpendicular); null when it
/// makes an ellipse, or nothing.
pub fn similarityScale(m: Matrix) ?f64 {
    const sx = std.math.hypot(m[0], m[1]);
    const sy = std.math.hypot(m[2], m[3]);
    const scale = @max(sx, sy);
    if (scale == 0) return null;
    if (@abs(sx - sy) > SIMILARITY_TOLERANCE * scale) return null;
    if (@abs(m[0] * m[2] + m[1] * m[3]) > SIMILARITY_TOLERANCE * scale * scale) return null;
    return sx;
}

/// The squared distance from `p` to the segment from `a` to `b` (to `a`, when it has no
/// length).
pub fn segmentDistanceSq(a: [2]f64, b: [2]f64, p: [2]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len_sq = dx * dx + dy * dy;
    const t = if (len_sq == 0) 0 else std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len_sq, 0, 1);
    const ex = a[0] + t * dx - p[0];
    const ey = a[1] + t * dy - p[1];
    return ex * ex + ey * ey;
}
