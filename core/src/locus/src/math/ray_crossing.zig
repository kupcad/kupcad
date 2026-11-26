//! Whether a point is inside a planar loop of lines and circular arcs, exactly: the parity
//! of the crossings of the ray from the point to +x with each edge, summed over the loop
//! (docs/architecture.md §6, D26). The one "point in a loop" of the sketch's containment
//! query, the checker's hole rule and a planar face's membership (`sketch/query.zig`,
//! `topology/check.zig`, `query/in_face.zig`): each asked it its own way before, and each
//! way had a case it got wrong (an arc's end heights from a sine against a line's from its
//! vertex; a polygon of four samples an edge; angles summed by halving).
//!
//! Every sign is an exact predicate's (`orient2d`, `inCircle`), so no angle, square root
//! or division decides anything. A vertex at the point's height counts as below it for
//! every edge (the half-open rule). A point on a straight edge's line is on the edge's
//! right, outside a face the edge bounds with the face on its left, as the planar faces'
//! count has always had it (the boolean's paves place a vertex whose foot is on a face's
//! edge by it). Within an arc, a point on a radius or on the circle is answered as the
//! point a hair to the east of it and a lesser hair to the north would be (a symbolic
//! perturbation, `p + (ε, ε²)`), the radii and the sector reading the same nudged point,
//! so their parities still sum to the arc's.
//!
//! An arc needs no cutting into pieces. With its two radii it bounds its sector, so the
//! ray crosses the arc an odd number of times just when the point's being in the sector
//! differs from the parity of its crossings of the two radii. The radii run from the
//! centre to the arc's ends as given, the vertices' own points (which lie off the circle
//! by up to the tolerance): at a vertex's height the arc's radius and the next edge read
//! the same point, as the half-open rule needs.

const std = @import("std");
const predicates = @import("predicates.zig");

comptime {
    @setFloatMode(.strict);
}

const Vec2 = [2]f64;

/// Whether the ray from `p` to +x crosses the segment from `a` to `b`: `p`'s height within
/// the segment's, an end at that height counting as below it (the half-open rule), and `p`
/// west of the segment there; on its line, on its right (west of one going down).
pub fn line(a: Vec2, b: Vec2, p: Vec2) bool {
    if ((a[1] > p[1]) == (b[1] > p[1])) return false;
    // West of the segment: left of one going up, right of one going down
    return (predicates.orient2d(a, b, p) > 0) == (b[1] > a[1]);
}

/// Whether `p` lies on the segment from `a` to `b`, its ends included, exactly. The
/// parity alone answers such a point by its rules at a vertex and along a level edge,
/// which read the loop's direction and the plane's axes (a mirror turns both), so a count
/// that must answer it alike either way asks this first (a planar face's: outside).
pub fn onSegment(a: Vec2, b: Vec2, p: Vec2) bool {
    if (p[0] < @min(a[0], b[0]) or p[0] > @max(a[0], b[0]) or p[1] < @min(a[1], b[1]) or p[1] > @max(a[1], b[1])) return false;
    return predicates.orient2d(a, b, p) == 0;
}

/// `line` for an arc's radius, a point on it read a hair east (`side`): the arc's two
/// radii and its sector must read one point.
fn radius(a: Vec2, b: Vec2, p: Vec2) bool {
    if ((a[1] > p[1]) == (b[1] > p[1])) return false;
    return (side(a, b, p) > 0) == (b[1] > a[1]);
}

/// Whether the ray from `p` to +x crosses the arc from `a` to `b` about `c`, of radius `r`,
/// counter-clockwise when `ccw`, an odd number of times. The same point twice is the full
/// circle.
pub fn arc(a: Vec2, b: Vec2, c: Vec2, r: f64, ccw: bool, p: Vec2) bool {
    return (radius(a, c, p) != radius(c, b, p)) != inSector(a, b, c, r, ccw, p);
}

/// Which side of the line from `u` to `v` the point `p` is on, positive to the left; on
/// the line, the side of the point a hair east of `p` (and, the line level, a hair north).
fn side(u: Vec2, v: Vec2, p: Vec2) f64 {
    const turn = predicates.orient2d(u, v, p);
    if (turn != 0) return turn;
    // (v − u) × (ε, ε²): −(v − u).y·ε leads
    const dy = v[1] - u[1];
    return if (dy != 0) -dy else v[0] - u[0];
}

/// Whether `p` is in the sector the arc and its two radii bound: in the circle, and
/// within the turn from the radius through `a` to the one through `b`.
fn inSector(a: Vec2, b: Vec2, c: Vec2, r: f64, ccw: bool, p: Vec2) bool {
    if (!inDisc(c, r, p)) return false;
    // A clockwise arc from `a` to `b` is the counter-clockwise one from `b` to `a`
    const from = if (ccw) a else b;
    const to = if (ccw) b else a;
    const left_of_from = side(c, from, p) > 0;
    const right_of_to = side(c, to, p) < 0;
    const turn = predicates.orient2d(c, from, to);
    // Under a half turn the two half planes' meeting; over one, all but the other's
    if (turn > 0) return left_of_from and right_of_to;
    if (turn < 0) return left_of_from or right_of_to;
    // The ends on one line through the centre: opposite, a half turn; on one radius, the
    // whole circle when they are one point (an arc of no sweep holds nothing)
    if ((from[0] - c[0]) * (to[0] - c[0]) + (from[1] - c[1]) * (to[1] - c[1]) < 0) return left_of_from;
    return from[0] == to[0] and from[1] == to[1];
}

/// Whether `p` is in the circle; on it, whether the point a hair east of `p` is (a hair
/// north where `p` is straight above or below the centre).
fn inDisc(c: Vec2, r: f64, p: Vec2) bool {
    const within = predicates.inCircle(c, r, p);
    if (within != 0) return within > 0;
    const dx = p[0] - c[0];
    return if (dx != 0) dx < 0 else p[1] < c[1];
}
