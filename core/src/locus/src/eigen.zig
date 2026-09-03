const std = @import("std");
const math = @import("math.zig");

extern fn locus_eigen_det3(mat: [*]const f64) f64;
extern fn locus_eigen_det4(mat: [*]const f64) f64;
extern fn locus_eigen_pca_normal(pts: [*]const f64, num_pts: c_int, out_normal: [*]f64) void;

pub fn determinant3x3(mat: *const [9]f64) f64 {
    return locus_eigen_det3(mat.ptr);
}

pub fn determinant4x4(mat: *const [16]f64) f64 {
    return locus_eigen_det4(mat.ptr);
}

pub fn pcaNormal(pts: []const math.Vec3) math.Vec3 {
    var normal: math.Vec3 = undefined;
    // Safely cast the contiguous array of [3]f64 directly to a flat f64 pointer
    locus_eigen_pca_normal(@ptrCast(pts.ptr), @intCast(pts.len), &normal);
    return normal;
}

/// Evaluates if point C is Counter-Clockwise (> 0), Clockwise (< 0), or Collinear (0) to line AB.
pub fn orient2D(a: math.Vec2, b: math.Vec2, c: math.Vec2) f64 {
    const mat = [9]f64{
        a[0], a[1], 1.0,
        b[0], b[1], 1.0,
        c[0], c[1], 1.0,
    };
    return determinant3x3(&mat);
}

/// Evaluates if point D lies strictly inside (> 0), outside (< 0), or on (0) the circumcircle of triangle ABC.
/// Assumes ABC is ordered Counter-Clockwise.
pub fn inCircle(a: math.Vec2, b: math.Vec2, c: math.Vec2, d: math.Vec2) f64 {
    const mat = [16]f64{
        a[0], a[1], (a[0] * a[0] + a[1] * a[1]), 1.0,
        b[0], b[1], (b[0] * b[0] + b[1] * b[1]), 1.0,
        c[0], c[1], (c[0] * c[0] + c[1] * c[1]), 1.0,
        d[0], d[1], (d[0] * d[0] + d[1] * d[1]), 1.0,
    };
    return determinant4x4(&mat);
}
