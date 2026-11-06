const std = @import("std");
const testing = std.testing;
const vec = @import("vec.zig");
const mat = @import("mat.zig");
const Vec3 = vec.Vec3;
const Mat3 = mat.Mat3;
const Mat4 = mat.Mat4;

test "mat: determinants and inverses by the adjoint" {
    const m3 = Mat3{ 1, 2, 3, 0, 1, 4, 5, 6, 0 };
    try testing.expectEqual(@as(f64, 1), mat.det3(&m3));
    const inv3 = mat.inverse3(&m3).?;
    const id = mat.mul3(&m3, &inv3);
    for (id, mat.IDENTITY3) |got, want| try testing.expectApproxEqAbs(want, got, 1e-14);
    try testing.expectEqual(@as(?Mat3, null), mat.inverse3(&Mat3{ 1, 2, 3, 2, 4, 6, 0, 0, 1 }));

    const m4 = Mat4{ 2, 0, 0, 1, 0, 3, 0, 2, 0, 0, 4, 3, 0, 0, 0, 1 };
    try testing.expectEqual(@as(f64, 24), mat.det4(&m4));
    const inv4 = mat.inverse4(&m4).?;
    // M · M⁻¹ = I
    for (0..4) |r| {
        for (0..4) |c| {
            var s: f64 = 0;
            for (0..4) |k| s += m4[r * 4 + k] * inv4[k * 4 + c];
            try testing.expectApproxEqAbs(@as(f64, if (r == c) 1 else 0), s, 1e-14);
        }
    }
    try testing.expectEqual(@as(?Mat4, null), mat.inverse4(&Mat4{ 1, 2, 3, 4, 2, 4, 6, 8, 0, 0, 1, 0, 0, 0, 0, 1 }));
}

test "mat: affine maps compose, invert, and move normals by the inverse transpose" {
    const r = mat.Affine.rotate(vec.Z3, std.math.pi / 2.0);
    const p = r.point(.{ 1, 0, 0 });
    try testing.expectApproxEqAbs(@as(f64, 0), p[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1), p[1], 1e-15);

    const t = mat.Affine.translate(.{ 10, 0, 0 });
    const both = t.compose(&r); // rotate, then translate
    const q = both.point(.{ 1, 0, 0 });
    try testing.expectApproxEqAbs(@as(f64, 10), q[0], 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 1), q[1], 1e-14);
    const back = both.inverse().?.point(q);
    try testing.expectApproxEqAbs(@as(f64, 1), back[0], 1e-14);
    try testing.expectApproxEqAbs(@as(f64, 0), back[1], 1e-14);

    const s = mat.Affine.scaleBy(.{ 2, 1, 1 });
    try testing.expectEqual(@as(f64, 2), s.determinant());
    // A normal of a plane x = const under a stretch in x shrinks in x: (1,0,0) ↦ (1/2,0,0)
    const n = mat.apply3(&s.normalMatrix().?, vec.X3);
    try testing.expectEqual(Vec3{ 0.5, 0, 0 }, n);

    const m = mat.Affine.mirror(vec.Z3);
    try testing.expectEqual(@as(f64, -1), m.determinant());
    try testing.expectEqual(Vec3{ 1, 2, -3 }, m.point(.{ 1, 2, 3 }));

    const rows = mat.Affine.fromRows(.{ 1, 0, 0, 5, 0, 1, 0, 6, 0, 0, 1, 7 });
    try testing.expectEqual(Vec3{ 6, 8, 10 }, rows.point(.{ 1, 2, 3 }));
    try testing.expectEqual(Vec3{ 1, 1, 1 }, rows.columnLengths());
    try testing.expectEqual(vec.ZERO3, rows.columnDots());
}
