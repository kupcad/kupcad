//! 3D vectors as `[3]f64`: the few operations the kernels and exporters measure meshes
//! with (a triangle's normal and centroid, how far a point is from one), in one place.

pub fn dot(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn sub(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

pub fn add(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

pub fn scale(v: [3]f64, s: f64) [3]f64 {
    return .{ v[0] * s, v[1] * s, v[2] * s };
}

pub fn cross(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// `v` scaled to unit length; the zero vector for a zero one. A zero component is `0`,
/// never `-0`, so a file written from it reads the same whichever way it was reached.
pub fn normalize(v: [3]f64) [3]f64 {
    const len = @sqrt(dot(v, v));
    if (len == 0) return .{ 0, 0, 0 };
    return .{ v[0] / len + 0.0, v[1] / len + 0.0, v[2] / len + 0.0 };
}

/// The unit normal of the triangle `a`, `b`, `c`, by the right-hand rule (counter-clockwise
/// seen from where it points); the zero vector for a degenerate triangle.
pub fn triangleNormal(a: [3]f64, b: [3]f64, c: [3]f64) [3]f64 {
    return normalize(cross(sub(b, a), sub(c, a)));
}

pub fn centroid(a: [3]f64, b: [3]f64, c: [3]f64) [3]f64 {
    return scale(add(add(a, b), c), 1.0 / 3.0);
}

/// The squared distance from `p` to the triangle `a`, `b`, `c` (its nearest point, on its
/// face, an edge or a corner: Ericson, Real-Time Collision Detection, 5.1.5).
pub fn pointTriangleDistanceSq(p: [3]f64, a: [3]f64, b: [3]f64, c: [3]f64) f64 {
    const nearest = closestPointOnTriangle(p, a, b, c);
    const d = sub(p, nearest);
    return dot(d, d);
}

fn closestPointOnTriangle(p: [3]f64, a: [3]f64, b: [3]f64, c: [3]f64) [3]f64 {
    const ab = sub(b, a);
    const ac = sub(c, a);
    const ap = sub(p, a);
    const d1 = dot(ab, ap);
    const d2 = dot(ac, ap);
    if (d1 <= 0 and d2 <= 0) return a;
    const bp = sub(p, b);
    const d3 = dot(ab, bp);
    const d4 = dot(ac, bp);
    if (d3 >= 0 and d4 <= d3) return b;
    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 and d1 >= 0 and d3 <= 0) return add(a, scale(ab, d1 / (d1 - d3)));
    const cp = sub(p, c);
    const d5 = dot(ab, cp);
    const d6 = dot(ac, cp);
    if (d6 >= 0 and d5 <= d6) return c;
    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 and d2 >= 0 and d6 <= 0) return add(a, scale(ac, d2 / (d2 - d6)));
    const va = d3 * d6 - d5 * d4;
    if (va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0) return add(b, scale(sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6))));
    // Inside the face: barycentric weights of b and c
    const denom = 1.0 / (va + vb + vc);
    return add(a, add(scale(ab, vb * denom), scale(ac, vc * denom)));
}
