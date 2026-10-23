//! Engine-independent 2D geometry: point-in-region tests over polygon contours.

const std = @import("std");
const segmentDistanceSq = @import("../core/affine2.zig").segmentDistanceSq;

pub const Vec2 = [2]f64;

/// Signed contribution of the edge a -> b to the winding number around `p`
/// (Sunday's crossing rule: +1 for an upward edge with `p` on its left, -1 for a
/// downward edge with `p` on its right).
pub fn edgeWinding(a: Vec2, b: Vec2, p: Vec2) i32 {
    const cross = (b[0] - a[0]) * (p[1] - a[1]) - (p[0] - a[0]) * (b[1] - a[1]);
    if (a[1] <= p[1]) {
        if (b[1] > p[1] and cross > 0) return 1;
    } else if (b[1] <= p[1] and cross < 0) {
        return -1;
    }
    return 0;
}

/// Accumulates the contours of a region and answers whether `point` lies in it.
///
/// The region is closed: a point within `tolerance` of any edge counts as inside, which
/// is what a CAD user means by "on the outline". Otherwise the nonzero winding rule
/// decides, so holes work as long as they wind opposite to their outer contour (Manifold
/// normalizes cross sections that way: outer contours counter-clockwise, holes clockwise).
pub const RegionTest = struct {
    point: Vec2,
    tolerance_sq: f64,
    winding: i32 = 0,
    on_boundary: bool = false,

    pub fn init(point: Vec2, tolerance: f64) RegionTest {
        return .{ .point = point, .tolerance_sq = tolerance * tolerance };
    }

    pub fn addEdge(self: *RegionTest, a: Vec2, b: Vec2) void {
        if (self.on_boundary) return;
        if (segmentDistanceSq(a, b, self.point) <= self.tolerance_sq) {
            self.on_boundary = true;
            return;
        }
        self.winding += edgeWinding(a, b, self.point);
    }

    pub fn contains(self: RegionTest) bool {
        return self.on_boundary or self.winding != 0;
    }
};

/// Whether the closed ring (anything with `len()` and `at(i)`, so engines test their
/// contours in place without copying them) is convex, collinear points allowed. A region
/// with holes or several outlines is never convex, so callers pass exactly one contour.
pub fn isConvexRing(ring: anytype) bool {
    const n = ring.len();
    if (n < 3) return false;
    var sign: f64 = 0;
    for (0..n) |i| {
        const p = ring.at(i);
        const q = ring.at((i + 1) % n);
        const r = ring.at((i + 2) % n);
        const cross = (q[0] - p[0]) * (r[1] - q[1]) - (q[1] - p[1]) * (r[0] - q[0]);
        if (cross == 0) continue;
        if (sign == 0) {
            sign = std.math.sign(cross);
        } else if (std.math.sign(cross) != sign) {
            return false;
        }
    }
    return sign != 0;
}
