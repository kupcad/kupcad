//! A path's corners eased: where two straight segments meet at an angle, the corner is
//! rounded off by the arc that touches both (a fillet) or cut off by a straight line (a
//! chamfer), the two sides giving up the same length to it. What `polygon(round_r:)`,
//! `polygon(chamfer:)` and a Path's `fillet` and `chamfer` make; the arcs are exact, so a
//! drawing writes them as arcs.

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
/// on to where the side after it starts, and `cut` is how far both are from the corner.
const Corner = struct {
    in: [2]f64,
    piece: path.Segment,
    cut: f64,
};

/// What the sides at a point do: go on straight (no corner), double back on each other,
/// or turn, at a corner eased.
const Turn = union(enum) { straight, doubles_back, eased: Corner };

/// The path from `start` along `segments` (none of them a point) with each corner where
/// two straight segments meet eased as `how` says. A corner where the path goes on
/// straight, or beside an arc or a curve, stays as it is; so do the ends of an open path.
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
        if (!segments[before].isLine() or !segments[i].isLine()) continue;
        c.* = switch (turnAt(pointOf(start, segments, before), pointOf(start, segments, i), segments[i].to, how)) {
            .straight => null,
            .doubles_back => {
                failure.* = .{ .doubles_back = i };
                return error.CornerFailed;
            },
            .eased => |eased| eased,
        };
    }

    for (segments, 0..) |segment, k| {
        if (!segment.isLine()) continue;
        const needed = cutOf(corners[k]) + cutOf(cornerAfter(corners, k, closed));
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
        var trimmed = segment;
        if (after) |c| trimmed.to = c.in;
        // The line back to the start, which closing draws
        if (closed and k == count - 1 and trimmed.isLine()) break;
        const trimmed_away = cutOf(corners[k]) + cutOf(after) > 0 and std.math.hypot(trimmed.to[0] - at[0], trimmed.to[1] - at[1]) <= tolerance;
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

fn cutOf(c: ?Corner) f64 {
    return if (c) |some| some.cut else 0;
}

/// What the sides from `from` to `at` and on to `to` do at `at`, the corner eased.
fn turnAt(from: [2]f64, at: [2]f64, to: [2]f64, how: Ease) Turn {
    const d1 = unit(.{ at[0] - from[0], at[1] - from[1] });
    const d2 = unit(.{ to[0] - at[0], to[1] - at[1] });
    const cross = d1[0] * d2[1] - d1[1] * d2[0];
    const dot = d1[0] * d2[0] + d1[1] * d2[1];
    const turn = @abs(std.math.atan2(cross, dot));
    if (turn <= STRAIGHT_TURN) return .straight;
    if (std.math.pi - turn <= STRAIGHT_TURN) return .doubles_back;
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
    return .{ .eased = .{ .in = in, .piece = piece, .cut = cut } };
}

fn unit(d: [2]f64) [2]f64 {
    const len = std.math.hypot(d[0], d[1]);
    return .{ d[0] / len, d[1] / len };
}
