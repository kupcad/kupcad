//! Open 2D geometry: a path is a start point and segments from it, each a straight line, an
//! arc of a circle (its centre and radius, which way round and how far) or a cubic Bézier
//! curve (a glyph's, bezier.zig), what `line`, `polyline` and `arc` make and a drawing
//! writes exactly. The geometry alone: how an arc is defined, how a path moves, how it is
//! drawn as points for the kernel, and where its ends and bounds are. The script's Path
//! value (core/value.zig) holds one; the 2D exporters write its segments as a drawing's
//! edges.

const std = @import("std");
const bezier = @import("bezier.zig");
const affine2 = @import("affine2.zig");

/// What a Path can't be and why, for every message that says so: a 3D export's refusal,
/// the VM's NoMethodError (an `extrude`) and the lint (`shape-mismatch`).
pub const OPEN_PATH_HINT = "a Path is open and encloses nothing: close it (.close) into a Sketch or give it a width (.stroke(w)) first";

/// How many straight pieces a cubic's length is summed over.
const CUBIC_LENGTH_PIECES = 64;
/// The least an arc piece of `encloses` turns (radians): an arc that starts a rounding
/// error short of a quarter's end goes on past it, rather than by a piece of no length.
const QUARTER_SLACK = 1e-12;

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

    /// The segment as `matrix` (core/affine2.zig) places it: a similarity
    /// keeps an arc an arc, turned over by a mirror; anything else (an uneven scale) can't
    /// keep it one, and the caller draws the arc as lines first. Any affine keeps a cubic
    /// a cubic, its controls moved with it.
    pub fn transformed(self: Segment, matrix: [6]f64) Segment {
        var out = self;
        out.to = affine2.apply(matrix, self.to);
        if (self.arc) |arc| {
            const det = matrix[0] * matrix[3] - matrix[1] * matrix[2];
            out.arc = .{ .center = affine2.apply(matrix, arc.center), .radius = arc.radius * std.math.hypot(matrix[0], matrix[1]) };
            if (det < 0) out.ccw = !self.ccw;
        }
        if (self.cubic) |cubic| out.cubic = .{ .c1 = affine2.apply(matrix, cubic.c1), .c2 = affine2.apply(matrix, cubic.c2) };
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

/// The direction (a unit vector) a path of `segments` from `start` leaves its end in: a
/// line's, an arc's tangent there going its way round, a cubic's from its last control;
/// null for a path with no segments.
pub fn endTangent(start: [2]f64, segments: []const Segment) ?[2]f64 {
    if (segments.len == 0) return null;
    const last = segments[segments.len - 1];
    const from = if (segments.len >= 2) segments[segments.len - 2].to else start;
    const d: [2]f64 = if (last.arc) |arc| arcTangent(arc, last.to, last.ccw) else if (last.cubic) |cubic| blk: {
        // A last control on the end point leaves along the first one's line
        const c = if (cubic.c2[0] != last.to[0] or cubic.c2[1] != last.to[1]) cubic.c2 else cubic.c1;
        break :blk .{ last.to[0] - c[0], last.to[1] - c[1] };
    } else .{ last.to[0] - from[0], last.to[1] - from[1] };
    return unit(d);
}

/// The direction (a unit vector) `segment` leaves `from` in: a line's, an arc's tangent
/// there going its way round, a cubic's toward its first control.
pub fn startTangent(from: [2]f64, segment: Segment) [2]f64 {
    const d: [2]f64 = if (segment.arc) |arc| arcTangent(arc, from, segment.ccw) else if (segment.cubic) |cubic| blk: {
        // A first control on the start point leaves toward the second
        const c = if (cubic.c1[0] != from[0] or cubic.c1[1] != from[1]) cubic.c1 else cubic.c2;
        break :blk .{ c[0] - from[0], c[1] - from[1] };
    } else .{ segment.to[0] - from[0], segment.to[1] - from[1] };
    return unit(d);
}

/// The direction along `arc`'s circle at `p` going the `ccw` way, not of unit length.
fn arcTangent(arc: Arc, p: [2]f64, ccw: bool) [2]f64 {
    const r = [2]f64{ p[0] - arc.center[0], p[1] - arc.center[1] };
    return if (ccw) .{ -r[1], r[0] } else .{ r[1], -r[0] };
}

fn unit(d: [2]f64) [2]f64 {
    const len = std.math.hypot(d[0], d[1]);
    return .{ d[0] / len, d[1] / len };
}

/// The arc from `from` leaving in direction `tangent` (a unit vector) to `to`: its circle
/// touches the line along `tangent` at `from`, so a path turns into it without a corner.
/// Its centre is on the normal at `from`, as far from `to` as from `from`; it turns left
/// (counter-clockwise) when `to` is left of the line. Null when `to` is within `tolerance`
/// of that line, where no circle touches it (a straight line goes on along it).
pub fn tangentArc(from: [2]f64, tangent: [2]f64, to: [2]f64, tolerance: f64) ?Segment {
    const d = [2]f64{ to[0] - from[0], to[1] - from[1] };
    const normal = [2]f64{ -tangent[1], tangent[0] };
    const off_line = d[0] * normal[0] + d[1] * normal[1];
    if (@abs(off_line) <= tolerance) return null;
    // |from + s·n − to| = |s|: s = |d|² / 2(d·n)
    const s = (d[0] * d[0] + d[1] * d[1]) / (2 * off_line);
    const center = [2]f64{ from[0] + s * normal[0], from[1] + s * normal[1] };
    const ccw = s > 0;
    return .{ .to = to, .arc = .{ .center = center, .radius = @abs(s) }, .ccw = ccw, .angle = sweep(center, from, to, ccw) };
}

/// A path's start and segments, as plain data: what a drawing's reader gives for each line
/// it reads, an outline's closed (its last segment ending at its start).
pub const Run = struct { start: [2]f64, segments: []Segment };

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

/// The area the closed path from `start` along `segments` encloses (its end joined
/// straight back to its start), positive when it runs counter-clockwise: its chords'
/// shoelace sum, with each arc's bulge past its chord on the side it bends to. A cubic
/// counts as its chord.
pub fn signedArea(start: [2]f64, segments: []const Segment) f64 {
    var twice: f64 = 0;
    var from = start;
    for (segments) |segment| {
        twice += from[0] * segment.to[1] - segment.to[0] * from[1];
        if (segment.arc) |arc| {
            // Between an arc and its chord: r²(θ - sin θ) / 2
            const bulge = arc.radius * arc.radius * (segment.angle - @sin(segment.angle));
            twice += if (segment.ccw) bulge else -bulge;
        }
        from = segment.to;
    }
    twice += from[0] * start[1] - start[0] * from[1];
    return twice / 2;
}

/// The path from `start` along `segments` run back from its end (endOf) to `start`: the
/// segments in the other order, each arc turning the other way and each cubic's controls
/// swapped. Owned by `allocator`.
pub fn reversed(allocator: std.mem.Allocator, start: [2]f64, segments: []const Segment) ![]Segment {
    const out = try allocator.alloc(Segment, segments.len);
    for (out, 0..) |*segment, i| {
        const k = segments.len - 1 - i;
        segment.* = segments[k];
        segment.to = if (k == 0) start else segments[k - 1].to;
        if (segments[k].arc != null) segment.ccw = !segments[k].ccw;
        if (segments[k].cubic) |cubic| segment.cubic = cubic.reversed();
    }
    return out;
}

/// Whether `p` lies inside the closed path from `start` along `segments` (its end joined
/// straight back to its start), by the even-odd rule: whether a ray from `p` along +x
/// crosses it an odd number of times, exactly on arcs. A point on the path may count
/// either way; a cubic counts as its chord.
pub fn encloses(start: [2]f64, segments: []const Segment, p: [2]f64) bool {
    var inside = false;
    var from = start;
    for (segments) |segment| {
        const crosses = if (segment.arc) |arc| arcCrosses(from, segment, arc, p) else lineCrosses(from, segment.to, p);
        if (crosses) inside = !inside;
        from = segment.to;
    }
    if (lineCrosses(from, start, p)) inside = !inside;
    return inside;
}

/// Whether the line from `a` to `b` crosses the ray from `p` along +x: one end above
/// `p` and the other not, and the crossing to its right.
fn lineCrosses(a: [2]f64, b: [2]f64, p: [2]f64) bool {
    if ((a[1] > p[1]) == (b[1] > p[1])) return false;
    return a[0] + (p[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1]) > p[0];
}

/// Whether the arc from `from` crosses the ray from `p` along +x an odd number of times.
/// Cut where it passes a quarter of its circle, each piece rises or falls only, so it
/// crosses as a line between its ends would, at the circle's x on its side.
fn arcCrosses(from: [2]f64, segment: Segment, arc: Arc, p: [2]f64) bool {
    const quarter = std.math.pi / 2.0;
    const way: f64 = if (segment.ccw) 1 else -1;
    const a0 = std.math.atan2(from[1] - arc.center[1], from[0] - arc.center[0]);
    var odd = false;
    var done: f64 = 0;
    var piece_from = from;
    while (done < segment.angle) {
        // On to the next quarter's end the arc's way, or to the arc's end
        const at = a0 + way * done;
        const boundary = if (segment.ccw) (@floor(at / quarter) + 1) * quarter else (@ceil(at / quarter) - 1) * quarter;
        const step = @min(@max(@abs(boundary - at), QUARTER_SLACK), segment.angle - done);
        done += step;
        const piece_to = if (done >= segment.angle) segment.to else pointAtRadians(arc, a0 + way * done);
        if ((piece_from[1] > p[1]) != (piece_to[1] > p[1])) {
            const dy = p[1] - arc.center[1];
            const dx = @sqrt(@max(0, arc.radius * arc.radius - dy * dy));
            const right = @cos(a0 + way * (done - step / 2)) >= 0;
            if (arc.center[0] + (if (right) dx else -dx) > p[0]) odd = !odd;
        }
        piece_from = piece_to;
    }
    return odd;
}

fn pointAtRadians(arc: Arc, radians: f64) [2]f64 {
    return .{ arc.center[0] + arc.radius * @cos(radians), arc.center[1] + arc.radius * @sin(radians) };
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
