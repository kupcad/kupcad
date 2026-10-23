//! Frames along a polyline in space, for a sweep's profile: each segment's, carried
//! through each corner by the corner's own rotation (about its bend's axis, which takes the
//! way in to the way out), so the profile doesn't twist about the path (the discrete
//! rotation-minimizing frame, parallel transport). Around a closed loop off a plane that
//! comes back turned by the loop's own twist (its holonomy), so a closed polyline's frames
//! are also twisted evenly along its length by as much the other way: the profile meets
//! itself where it started.

const std = @import("std");
const vec3 = @import("vec3.zig");

/// A turn (radians) this small at a corner is none.
pub const STRAIGHT_TURN = 1e-9;
/// A direction this close to straight up or down (its z) starts a frame with its v along y,
/// as up can't be across it.
const VERTICAL_SLACK = 1e-9;

/// The profile's directions in space: its x along `u`, its y along `v`, swept along u × v.
pub const Frame = struct {
    u: [3]f64,
    v: [3]f64,

    /// The frame for a path leaving along `t` (a unit vector): `v` as near up (z) as `t`
    /// allows, or y for a path straight up or down, and `u` to the path's left.
    pub fn along(t: [3]f64) Frame {
        const up: [3]f64 = if (@abs(t[2]) > 1 - VERTICAL_SLACK) .{ 0, 1, 0 } else .{ 0, 0, 1 };
        const v = vec3.normalize(vec3.sub(up, vec3.scale(t, vec3.dot(up, t))));
        return .{ .u = vec3.cross(v, t), .v = v };
    }

    /// The frame turned `angle` radians about the unit `axis` (Rodrigues' rotation).
    pub fn turned(self: Frame, axis: [3]f64, angle: f64) Frame {
        return .{ .u = rotated(self.u, axis, angle), .v = rotated(self.v, axis, angle) };
    }
};

/// How a path turns at a corner: about `axis` by `angle` (radians; 0, no turn, for one that
/// goes on straight).
pub const Bend = struct { axis: [3]f64, angle: f64 };

/// The bend from the unit direction `t1` to `t2`: about t1 × t2, or, for a path that
/// doubles back (where that is none), about `fallback`.
pub fn bendAt(t1: [3]f64, t2: [3]f64, fallback: [3]f64) Bend {
    const cross = vec3.cross(t1, t2);
    const sin = std.math.sqrt(vec3.dot(cross, cross));
    const angle = std.math.atan2(sin, vec3.dot(t1, t2));
    if (angle <= STRAIGHT_TURN) return .{ .axis = fallback, .angle = 0 };
    return .{ .axis = if (sin > STRAIGHT_TURN) vec3.scale(cross, 1 / sin) else fallback, .angle = angle };
}

/// A segment's frame where it starts, and how far (radians) it twists about the segment
/// along it.
pub const Leg = struct { frame: Frame, twist: f64 };

/// The legs of the polyline through `points` (two or more, none repeating the one before
/// it): its first segment's frame `Frame.along` it, each next one's turned by the corner
/// before it, and for a `closed` one (its last point on its first) each twisted by its
/// share of the length of the turn that brings the frame back to its start. Owned by
/// `allocator`.
pub fn legs(allocator: std.mem.Allocator, points: []const [3]f64, closed: bool) ![]Leg {
    const count = points.len - 1;
    const out = try allocator.alloc(Leg, count);
    errdefer allocator.free(out);
    var frame = Frame.along(direction(points[0], points[1]));
    for (out, 0..) |*leg, k| {
        if (k > 0) frame = turnedAt(frame, direction(points[k - 1], points[k]), direction(points[k], points[k + 1]));
        leg.* = .{ .frame = frame, .twist = 0 };
    }
    if (!closed) return out;
    // Round the last corner, back on the first segment: how far the frame is turned from
    // where it started, about that segment
    const t0 = direction(points[0], points[1]);
    const back = turnedAt(frame, direction(points[count - 1], points[count]), t0);
    const start = out[0].frame.u;
    const holonomy = std.math.atan2(vec3.dot(vec3.cross(start, back.u), t0), vec3.dot(start, back.u));
    var total: f64 = 0;
    for (0..count) |k| total += std.math.sqrt(distanceSq(points[k], points[k + 1]));
    var done: f64 = 0;
    for (out, 0..) |*leg, k| {
        const share = std.math.sqrt(distanceSq(points[k], points[k + 1])) / total;
        // Turned by the twist of the legs before it (a twist about a leg carries through a
        // corner as one about the next), then twisting by its own share
        leg.frame = leg.frame.turned(direction(points[k], points[k + 1]), done);
        leg.twist = -holonomy * share;
        done += leg.twist;
    }
    return out;
}

/// The frame of the way in, `t1`, turned through the corner onto the way out, `t2`.
pub fn turnedAt(frame: Frame, t1: [3]f64, t2: [3]f64) Frame {
    const bend = bendAt(t1, t2, frame.v);
    return if (bend.angle == 0) frame else frame.turned(bend.axis, bend.angle);
}

fn rotated(w: [3]f64, axis: [3]f64, angle: f64) [3]f64 {
    const c = @cos(angle);
    const s = @sin(angle);
    return vec3.add(vec3.add(vec3.scale(w, c), vec3.scale(vec3.cross(axis, w), s)), vec3.scale(axis, vec3.dot(axis, w) * (1 - c)));
}

pub fn distanceSq(a: [3]f64, b: [3]f64) f64 {
    const d = vec3.sub(b, a);
    return vec3.dot(d, d);
}

/// The unit vector from `a` to `b`, two different points.
pub fn direction(a: [3]f64, b: [3]f64) [3]f64 {
    return vec3.normalize(vec3.sub(b, a));
}
