//! A path's corners eased: where two sides (lines or arcs) meet at an angle, the corner is
//! rounded off by the arc that touches both (a fillet) or cut off by a straight line (a
//! chamfer, the same length back along each). What `polygon(round_r:)`,
//! `polygon(chamfer:)` and a Path's `fillet` and `chamfer` make; the arcs are exact, so a
//! drawing writes them as arcs. Between two lines the fillet's tangent points are found in
//! closed form; beside an arc, the fillet's centre is where the sides moved `r` towards
//! the corner's inside meet (a line along itself, an arc's circle grown or shrunk by `r`),
//! and an arc gives up its sweep to the corner.

const std = @import("std");
const path = @import("path.zig");

/// A turn this small (in radians) is no corner: the sides go on straight.
const STRAIGHT_TURN = 1e-12;

/// How a corner is eased: rounded off by the arc of radius `round` that touches both
/// sides, or cut off by the line between the points `chamfer` back along each side.
pub const Ease = union(enum) {
    round: f64,
    chamfer: f64,

    /// The radius or the cut.
    pub fn size(self: Ease) f64 {
        return switch (self) {
            inline else => |v| v,
        };
    }
};

/// Why a path's corners can't be eased, for the caller's message; points are numbered
/// from 0, the path's start, and segment k runs from point k.
pub const Failure = union(enum) {
    /// The sides at this point double back on each other, so nothing can round or cut
    /// the corner.
    doubles_back: usize,
    /// The segment from point `from` is `length` long, less than the `needed` the
    /// corners at its ends take from it.
    too_short: struct { from: usize, length: f64, needed: f64 },
    /// No arc of the radius touches both sides at this point: an arc there curves the
    /// corner's way more tightly than it, or the sides never come within it.
    no_fit: usize,
};

pub const Error = error{CornerFailed} || std.mem.Allocator.Error;

/// A path eased: its segments are owned by the allocator it was eased with.
pub const Eased = struct {
    start: [2]f64,
    segments: []path.Segment,

    pub fn deinit(self: Eased, allocator: std.mem.Allocator) void {
        allocator.free(self.segments);
    }
};

/// One corner eased: the side before it now ends at `in`, `piece` (an arc or a line) goes
/// on to where the side after it starts, and `cut_in` and `cut_out` are how much of the
/// length of the side before and the side after it takes.
const Corner = struct {
    in: [2]f64,
    piece: path.Segment,
    cut_in: f64,
    cut_out: f64,
};

/// What the sides at a point do: go on straight (no corner), double back on each other,
/// turn at a corner no fillet fits, or turn, at a corner eased.
const Turn = union(enum) { straight, doubles_back, no_fit, eased: Corner };

/// A side of a corner moved the fillet's radius towards the corner's inside: a line
/// through `q` along `d`, or a circle.
const Offset = union(enum) {
    line: struct { q: [2]f64, d: [2]f64 },
    circle: struct { center: [2]f64, radius: f64 },
};

/// The path from `start` along `segments` (none of them a point) with each corner where
/// two lines or arcs meet eased as `how` says. A joint where the path goes on smoothly (an
/// arc leaving along the line before it), or beside a curve, stays as it is; so do the
/// ends of an open path.
/// When `closed`, the last segment ends back at `start` and the corner there is eased too,
/// and the path is given without its last line back to its start, which closing it draws.
/// A segment trimmed to within `tolerance` of nothing is left out. When a corner can't be
/// eased, `failure` says why and the error is error.CornerFailed.
pub fn ease(allocator: std.mem.Allocator, start: [2]f64, segments: []const path.Segment, closed: bool, how: Ease, tolerance: f64, failure: *Failure) Error!Eased {
    const count = segments.len;
    // The corner at each point, where segment i starts
    const corners = try allocator.alloc(?Corner, count);
    defer allocator.free(corners);
    for (corners, 0..) |*c, i| {
        c.* = null;
        if (i == 0 and !closed) continue;
        const before = (i + count - 1) % count;
        if (segments[before].cubic != null or segments[i].cubic != null) continue;
        c.* = switch (turnAt(pointOf(start, segments, before), segments[before], segments[i], how)) {
            .straight => null,
            .doubles_back => {
                failure.* = .{ .doubles_back = i };
                return error.CornerFailed;
            },
            .no_fit => {
                failure.* = .{ .no_fit = i };
                return error.CornerFailed;
            },
            .eased => |eased| eased,
        };
    }

    for (segments, 0..) |segment, k| {
        if (segment.cubic != null) continue;
        const needed = cutOut(corners[k]) + cutIn(cornerAfter(corners, k, closed));
        const length = segment.length(pointOf(start, segments, k));
        if (needed > length + tolerance) {
            failure.* = .{ .too_short = .{ .from = k, .length = length, .needed = needed } };
            return error.CornerFailed;
        }
    }

    var out: std.ArrayList(path.Segment) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, 2 * count);
    var eased_start = start;
    var at = start;
    if (closed) if (corners[0]) |c| {
        eased_start = c.in;
        out.appendAssumeCapacity(c.piece);
        at = c.piece.to;
    };
    for (segments, 0..) |segment, k| {
        const after = cornerAfter(corners, k, closed);
        const cut = cutOut(corners[k]) + cutIn(after);
        var trimmed = segment;
        if (after) |c| trimmed.to = c.in;
        // An arc gives up the sweep of its length the corners take
        if (trimmed.arc) |arc| trimmed.angle -= cut / arc.radius;
        // The line back to the start, which closing draws
        if (closed and k == count - 1 and trimmed.isLine()) break;
        const trimmed_away = cut > 0 and trimmed.length(at) <= tolerance;
        if (!trimmed_away) {
            out.appendAssumeCapacity(trimmed);
            at = trimmed.to;
        }
        if (k + 1 < count) if (after) |c| {
            out.appendAssumeCapacity(c.piece);
            at = c.piece.to;
        };
    }
    return .{ .start = eased_start, .segments = try out.toOwnedSlice(allocator) };
}

/// Where segment `k` starts: the path's start, or the end of the one before.
fn pointOf(start: [2]f64, segments: []const path.Segment, k: usize) [2]f64 {
    return if (k == 0) start else segments[k - 1].to;
}

/// The corner at the end of segment `k`: the next one's, or, closed, the start's.
fn cornerAfter(corners: []const ?Corner, k: usize, closed: bool) ?Corner {
    if (k + 1 < corners.len) return corners[k + 1];
    return if (closed) corners[0] else null;
}

/// How much of the side before it a corner takes.
fn cutIn(c: ?Corner) f64 {
    return if (c) |some| some.cut_in else 0;
}

/// How much of the side after it a corner takes.
fn cutOut(c: ?Corner) f64 {
    return if (c) |some| some.cut_out else 0;
}

/// What the side `before` (from `from`) and the side `after` do where they meet, the
/// corner eased.
fn turnAt(from: [2]f64, before: path.Segment, after: path.Segment, how: Ease) Turn {
    const at = before.to;
    const d1 = path.endTangent(from, &.{before}).?;
    const d2 = path.startTangent(at, after);
    const cross = d1[0] * d2[1] - d1[1] * d2[0];
    const dot = d1[0] * d2[0] + d1[1] * d2[1];
    const turn = @abs(std.math.atan2(cross, dot));
    if (turn <= STRAIGHT_TURN) return .straight;
    if (std.math.pi - turn <= STRAIGHT_TURN) return .doubles_back;
    if (!before.isLine() or !after.isLine()) return switch (how) {
        .round => |r| roundBeside(before, after, d1, d2, cross > 0, r),
        .chamfer => |c| .{ .eased = .{ .in = alongSide(before, at, d1, -c), .piece = .{ .to = alongSide(after, at, d2, c) }, .cut_in = c, .cut_out = c } },
    };
    const cut = switch (how) {
        // r tan(turn / 2), as sin / (1 + cos): exact for a right angle
        .round => |r| r * @abs(cross) / (1 + dot),
        .chamfer => |c| c,
    };
    const in = [2]f64{ at[0] - cut * d1[0], at[1] - cut * d1[1] };
    const out = [2]f64{ at[0] + cut * d2[0], at[1] + cut * d2[1] };
    const piece: path.Segment = switch (how) {
        .round => |r| blk: {
            // The arc's centre is `r` from `in` towards the side the path turns to
            const left = cross > 0;
            const normal: [2]f64 = if (left) .{ -d1[1], d1[0] } else .{ d1[1], -d1[0] };
            const center = [2]f64{ in[0] + r * normal[0], in[1] + r * normal[1] };
            break :blk .{ .to = out, .arc = .{ .center = center, .radius = r }, .ccw = left, .angle = turn };
        },
        .chamfer => .{ .to = out },
    };
    return .{ .eased = .{ .in = in, .piece = piece, .cut_in = cut, .cut_out = cut } };
}

/// The fillet of radius `r` where `before` meets `after` (one of them an arc), leaving
/// along `d1` and on along `d2`, turning `left` or right: its centre where the sides moved
/// `r` inside meet, nearest the corner, and its ends where it touches them.
fn roundBeside(before: path.Segment, after: path.Segment, d1: [2]f64, d2: [2]f64, left: bool, r: f64) Turn {
    const at = before.to;
    const center = nearestMeeting(offsetOf(before, at, d1, left, r) orelse return .no_fit, offsetOf(after, at, d2, left, r) orelse return .no_fit, at) orelse return .no_fit;
    const in = touching(before, at, d1, center);
    const out = touching(after, at, d2, center);
    const cut_in = lengthTo(before, at, d1, in, true) orelse return .no_fit;
    const cut_out = lengthTo(after, at, d2, out, false) orelse return .no_fit;
    const piece = path.Segment{ .to = out, .arc = .{ .center = center, .radius = r }, .ccw = left, .angle = path.sweep(center, in, out, left) };
    return .{ .eased = .{ .in = in, .piece = piece, .cut_in = cut_in, .cut_out = cut_out } };
}

/// The side `segment` (through `at` along `d` there) moved `r` towards the side the corner
/// turns to (`left`): a line along it, or its arc's circle, smaller by `r` when the arc
/// turns that way (its centre on that side) and larger otherwise; null for an arc that
/// turns that way no more widely than `r`.
fn offsetOf(segment: path.Segment, at: [2]f64, d: [2]f64, left: bool, r: f64) ?Offset {
    const n: [2]f64 = if (left) .{ -d[1], d[0] } else .{ d[1], -d[0] };
    const arc = segment.arc orelse return .{ .line = .{ .q = .{ at[0] + r * n[0], at[1] + r * n[1] }, .d = d } };
    const radius = if (segment.ccw == left) arc.radius - r else arc.radius + r;
    if (!(radius > 0)) return null;
    return .{ .circle = .{ .center = arc.center, .radius = radius } };
}

/// Where the offsets `a` and `b` (not both lines) meet nearest `at`; null where they don't.
fn nearestMeeting(a: Offset, b: Offset, at: [2]f64) ?[2]f64 {
    var points: [2][2]f64 = undefined;
    const found = switch (a) {
        .line => |l| lineCircle(l.q, l.d, b.circle.center, b.circle.radius, &points),
        .circle => |c| switch (b) {
            .line => |l| lineCircle(l.q, l.d, c.center, c.radius, &points),
            .circle => |c2| circleCircle(c.center, c.radius, c2.center, c2.radius, &points),
        },
    };
    if (found == 0) return null;
    if (found == 1) return points[0];
    const d0 = std.math.hypot(points[0][0] - at[0], points[0][1] - at[1]);
    const d1 = std.math.hypot(points[1][0] - at[0], points[1][1] - at[1]);
    return if (d0 <= d1) points[0] else points[1];
}

/// Where the line through `q` along the unit `d` meets the circle, into `out`: how many.
fn lineCircle(q: [2]f64, d: [2]f64, center: [2]f64, radius: f64, out: *[2][2]f64) usize {
    // |q + s d - center|² = radius²: s² + 2 b s + c = 0
    const w = [2]f64{ q[0] - center[0], q[1] - center[1] };
    const b = d[0] * w[0] + d[1] * w[1];
    const c = w[0] * w[0] + w[1] * w[1] - radius * radius;
    const disc = b * b - c;
    if (disc < 0) return 0;
    const root = @sqrt(disc);
    for ([_]f64{ -b - root, -b + root }, out) |s, *p| p.* = .{ q[0] + s * d[0], q[1] + s * d[1] };
    return 2;
}

/// Where two circles meet, into `out`: how many.
fn circleCircle(c1: [2]f64, r1: f64, c2: [2]f64, r2: f64, out: *[2][2]f64) usize {
    const dx = c2[0] - c1[0];
    const dy = c2[1] - c1[1];
    const dist = std.math.hypot(dx, dy);
    if (dist == 0 or dist > r1 + r2 or dist < @abs(r1 - r2)) return 0;
    // Along the line of centres to the chord between the meetings, then across it
    const along = (r1 * r1 - r2 * r2 + dist * dist) / (2 * dist);
    const across = @sqrt(@max(0, r1 * r1 - along * along));
    const mid = [2]f64{ c1[0] + along * dx / dist, c1[1] + along * dy / dist };
    out[0] = .{ mid[0] - across * dy / dist, mid[1] + across * dx / dist };
    out[1] = .{ mid[0] + across * dy / dist, mid[1] - across * dx / dist };
    return 2;
}

/// Where a circle about `center` touches the side `segment` (through `at` along `d`): the
/// foot of the centre on a line, the point of an arc's circle towards it.
fn touching(segment: path.Segment, at: [2]f64, d: [2]f64, center: [2]f64) [2]f64 {
    const arc = segment.arc orelse {
        const s = (center[0] - at[0]) * d[0] + (center[1] - at[1]) * d[1];
        return .{ at[0] + s * d[0], at[1] + s * d[1] };
    };
    const u = unit(.{ center[0] - arc.center[0], center[1] - arc.center[1] });
    return .{ arc.center[0] + arc.radius * u[0], arc.center[1] + arc.radius * u[1] };
}

/// How far along the side `segment` (through `at` along `d`) `p` is from `at`: back along
/// it for the side `ending` at `at`, on along it otherwise; null for a point the other way,
/// or (on an arc) more than half its circle round.
fn lengthTo(segment: path.Segment, at: [2]f64, d: [2]f64, p: [2]f64, ending: bool) ?f64 {
    const arc = segment.arc orelse {
        const s = (p[0] - at[0]) * d[0] + (p[1] - at[1]) * d[1];
        const length = if (ending) -s else s;
        return if (length > 0) length else null;
    };
    const angle = if (ending) path.sweep(arc.center, p, at, segment.ccw) else path.sweep(arc.center, at, p, segment.ccw);
    return if (angle > 0 and angle < std.math.pi) arc.radius * angle else null;
}

/// The point `length` along the side `segment` from `at` (through it along `d`), back
/// along it for a negative one: along a line, or round an arc's circle.
fn alongSide(segment: path.Segment, at: [2]f64, d: [2]f64, length: f64) [2]f64 {
    const arc = segment.arc orelse return .{ at[0] + length * d[0], at[1] + length * d[1] };
    const turn = (if (segment.ccw) length else -length) / arc.radius;
    const v = [2]f64{ at[0] - arc.center[0], at[1] - arc.center[1] };
    const c = @cos(turn);
    const s = @sin(turn);
    return .{ arc.center[0] + c * v[0] - s * v[1], arc.center[1] + s * v[0] + c * v[1] };
}

fn unit(d: [2]f64) [2]f64 {
    const len = std.math.hypot(d[0], d[1]);
    return .{ d[0] / len, d[1] / len };
}
