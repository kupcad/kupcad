//! Small dense matrices (3×3 and 4×4, row-major) with determinants and inverses by the
//! adjoint, exact in form so the same input gives the same bytes on every platform, and
//! `Affine`, the rigid moves, scales and mirrors a body is transformed by. Column vectors:
//! a point `p` maps to `M·p + t`.

const vec = @import("vec.zig");
const Vec3 = vec.Vec3;

/// Row-major 3×3: `m[row * 3 + col]`.
pub const Mat3 = [9]f64;
/// Row-major 4×4.
pub const Mat4 = [16]f64;

pub const IDENTITY3: Mat3 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };

pub fn det3(m: *const Mat3) f64 {
    return m[0] * (m[4] * m[8] - m[5] * m[7]) -
        m[1] * (m[3] * m[8] - m[5] * m[6]) +
        m[2] * (m[3] * m[7] - m[4] * m[6]);
}

pub fn det4(m: *const Mat4) f64 {
    const s0 = m[10] * m[15] - m[11] * m[14];
    const s1 = m[9] * m[15] - m[11] * m[13];
    const s2 = m[9] * m[14] - m[10] * m[13];
    const s3 = m[8] * m[15] - m[11] * m[12];
    const s4 = m[8] * m[14] - m[10] * m[12];
    const s5 = m[8] * m[13] - m[9] * m[12];
    return m[0] * (m[5] * s0 - m[6] * s1 + m[7] * s2) -
        m[1] * (m[4] * s0 - m[6] * s3 + m[7] * s4) +
        m[2] * (m[4] * s1 - m[5] * s3 + m[7] * s5) -
        m[3] * (m[4] * s2 - m[5] * s4 + m[6] * s5);
}

/// The inverse by the adjoint, or null when the determinant is zero or not finite. A nearly
/// singular matrix inverts to large numbers; the caller judges them.
pub fn inverse3(m: *const Mat3) ?Mat3 {
    const d = det3(m);
    if (!(d != 0.0) or !(d - d == 0)) return null;
    const inv = 1.0 / d;
    return .{
        (m[4] * m[8] - m[5] * m[7]) * inv, (m[2] * m[7] - m[1] * m[8]) * inv, (m[1] * m[5] - m[2] * m[4]) * inv,
        (m[5] * m[6] - m[3] * m[8]) * inv, (m[0] * m[8] - m[2] * m[6]) * inv, (m[2] * m[3] - m[0] * m[5]) * inv,
        (m[3] * m[7] - m[4] * m[6]) * inv, (m[1] * m[6] - m[0] * m[7]) * inv, (m[0] * m[4] - m[1] * m[3]) * inv,
    };
}

/// The inverse by the adjoint (cofactors of the 3×3 minors), or null when singular.
pub fn inverse4(m: *const Mat4) ?Mat4 {
    var cof: Mat4 = undefined;
    inline for (0..4) |r| {
        inline for (0..4) |c| {
            // The minor without row r and column c
            var minor: Mat3 = undefined;
            var k: usize = 0;
            inline for (0..4) |i| {
                if (i != r) {
                    inline for (0..4) |j| {
                        if (j != c) {
                            minor[k] = m[i * 4 + j];
                            k += 1;
                        }
                    }
                }
            }
            const sign: f64 = if ((r + c) % 2 == 0) 1 else -1;
            cof[r * 4 + c] = sign * det3(&minor);
        }
    }
    // The determinant along the first row, from the cofactors already computed
    const d = m[0] * cof[0] + m[1] * cof[1] + m[2] * cof[2] + m[3] * cof[3];
    if (!(d != 0.0) or !(d - d == 0)) return null;
    const inv = 1.0 / d;
    var out: Mat4 = undefined;
    inline for (0..4) |r| {
        inline for (0..4) |c| out[r * 4 + c] = cof[c * 4 + r] * inv; // the adjoint is the transpose
    }
    return out;
}

pub fn mul3(a: *const Mat3, b: *const Mat3) Mat3 {
    var out: Mat3 = undefined;
    inline for (0..3) |r| {
        inline for (0..3) |c| {
            out[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c];
        }
    }
    return out;
}

pub fn transpose3(m: *const Mat3) Mat3 {
    return .{ m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8] };
}

pub fn apply3(m: *const Mat3, v: Vec3) Vec3 {
    return .{
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    };
}

/// An affine map `p ↦ linear·p + translation`.
pub const Affine = struct {
    linear: Mat3 = IDENTITY3,
    translation: Vec3 = vec.ZERO3,

    pub const identity: Affine = .{};

    pub fn translate(t: Vec3) Affine {
        return .{ .translation = t };
    }

    /// Scale by `s` along each axis about the origin.
    pub fn scaleBy(s: Vec3) Affine {
        return .{ .linear = .{ s[0], 0, 0, 0, s[1], 0, 0, 0, s[2] } };
    }

    /// Rotation by `angle` radians about the unit `axis` through the origin, counter-
    /// clockwise seen from the axis's tip (Rodrigues).
    pub fn rotate(axis: Vec3, angle: f64) Affine {
        const c = @cos(angle);
        const s = @sin(angle);
        const t = 1.0 - c;
        const x = axis[0];
        const y = axis[1];
        const z = axis[2];
        return .{ .linear = .{
            t * x * x + c,     t * x * y - s * z, t * x * z + s * y,
            t * x * y + s * z, t * y * y + c,     t * y * z - s * x,
            t * x * z - s * y, t * y * z + s * x, t * z * z + c,
        } };
    }

    /// Reflection in the plane through the origin with unit normal `n`.
    pub fn mirror(n: Vec3) Affine {
        return .{ .linear = .{
            1 - 2 * n[0] * n[0], -2 * n[0] * n[1],    -2 * n[0] * n[2],
            -2 * n[1] * n[0],    1 - 2 * n[1] * n[1], -2 * n[1] * n[2],
            -2 * n[2] * n[0],    -2 * n[2] * n[1],    1 - 2 * n[2] * n[2],
        } };
    }

    /// From the 3×4 row-major matrix a host gives (KupCAD's `transform`): three rows of
    /// `(m00 m01 m02 t0)`.
    pub fn fromRows(rows: [12]f64) Affine {
        return .{
            .linear = .{ rows[0], rows[1], rows[2], rows[4], rows[5], rows[6], rows[8], rows[9], rows[10] },
            .translation = .{ rows[3], rows[7], rows[11] },
        };
    }

    pub fn point(self: *const Affine, p: Vec3) Vec3 {
        return vec.add(apply3(&self.linear, p), self.translation);
    }

    /// A direction: moved by the linear part alone.
    pub fn vector(self: *const Affine, v: Vec3) Vec3 {
        return apply3(&self.linear, v);
    }

    /// `self` after `first`: `p ↦ self(first(p))`.
    pub fn compose(self: *const Affine, first: *const Affine) Affine {
        return .{
            .linear = mul3(&self.linear, &first.linear),
            .translation = vec.add(apply3(&self.linear, first.translation), self.translation),
        };
    }

    pub fn inverse(self: *const Affine) ?Affine {
        const inv = inverse3(&self.linear) orelse return null;
        return .{ .linear = inv, .translation = vec.neg(apply3(&inv, self.translation)) };
    }

    pub fn determinant(self: *const Affine) f64 {
        return det3(&self.linear);
    }

    /// The matrix normals transform by: the inverse transpose of the linear part, or null
    /// when singular. A mirror (negative determinant) flips the normal's sense too.
    pub fn normalMatrix(self: *const Affine) ?Mat3 {
        const inv = inverse3(&self.linear) orelse return null;
        return transpose3(&inv);
    }

    /// The columns' lengths: the scale along each axis of the source.
    pub fn columnLengths(self: *const Affine) Vec3 {
        const m = &self.linear;
        return .{
            @sqrt(m[0] * m[0] + m[3] * m[3] + m[6] * m[6]),
            @sqrt(m[1] * m[1] + m[4] * m[4] + m[7] * m[7]),
            @sqrt(m[2] * m[2] + m[5] * m[5] + m[8] * m[8]),
        };
    }

    /// The dot products of the columns pairwise: zero when the axes stay orthogonal.
    pub fn columnDots(self: *const Affine) Vec3 {
        const m = &self.linear;
        return .{
            m[0] * m[1] + m[3] * m[4] + m[6] * m[7],
            m[1] * m[2] + m[4] * m[5] + m[7] * m[8],
            m[0] * m[2] + m[3] * m[5] + m[6] * m[8],
        };
    }
};
