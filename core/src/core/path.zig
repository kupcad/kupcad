//! Open 2D geometry: a path is a start point and segments from it, each a straight line, an
//! arc of a circle (its centre and radius, which way round and how far) or a cubic Bézier
//! curve (a glyph's, bezier.zig), what `line`, `polyline` and `arc` make and a drawing
//! writes exactly. The geometry alone: how an arc is defined, how a path moves, how it is
//! drawn as points for the kernel, and where its ends and bounds are. The script's Path
//! value (core/value.zig) holds one; the 2D exporters write its segments as a drawing's
//! edges.

const std = @import("std");
const bezier = @import("bezier.zig");

/// What a Path can't be and why, for every message that says so: a 3D export's refusal,
/// the VM's NoMethodError (an `extrude`) and the lint (`shape-mismatch`).
pub const OPEN_PATH_HINT = "a Path is open and encloses nothing: close it (.close) into a Sketch or give it a width (.stroke(w)) first";

/// How many straight pieces a cubic's length is summed over.
const CUBIC_LENGTH_PIECES = 64;

/// The circle an arc lies on.
pub const Arc = struct {
    center: [2]f64,
    radius: f64,
};

pub const Cubic = bezier.Cubic;

/// One segment: a straight line to `to`, the arc of `arc`'s circle to it, counter-clockwise
/// about the centre when `ccw`, sweeping `angle` radians (more than π: the long way round),
/// or the cubic curve of `cubic`'s controls to it; never both an arc and a curve.
pub const Segment = struct {
    to: [2]f64,
    arc: ?Arc = null,
    ccw: bool = true,
    angle: f64 = 0,
    cubic: ?Cubic = null,

    pub fn isLine(self: Segment) bool {
        return self.arc == null and self.cubic == null;
    }

    pub fn large(self: Segment) bool {
        return self.angle > std.math.pi;
    }

    /// How long the segment is from `from`: a line's, an arc's, or a cubic's summed over
    /// CUBIC_LENGTH_PIECES straight pieces.
    pub fn length(self: Segment, from: [2]f64) f64 {
        if (self.arc) |arc| return arc.radius * self.angle;
        if (self.cubic) |cubic| {
            var total: f64 = 0;
            var last = from;
            for (1..CUBIC_LENGTH_PIECES + 1) |k| {
                const p = bezier.pointOn(from, cubic, self.to, @as(f64, @floatFromInt(k)) / CUBIC_LENGTH_PIECES);
                total += std.math.hypot(p[0] - last[0], p[1] - last[1]);
                last = p;
            }
            return total;
        }
        return std.math.hypot(self.to[0] - from[0], self.to[1] - from[1]);
    }

    /// Whether the arc from `from` passes `p`, a point of its circle: `p`'s angle lies
    /// within the arc's, going its way.
    pub fn passes(self: Segment, from: [2]f64, p: [2]f64) bool {
        const arc = self.arc orelse return false;
        return sweep(arc.center, from, p, self.ccw) <= self.angle;
    }

    /// The segment as `matrix` (column-major, x' = a x + c y + tx) places it: a similarity
    /// keeps an arc an arc, turned over by a mirror; anything else (an uneven scale) can't
    /// keep it one, and the caller draws the arc as lines first. Any affine keeps a cubic
    /// a cubic, its controls moved with it.
    pub fn transformed(self: Segment, matrix: [6]f64) Segment {
        var out = self;
        out.to = apply(matrix, self.to);
        if (self.arc) |arc| {
            const det = matrix[0] * matrix[3] - matrix[1] * matrix[2];
            out.arc = .{ .center = apply(matrix, arc.center), .radius = arc.radius * std.math.hypot(matrix[0], matrix[1]) };
            if (det < 0) out.ccw = !self.ccw;
        }
        if (self.cubic) |cubic| out.cubic = .{ .c1 = apply(matrix, cubic.c1), .c2 = apply(matrix, cubic.c2) };
        return out;
    }
};

/// The angle swept about `center` from `from` to `to` going the `ccw` way, in [0, 2π).
pub fn sweep(center: [2]f64, from: [2]f64, to: [2]f64, ccw: bool) f64 {
    const a0 = std.math.atan2(from[1] - center[1], from[0] - center[0]);
    const a1 = std.math.atan2(to[1] - center[1], to[0] - center[0]);
    const d = if (ccw) a1 - a0 else a0 - a1;
    return if (d < 0) d + 2 * std.math.pi else d;
}

/// `p` as the column-major 2D affine `matrix` places it.
pub fn apply(matrix: [6]f64, p: [2]f64) [2]f64 {
    return .{ matrix[0] * p[0] + matrix[2] * p[1] + matrix[4], matrix[1] * p[0] + matrix[3] * p[1] + matrix[5] };
}

/// Whether `matrix` keeps a circle a circle: its columns equally long and perpendicular
/// (a move, a turn, a uniform scale, a mirror).
pub fn isSimilarity(matrix: [6]f64) bool {
    const sx = std.math.hypot(matrix[0], matrix[1]);
    const sy = std.math.hypot(matrix[2], matrix[3]);
    const scale = @max(sx, sy);
    if (scale == 0) return false;
    return @abs(sx - sy) <= SIMILARITY_TOLERANCE * scale and @abs(matrix[0] * matrix[2] + matrix[1] * matrix[3]) <= SIMILARITY_TOLERANCE * scale * scale;
}

/// How far from a similarity a matrix may be, relative to its scale, and still keep arcs.
const SIMILARITY_TOLERANCE = 1e-9;

/// The point of `arc`'s circle at `degrees` from the +x axis.
pub fn pointAt(arc: Arc, degrees: f64) [2]f64 {
    const rad = degrees * std.math.pi / 180.0;
    return .{ arc.center[0] + arc.radius * @cos(rad), arc.center[1] + arc.radius * @sin(rad) };
}

/// The arc about `center` of `radius` from `start` to `end` degrees, counter-clockwise
/// when `end` is past `start` and clockwise otherwise, as a segment to its end; its start is
/// `pointAt(arc, start)`.
pub fn arcByAngles(center: [2]f64, radius: f64, start: f64, end: f64) Segment {
    const arc = Arc{ .center = center, .radius = radius };
    const ccw = end >= start;
    return .{ .to = pointAt(arc, end), .arc = arc, .ccw = ccw, .angle = @abs(end - start) * std.math.pi / 180.0 };
}

/// The arc of `radius` from `from` to `to`, the short way unless `large`, counter-clockwise
/// when `ccw`; null when the points are further apart than the circle allows (2r) or the
/// same point.
pub fn arcThrough(from: [2]f64, to: [2]f64, radius: f64, ccw: bool, large: bool) ?Segment {
    const dx = to[0] - from[0];
    const dy = to[1] - from[1];
    const chord = std.math.hypot(dx, dy);
    if (chord == 0 or chord > 2 * radius) return null;
    // The centre lies on the chord's bisector, `h` from its midpoint; on the left of the
    // chord for a short counter-clockwise arc, on the right for a long one
    const h = @sqrt(@max(0, radius * radius - chord * chord / 4));
    const left = ccw != large;
    const side: f64 = if (left) 1 else -1;
    const center = [2]f64{ (from[0] + to[0]) / 2 - side * h * dy / chord, (from[1] + to[1]) / 2 + side * h * dx / chord };
    const arc = Arc{ .center = center, .radius = radius };
    return .{ .to = to, .arc = arc, .ccw = ccw, .angle = sweep(center, from, to, ccw) };
}

/// Where a path of `segments` from `start` ends.
pub fn endOf(start: [2]f64, segments: []const Segment) [2]f64 {
    return if (segments.len == 0) start else segments[segments.len - 1].to;
}

/// Which of a path's points a segment drew: `count` from `first` (its end last; the start
/// of the first segment is the path's start, point 0).
pub const Range = struct { first: u32, count: u32 };

/// The points a path is drawn with: the start, then each segment's, an arc or a cubic as
/// `chords[i]` chords (a cubic's at even steps of its parameter) and a line as its end:
/// the kernel's polygon of a closed path, a stroke's spine. `ranges`, when given (one per
/// segment), gets which points each segment drew.
pub fn appendPoints(allocator: std.mem.Allocator, pts: *std.ArrayList([2]f64), start: [2]f64, segments: []const Segment, chords: []const u32, ranges: ?[]Range) !void {
    try pts.append(allocator, start);
    var from = start;
    for (segments, chords, 0..) |segment, chord_count, i| {
        const first = pts.items.len;
        const n: usize = @max(1, chord_count);
        if (segment.arc) |arc| {
            const a0 = std.math.atan2(from[1] - arc.center[1], from[0] - arc.center[0]);
            const step = (if (segment.ccw) segment.angle else -segment.angle) / @as(f64, @floatFromInt(n));
            for (1..n) |k| {
                const a = a0 + step * @as(f64, @floatFromInt(k));
                try pts.append(allocator, .{ arc.center[0] + arc.radius * @cos(a), arc.center[1] + arc.radius * @sin(a) });
            }
        } else if (segment.cubic) |cubic| {
            for (1..n) |k| try pts.append(allocator, bezier.pointOn(from, cubic, segment.to, @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n))));
        }
        try pts.append(allocator, segment.to);
        if (ranges) |r| r[i] = .{ .first = @intCast(first), .count = @intCast(pts.items.len - first) };
        from = segment.to;
    }
}

/// A box around points.
pub const Bounds = struct {
    min: [2]f64,
    max: [2]f64,

    pub fn include(box: *?Bounds, p: [2]f64) void {
        if (box.*) |*b| {
            b.min = .{ @min(b.min[0], p[0]), @min(b.min[1], p[1]) };
            b.max = .{ @max(b.max[0], p[0]), @max(b.max[1], p[1]) };
        } else box.* = .{ .min = p, .max = p };
    }
};

/// The box around a path, its arcs' bulges and its curves' bends included.
pub fn bounds(start: [2]f64, segments: []const Segment) Bounds {
    var box: ?Bounds = null;
    Bounds.include(&box, start);
    var from = start;
    for (segments) |segment| {
        Bounds.include(&box, segment.to);
        if (segment.cubic) |cubic| {
            // A cubic is furthest out where it turns back along an axis: where the
            // derivative of that coordinate, a quadratic in t, is zero
            for (0..2) |axis| {
                const p0 = from[axis];
                const p1 = cubic.c1[axis];
                const p2 = cubic.c2[axis];
                const p3 = segment.to[axis];
                const a = -p0 + 3 * p1 - 3 * p2 + p3;
                const b = 2 * (p0 - 2 * p1 + p2);
                const c = p1 - p0;
                for (quadraticRoots(a, b, c)) |maybe| {
                    const t = maybe orelse continue;
                    if (t > 0 and t < 1) Bounds.include(&box, bezier.pointOn(from, cubic, segment.to, t));
                }
            }
        }
        if (segment.arc) |arc| {
            // Wherever the arc crosses an axis through the centre, it reaches the circle's
            // extreme on that side
            const extremes = [4][2]f64{
                .{ arc.center[0] + arc.radius, arc.center[1] },
                .{ arc.center[0], arc.center[1] + arc.radius },
                .{ arc.center[0] - arc.radius, arc.center[1] },
                .{ arc.center[0], arc.center[1] - arc.radius },
            };
            for (extremes) |p| {
                if (segment.passes(from, p)) Bounds.include(&box, p);
            }
        }
        from = segment.to;
    }
    return box.?;
}

/// The real roots of a t² + b t + c (a line's one root when `a` is 0), each null when
/// there is none.
fn quadraticRoots(a: f64, b: f64, c: f64) [2]?f64 {
    if (a == 0) return .{ if (b == 0) null else -c / b, null };
    const discriminant = b * b - 4 * a * c;
    if (discriminant < 0) return .{ null, null };
    const root = @sqrt(discriminant);
    return .{ (-b - root) / (2 * a), (-b + root) / (2 * a) };
}
