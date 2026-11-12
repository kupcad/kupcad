//! Where a curve meets a surface (docs/architecture.md §7.2). So far a curve against a
//! plane (`curvePlane`), which a plane section reads off a body's edges: the parameters
//! where an edge's range crosses or touches the plane, in closed form for lines, circles
//! and ellipses; an edge that lies in the plane over its whole range (within the zone) is
//! told apart, since all of it is on the section. A NURBS edge waits for M5's subdivision
//! and Newton.

const std = @import("std");
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
const curves = @import("../geometry/curves.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Vec3 = vec.Vec3;
const Curve = curves.Curve;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;
const TWO_PI = geometry.TWO_PI;

/// The most crossings a line, circle or ellipse has with a plane over one range: two
/// roots, and the range's ends when they lie on the plane.
pub const MAX_CROSSINGS = 4;

/// The plane `n·p = d`, `n` unit.
pub const Plane = struct {
    n: Vec3,
    d: f64,

    /// The horizontal plane `z = at`.
    pub fn level(at: f64) Plane {
        return .{ .n = vec.Z3, .d = at };
    }

    /// How far `p` lies above the plane (along `n`).
    pub fn height(self: Plane, p: Vec3) f64 {
        return vec.dot(self.n, p) - self.d;
    }
};

/// Where a curve's range meets a plane: its parameters there in increasing order, or the
/// whole range when it lies in the plane.
pub const Crossings = struct {
    /// The range lies within the zone of the plane from end to end.
    lies_in: bool = false,
    count: u8 = 0,
    t: [MAX_CROSSINGS]f64 = undefined,

    pub fn params(self: *const Crossings) []const f64 {
        return self.t[0..self.count];
    }

    /// Adds `t` unless a parameter within `same` of it is there already.
    fn add(self: *Crossings, t: f64, same: f64) void {
        for (self.t[0..self.count]) |u| if (@abs(u - t) <= same) return;
        if (self.count == MAX_CROSSINGS) return;
        self.t[self.count] = t;
        self.count += 1;
        std.mem.sort(f64, self.t[0..self.count], {}, std.sort.asc(f64));
    }
};

/// Where `curve` over `[t0, t1]` meets `plane`: each end within the zone of it, and each
/// root of the curve's height above it inside the range (a root where the curve only
/// touches the plane is one crossing); or `lies_in` when every point of the range is within
/// the zone. A NURBS curve is `NotImplemented` (M5).
pub fn curvePlane(curve: Curve, t0: f64, t1: f64, plane: Plane, tol: Tolerance, diag: *Diagnostics) Error!Crossings {
    return switch (curve) {
        .line => |line| linePlane(line, t0, t1, plane, tol),
        .circle => |circle| conicPlane(circle.c, vec.scale(circle.x, circle.r), vec.scale(circle.y, circle.r), circle.r, t0, t1, plane, tol),
        .ellipse => |ellipse| conicPlane(ellipse.c, vec.scale(ellipse.x, ellipse.a), vec.scale(ellipse.y, ellipse.b), @max(ellipse.a, ellipse.b), t0, t1, plane, tol),
        .nurbs => diagnostics.notImplemented(diag, "a plane's crossings with a free-form edge", 5),
    };
}

/// A line's height is linear in `t`: its ends decide.
fn linePlane(line: curves.Line, t0: f64, t1: f64, plane: Plane, tol: Tolerance) Crossings {
    var out: Crossings = .{};
    const h0 = plane.height(line.eval(t0));
    const h1 = plane.height(line.eval(t1));
    const on0 = @abs(h0) <= tol.zone;
    const on1 = @abs(h1) <= tol.zone;
    if (on0 and on1) return .{ .lies_in = true };
    if (on0) out.add(t0, 0);
    if (on1) out.add(t1, 0);
    if (!on0 and !on1 and (h0 < 0) != (h1 < 0)) out.add(t0 + (t1 - t0) * h0 / (h0 - h1), 0);
    return out;
}

/// A circle's or an ellipse's height, `b + A·cos t + B·sin t` (its centre's height and its
/// axes' `x`, `y` scaled by their radii, projected on the normal): `lies_in` when no point
/// of the range is further than the zone, else the ends on the plane and the roots
/// `t = φ ± acos(−b/m)` (`m = √(A² + B²)`, `φ = atan2(B, A)`) taken into the range, a root
/// within the zone of touching being one. `radius` turns the zone into a parameter step.
fn conicPlane(c: Vec3, x: Vec3, y: Vec3, radius: f64, t0: f64, t1: f64, plane: Plane, tol: Tolerance) Crossings {
    var out: Crossings = .{};
    const b = plane.height(c);
    const a_cos = vec.dot(plane.n, x);
    const b_sin = vec.dot(plane.n, y);
    const m = @sqrt(a_cos * a_cos + b_sin * b_sin);
    const phi = trig.atan2(b_sin, a_cos);
    const height = struct {
        fn at(bb: f64, ac: f64, bs: f64, t: f64) f64 {
            return bb + ac * @cos(t) + bs * @sin(t);
        }
    }.at;
    // The range's extreme heights: its ends and the turns inside it
    var high = @max(@abs(height(b, a_cos, b_sin, t0)), @abs(height(b, a_cos, b_sin, t1)));
    for ([_]f64{ phi, phi + std.math.pi }) |turn| {
        const t = into(turn, t0);
        if (t <= t1) high = @max(high, @abs(height(b, a_cos, b_sin, t)));
    }
    if (high <= tol.zone) return .{ .lies_in = true };
    const same = tol.zone / radius;
    // A whole turn ends where it starts: its end is its start's crossing
    const whole = t1 - t0 >= TWO_PI - same;
    const last = if (whole) t1 - same else t1;
    if (@abs(height(b, a_cos, b_sin, t0)) <= tol.zone) out.add(t0, same);
    if (!whole and @abs(height(b, a_cos, b_sin, t1)) <= tol.zone) out.add(t1, same);
    if (m == 0) return out;
    const k = -b / m;
    // Beyond reach by more than the zone: no root; within it of the extreme: a touch
    if (@abs(k) * m > m + tol.zone) return out;
    // cos(t − φ) = k: a touch at the turn itself when k reaches 1, half a turn from it
    // when k reaches −1
    const spread = if (k >= 1) 0 else if (k <= -1) std.math.pi else std.math.acos(k);
    for ([_]f64{ phi - spread, phi + spread }) |root| {
        const t = into(root, t0 - same);
        if (t <= last + same) out.add(std.math.clamp(t, t0, last), same);
    }
    return out;
}

/// `t` moved by whole turns to the first value at or after `from`.
fn into(t: f64, from: f64) f64 {
    return t + TWO_PI * @ceil((from - t) / TWO_PI);
}
