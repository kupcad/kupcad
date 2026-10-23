//! Where a copy of a part is: the rigid transform its translates and rotates make, as a 3×4
//! matrix (a 3×3 rotation and a translation, columns first, as Manifold's mat3x4). The
//! parts list groups copies by the shape under it, and a 3MF file places each copy of one
//! mesh with it. A rotation is built as the mesh engine builds it (Manifold's
//! CsgNode::Rotate: about x, then y, then z, in degrees, multiples of 90° exact), so a copy
//! lands where the kernel puts it.

const std = @import("std");

/// The full turn's quarter, at which a rotation's sine and cosine are exact.
const QUARTER_TURN = 90.0;
/// How near a quarter turn an angle taken from a matrix is that quarter turn: far below any
/// angle a model means, far above the rounding atan2 leaves.
const SNAP_DEGREES = 1e-9;
/// Past this cosine of the y angle, x and z still turn about lines of their own.
const GIMBAL_COS = 1e-12;

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

/// The angles `Placement.rotation(x, y, z)` takes to turn `deg` degrees right-handedly
/// about `axis` (through the origin, any length but zero): a turn about any axis as a
/// rotate, which the kernel and the parts list read as they read any. Rodrigues' matrix,
/// taken apart as rotation composes it (about x, then y, then z); an angle within
/// SNAP_DEGREES of a quarter turn is that quarter turn, so a turn of 90° about an axis
/// stays exact.
pub fn eulerOfAxisAngle(axis: [3]f64, deg: f64) [3]f64 {
    const len = @sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
    const k = [3]f64{ axis[0] / len, axis[1] / len, axis[2] / len };
    const s = sinDegrees(deg);
    const c = sinDegrees(deg + QUARTER_TURN);
    const t = 1 - c;
    // r[row][col]
    const r = [3][3]f64{
        .{ c + k[0] * k[0] * t, k[0] * k[1] * t - k[2] * s, k[0] * k[2] * t + k[1] * s },
        .{ k[1] * k[0] * t + k[2] * s, c + k[1] * k[1] * t, k[1] * k[2] * t - k[0] * s },
        .{ k[2] * k[0] * t - k[1] * s, k[2] * k[1] * t + k[0] * s, c + k[2] * k[2] * t },
    };
    // Rz(γ)·Ry(β)·Rx(α): r[2][0] = -sin β, r[2][1] = cos β sin α, r[1][0] = cos β sin γ
    const beta = std.math.asin(std.math.clamp(-r[2][0], -1, 1));
    const cos_beta = @cos(beta);
    const alpha, const gamma = if (@abs(cos_beta) > GIMBAL_COS)
        .{ std.math.atan2(r[2][1], r[2][2]), std.math.atan2(r[1][0], r[0][0]) }
    else
        // Straight up or down: x and z turn about one line, so all of it is z's
        .{ 0.0, std.math.atan2(-r[0][1], r[1][1]) };
    return .{ snapped(std.math.radiansToDegrees(alpha)), snapped(std.math.radiansToDegrees(beta)), snapped(std.math.radiansToDegrees(gamma)) };
}

fn snapped(deg: f64) f64 {
    const quarters = @round(deg / QUARTER_TURN) * QUARTER_TURN;
    return if (@abs(deg - quarters) <= SNAP_DEGREES) quarters else deg;
}

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
