//! Where a copy of a part is: the rigid transform its translates and rotates make, as a 3×4
//! matrix (a 3×3 rotation and a translation, columns first, as Manifold's mat3x4). The
//! parts list groups copies by the shape under it, and a 3MF file places each copy of one
//! mesh with it. A rotation is built as the mesh engine builds it (Manifold's
//! CsgNode::Rotate: about x, then y, then z, in degrees, multiples of 90° exact), so a copy
//! lands where the kernel puts it.

const std = @import("std");

/// The full turn's quarter, at which a rotation's sine and cosine are exact.
const QUARTER_TURN = 90.0;

pub const Placement = struct {
    /// Columns: the images of x, y and z, then the translation.
    m: [4][3]f64,

    pub const identity: Placement = .{ .m = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, 0 } } };

    pub fn translation(x: f64, y: f64, z: f64) Placement {
        var p = identity;
        p.m[3] = .{ x, y, z };
        return p;
    }

    /// About x by `x_deg`, then y, then z, as `rotate(x, y, z)` turns a shape.
    pub fn rotation(x_deg: f64, y_deg: f64, z_deg: f64) Placement {
        const rx = axisRotation(0, x_deg);
        const ry = axisRotation(1, y_deg);
        const rz = axisRotation(2, z_deg);
        return rz.then(ry).then(rx);
    }

    /// `self` after `inner`: the placement of a shape `inner` places, placed by `self`.
    pub fn then(self: Placement, inner: Placement) Placement {
        var out: Placement = undefined;
        for (0..4) |col| {
            for (0..3) |row| {
                var sum: f64 = if (col == 3) self.m[3][row] else 0;
                for (0..3) |k| sum += self.m[k][row] * inner.m[col][k];
                out.m[col][row] = sum;
            }
        }
        return out;
    }

    pub fn apply(self: Placement, point: [3]f64) [3]f64 {
        var out: [3]f64 = self.m[3];
        for (0..3) |row| {
            for (0..3) |k| out[row] += self.m[k][row] * point[k];
        }
        return out;
    }

    /// About one axis (0, 1, 2 for x, y, z), as Manifold's rX, rY and rZ.
    fn axisRotation(axis: usize, deg: f64) Placement {
        const s = sinDegrees(deg);
        const c = sinDegrees(deg + QUARTER_TURN);
        var p = identity;
        const a = (axis + 1) % 3;
        const b = (axis + 2) % 3;
        p.m[a][a] = c;
        p.m[a][b] = s;
        p.m[b][a] = -s;
        p.m[b][b] = c;
        return p;
    }
};

/// The sine of `deg` degrees, exact at multiples of 90° (Manifold's sind: the remainder
/// after the nearest quarter turn, in radians, the quadrant picking sine or cosine; a tie
/// goes to the even quarter, as remquo's).
fn sinDegrees(deg: f64) f64 {
    if (!std.math.isFinite(deg)) return std.math.nan(f64);
    if (deg < 0) return -sinDegrees(-deg);
    const ratio = deg / QUARTER_TURN;
    var quarters = @round(ratio);
    if (@abs(ratio - @trunc(ratio)) == 0.5 and @mod(quarters, 2) != 0) quarters -= 1;
    const rest = std.math.degreesToRadians(deg - quarters * QUARTER_TURN);
    return switch (@as(u2, @truncate(@as(u64, @intFromFloat(@mod(quarters, 4)))))) {
        0 => @sin(rest),
        1 => @cos(rest),
        2 => -@sin(rest),
        3 => -@cos(rest),
    };
}
