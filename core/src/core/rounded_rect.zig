//! Rounded corners: how many chords a quarter arc gets, the points of an arc, and a
//! rectangle with rounded corners (`square(round_r:)`, the profile of `cube(round_r:)`) as
//! the points its graph node evaluates to and the four corner circles those points lie on,
//! which the 2D exporters write as true arcs.

const std = @import("std");

/// How many chords a quarter arc gets when a full circle gets `total`: its share, rounded
/// up. It was rounded down, so a corner the resolution gave 5 to 7 segments a turn (any
/// radius up to about 2.2 mm by default) was one chord, a chamfer.
pub fn quarterArcSegments(total: i32) usize {
    return @max(1, (@as(usize, @intCast(total)) + 3) / 4);
}

/// The points of the arc of radius `r` about (`cx`, `cy`) from `start_ang` to `end_ang`
/// (radians), `segments` chords, both ends included, appended to `pts`.
pub fn appendArc(allocator: std.mem.Allocator, pts: *std.ArrayList([2]f64), cx: f64, cy: f64, r: f64, start_ang: f64, end_ang: f64, segments: usize) !void {
    const step = (end_ang - start_ang) / @as(f64, @floatFromInt(segments));
    for (0..segments + 1) |i| {
        const ang = start_ang + @as(f64, @floatFromInt(i)) * step;
        try pts.append(allocator, .{ cx + r * @cos(ang), cy + r * @sin(ang) });
    }
}

/// A corner's circle, and which of the rectangle's points lie on it: `count` from `first`.
pub const Corner = struct {
    center: [2]f64,
    radius: f64,
    first: usize,
    count: usize,
};

/// A rectangle `x` by `y`, at the origin's corner or centred, its corners rounded to
/// `radius` (no more than half a side) and drawn with the share of `segments` (a full
/// circle's) a quarter gets.
pub const RoundedRect = struct {
    x: f64,
    y: f64,
    center: bool,
    radius: f64,
    segments: i32,

    /// `radius` kept to half the shorter side, where the corners meet.
    pub fn safeRadius(self: RoundedRect) f64 {
        return @min(self.radius, @min(self.x / 2.0, self.y / 2.0));
    }

    /// The corners counter-clockwise from the bottom right, each a quarter arc of its
    /// circle, as `appendPoints` lays the points out.
    pub fn corners(self: RoundedRect) [4]Corner {
        const r = self.safeRadius();
        const hw = self.x / 2.0;
        const hh = self.y / 2.0;
        const cx = if (self.center) 0.0 else hw;
        const cy = if (self.center) 0.0 else hh;
        const per_corner = quarterArcSegments(self.segments) + 1;
        const centers = [4][2]f64{
            .{ cx + hw - r, cy - hh + r },
            .{ cx + hw - r, cy + hh - r },
            .{ cx - hw + r, cy + hh - r },
            .{ cx - hw + r, cy - hh + r },
        };
        var out: [4]Corner = undefined;
        for (centers, &out, 0..) |c, *corner, i| corner.* = .{ .center = c, .radius = r, .first = i * per_corner, .count = per_corner };
        return out;
    }

    /// The outline's points, counter-clockwise: each corner's arc in turn, from -90°.
    pub fn appendPoints(self: RoundedRect, allocator: std.mem.Allocator, pts: *std.ArrayList([2]f64)) !void {
        const chords = quarterArcSegments(self.segments);
        for (self.corners(), 0..) |corner, i| {
            const start = -std.math.pi / 2.0 + @as(f64, @floatFromInt(i)) * std.math.pi / 2.0;
            try appendArc(allocator, pts, corner.center[0], corner.center[1], corner.radius, start, start + std.math.pi / 2.0, chords);
        }
    }
};
