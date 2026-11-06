//! NURBS curves and surfaces: the algorithms of The NURBS Book (Piegl & Tiller, 2nd ed.) by
//! their numbers. Curves are clamped, of degree at most `MAX_DEGREE`, rational through
//! 4-D control points `(wx, wy, wz, w)` with positive weights, so one code path serves the
//! polynomial and the rational case (A3.1, A4.2). Knots are stored as the full vector
//! `U[0..m]`, `m = n + p + 1`, which is what every algorithm here indexes; repeated knots
//! are exact copies (the insertion and refinement here make them so), and a STEP writer
//! runs them into distinct values with multiplicities.
//!
//! Views (`Curve`, `Curve2`, `Surface`) borrow their slices from the arena's pools; owned
//! data (`CurveData`, `SurfaceData`) is what the constructors and knot algorithms return.

const std = @import("std");
const vec = @import("../math/vec.zig");
const solve = @import("../math/solve.zig");
const types = @import("types.zig");
const curves = @import("curves.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;
const Domain = types.Domain;
const Box2 = types.Box2;
const Box3 = types.Box3;

/// The highest degree a curve or a surface direction may have (STEP allows more; nothing
/// Locus builds needs it).
pub const MAX_DEGREE: usize = 9;
/// The highest derivative order the evaluators give: second, for curvature and the
/// projection's Jacobian.
pub const MAX_DERIV: usize = 2;
/// Samples per knot span when seeding a projection (§6.1 starts Newton from samples).
const PROJECT_SAMPLES_PER_SPAN: usize = 4;
/// The largest arc one rational quadratic piece covers (A7.1: pieces of at most 90°).
const MAX_ARC_PER_PIECE: f64 = std.math.pi / 2.0;

pub const Error = error{OutOfMemory};

// ---------------------------------------------------------------------------------------
// Basis functions (ch. 2)

/// A2.1: the knot span index `i` with `U[i] <= u < U[i+1]`, for `u` in `[U[p], U[n+1]]`;
/// `u == U[n+1]` gives `n` (the last non-empty span), so the end is evaluated too.
pub fn findSpan(n: usize, p: usize, u: f64, knots: []const f64) usize {
    if (u >= knots[n + 1]) return n;
    if (u <= knots[p]) return p;
    var low = p;
    var high = n + 1;
    var mid = (low + high) / 2;
    while (u < knots[mid] or u >= knots[mid + 1]) {
        if (u < knots[mid]) high = mid else low = mid;
        mid = (low + high) / 2;
    }
    return mid;
}

pub const Basis = [MAX_DEGREE + 1]f64;
pub const BasisDers = [MAX_DERIV + 1][MAX_DEGREE + 1]f64;

/// A2.2: the `p+1` basis functions that are nonzero at `u` in span `i`, `N[0..p]`,
/// division-free (no 0/0 at repeated knots).
pub fn basisFuns(i: usize, u: f64, p: usize, knots: []const f64, out: *Basis) void {
    var left: Basis = undefined;
    var right: Basis = undefined;
    out[0] = 1.0;
    var j: usize = 1;
    while (j <= p) : (j += 1) {
        left[j] = u - knots[i + 1 - j];
        right[j] = knots[i + j] - u;
        var saved: f64 = 0.0;
        var r: usize = 0;
        while (r < j) : (r += 1) {
            const temp = out[r] / (right[r + 1] + left[j - r]);
            out[r] = saved + right[r + 1] * temp;
            saved = left[j - r] * temp;
        }
        out[j] = saved;
    }
}

/// A2.3: the basis functions and their derivatives to order `n_ders` (at most `MAX_DERIV`
/// and `p`) at `u` in span `i`: `out[k][j]` is the k-th derivative of `N_{i-p+j,p}`.
pub fn dersBasisFuns(i: usize, u: f64, p: usize, n_ders: usize, knots: []const f64, out: *BasisDers) void {
    var ndu: [MAX_DEGREE + 1][MAX_DEGREE + 1]f64 = undefined;
    var left: Basis = undefined;
    var right: Basis = undefined;
    ndu[0][0] = 1.0;
    var j: usize = 1;
    while (j <= p) : (j += 1) {
        left[j] = u - knots[i + 1 - j];
        right[j] = knots[i + j] - u;
        var saved: f64 = 0.0;
        var r: usize = 0;
        while (r < j) : (r += 1) {
            // Lower triangle: the knot differences; upper: the basis functions
            ndu[j][r] = right[r + 1] + left[j - r];
            const temp = ndu[r][j - 1] / ndu[j][r];
            ndu[r][j] = saved + right[r + 1] * temp;
            saved = left[j - r] * temp;
        }
        ndu[j][j] = saved;
    }
    j = 0;
    while (j <= p) : (j += 1) out[0][j] = ndu[j][p];
    const n = @min(n_ders, p);
    var a: [2][MAX_DEGREE + 1]f64 = undefined;
    var r: usize = 0;
    while (r <= p) : (r += 1) {
        var s1: usize = 0;
        var s2: usize = 1;
        a[0][0] = 1.0;
        var k: usize = 1;
        while (k <= n) : (k += 1) {
            var d: f64 = 0.0;
            const rk = @as(isize, @intCast(r)) - @as(isize, @intCast(k));
            const pk = p - k;
            if (r >= k) {
                a[s2][0] = a[s1][0] / ndu[pk + 1][@intCast(rk)];
                d = a[s2][0] * ndu[@intCast(rk)][pk];
            }
            const j1: usize = if (rk >= -1) 1 else @intCast(-rk);
            const j2: usize = if (@as(isize, @intCast(r)) - 1 <= @as(isize, @intCast(pk))) k - 1 else p - r;
            j = j1;
            while (j <= j2) : (j += 1) {
                a[s2][j] = (a[s1][j] - a[s1][j - 1]) / ndu[pk + 1][@intCast(rk + @as(isize, @intCast(j)))];
                d += a[s2][j] * ndu[@intCast(rk + @as(isize, @intCast(j)))][pk];
            }
            if (r <= pk) {
                a[s2][k] = -a[s1][k - 1] / ndu[pk + 1][r];
                d += a[s2][k] * ndu[r][pk];
            }
            out[k][r] = d;
            std.mem.swap(usize, &s1, &s2);
        }
    }
    // Multiply by the factorials p! / (p − k)!
    var rr: f64 = @floatFromInt(p);
    var k: usize = 1;
    while (k <= n) : (k += 1) {
        j = 0;
        while (j <= p) : (j += 1) out[k][j] *= rr;
        rr *= @floatFromInt(p - k);
    }
    // Orders past p are zero
    k = n + 1;
    while (k <= MAX_DERIV) : (k += 1) {
        j = 0;
        while (j <= p) : (j += 1) out[k][j] = 0.0;
    }
}

// ---------------------------------------------------------------------------------------
// Rational derivatives (A4.2, A4.4)

/// Binomial coefficients to order `MAX_DERIV`.
const BINOMIAL: [MAX_DERIV + 1][MAX_DERIV + 1]f64 = .{ .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 2, 1 } };

/// A4.2: the derivatives of the rational curve to order `MAX_DERIV` from those of its
/// homogeneous form: `C^(k) = (A^(k) − Σ_{i=1..k} C(k,i) w^(i) C^(k−i)) / w`.
fn rationalCurveDers(hom: *const [MAX_DERIV + 1]Vec4) [MAX_DERIV + 1]Vec3 {
    var out: [MAX_DERIV + 1]Vec3 = undefined;
    var k: usize = 0;
    while (k <= MAX_DERIV) : (k += 1) {
        var v = Vec3{ hom[k][0], hom[k][1], hom[k][2] };
        var i: usize = 1;
        while (i <= k) : (i += 1) {
            v = vec.addScaled(v, out[k - i], -BINOMIAL[k][i] * hom[i][3]);
        }
        out[k] = vec.scale(v, 1.0 / hom[0][3]);
    }
    return out;
}

// ---------------------------------------------------------------------------------------
// Curves

/// A NURBS curve as a view over the arena's pools (or over `CurveData`).
pub const Curve = struct {
    degree: u8,
    knots: []const f64,
    points: []const Vec4,

    /// `n`: the last control point's index.
    fn n(self: Curve) usize {
        return self.points.len - 1;
    }

    pub fn domain(self: Curve) Domain {
        return .{ .t0 = self.knots[self.degree], .t1 = self.knots[self.points.len] };
    }

    /// Whether the data is a clamped curve this module can evaluate: degree in range,
    /// enough points, `knots.len == points.len + degree + 1`, knots non-decreasing and
    /// finite, the ends of multiplicity `degree + 1`, interior multiplicities at most
    /// `degree`, a non-empty domain, finite points with positive weights.
    pub fn isValid(self: Curve) bool {
        const p = self.degree;
        if (p < 1 or p > MAX_DEGREE) return false;
        if (self.points.len < p + 1) return false;
        if (self.knots.len != self.points.len + p + 1) return false;
        if (!knotsValid(self.knots, p)) return false;
        for (self.points) |q| {
            if (!(q[3] > 0.0)) return false;
            for (q) |c| if (!(c - c == 0)) return false;
        }
        return true;
    }

    /// A3.1 with A4.1: the point at `t` (clamped to the domain).
    pub fn eval(self: Curve, t: f64) Vec3 {
        return vec.project4(self.evalHomogeneous(t));
    }

    pub fn evalHomogeneous(self: Curve, t: f64) Vec4 {
        const p = self.degree;
        const u = std.math.clamp(t, self.knots[p], self.knots[self.points.len]);
        const span = findSpan(self.n(), p, u, self.knots);
        var basis: Basis = undefined;
        basisFuns(span, u, p, self.knots, &basis);
        var c: Vec4 = .{ 0, 0, 0, 0 };
        var i: usize = 0;
        while (i <= p) : (i += 1) c = vec.addScaled4(c, self.points[span - p + i], basis[i]);
        return c;
    }

    /// A3.2 with A4.2: the point and its first two derivatives at `t`.
    pub fn sample(self: Curve, t: f64) Sample {
        const p = self.degree;
        const u = std.math.clamp(t, self.knots[p], self.knots[self.points.len]);
        const span = findSpan(self.n(), p, u, self.knots);
        var ders: BasisDers = undefined;
        dersBasisFuns(span, u, p, MAX_DERIV, self.knots, &ders);
        var hom: [MAX_DERIV + 1]Vec4 = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } };
        var k: usize = 0;
        while (k <= MAX_DERIV) : (k += 1) {
            var i: usize = 0;
            while (i <= p) : (i += 1) hom[k] = vec.addScaled4(hom[k], self.points[span - p + i], ders[k][i]);
        }
        const r = rationalCurveDers(&hom);
        return .{ .p = r[0], .d1 = r[1], .d2 = r[2] };
    }

    /// §6.1: the parameter nearest `target`, Newton from the nearest of a few samples per
    /// span; `eps` the point tolerance, `max_steps` the Newton bound.
    pub fn project(self: Curve, target: Vec3, eps: f64, max_steps: u32) f64 {
        const seed = self.projectSeed(target);
        return refineProjection(.{ .nurbs = self }, target, seed, eps, max_steps);
    }

    fn projectSeed(self: Curve, target: Vec3) f64 {
        const dom = self.domain();
        var best = dom.t0;
        var best_d = std.math.inf(f64);
        const p = self.degree;
        var span = p;
        while (span <= self.n()) : (span += 1) {
            const a = self.knots[span];
            const b = self.knots[span + 1];
            if (!(b > a)) continue;
            var s: usize = 0;
            while (s <= PROJECT_SAMPLES_PER_SPAN) : (s += 1) {
                const t = a + (b - a) * @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(PROJECT_SAMPLES_PER_SPAN));
                const d = vec.distanceSq(self.eval(t), target);
                if (d < best_d) {
                    best_d = d;
                    best = t;
                }
            }
        }
        return best;
    }

    /// The box of the control points whose spans cover `[t0, t1]` (the convex hull
    /// property, P3.5): a bound on the curve there.
    pub fn bounds(self: Curve, t0: f64, t1: f64) Box3 {
        const p = self.degree;
        const first = findSpan(self.n(), p, t0, self.knots);
        const last = findSpan(self.n(), p, t1, self.knots);
        var box = Box3.empty;
        var i = first - p;
        while (i <= last) : (i += 1) box.grow(vec.project4(self.points[i]));
        return box;
    }

    pub fn toOwned(self: Curve, allocator: std.mem.Allocator) Error!CurveData {
        return .{
            .degree = self.degree,
            .knots = try allocator.dupe(f64, self.knots),
            .points = try allocator.dupe(Vec4, self.points),
        };
    }
};

pub const Sample = struct { p: Vec3, d1: Vec3, d2: Vec3 };

/// Newton (§6.1) from `seed` on any curve, through math/solve.zig.
pub fn refineProjection(curve: curves.Curve, target: Vec3, seed: f64, eps: f64, max_steps: u32) f64 {
    const Ctx = struct {
        curve: curves.Curve,
        fn sample(self: @This(), t: f64) solve.CurveSample {
            const s = self.curve.sample(t);
            return .{ .p = s.p, .d1 = s.d1, .d2 = s.d2 };
        }
    };
    const dom = curve.domain();
    const r = solve.projectToCurve(Ctx{ .curve = curve }, Ctx.sample, target, seed, .{ .range = .{ dom.t0, dom.t1 }, .periodic = dom.periodic }, eps, eps, max_steps);
    return r.t;
}

/// A curve in UV: homogeneous `(wx, wy, w)` control points.
pub const Curve2 = struct {
    degree: u8,
    knots: []const f64,
    points: []const Vec3,

    fn n(self: Curve2) usize {
        return self.points.len - 1;
    }

    pub fn domain(self: Curve2) Domain {
        return .{ .t0 = self.knots[self.degree], .t1 = self.knots[self.points.len] };
    }

    pub fn isValid(self: Curve2) bool {
        const p = self.degree;
        if (p < 1 or p > MAX_DEGREE) return false;
        if (self.points.len < p + 1) return false;
        if (self.knots.len != self.points.len + p + 1) return false;
        if (!knotsValid(self.knots, p)) return false;
        for (self.points) |q| {
            if (!(q[2] > 0.0)) return false;
            for (q) |c| if (!(c - c == 0)) return false;
        }
        return true;
    }

    pub fn eval(self: Curve2, t: f64) Vec2 {
        const h = self.evalHomogeneous(t);
        return .{ h[0] / h[2], h[1] / h[2] };
    }

    fn evalHomogeneous(self: Curve2, t: f64) Vec3 {
        const p = self.degree;
        const u = std.math.clamp(t, self.knots[p], self.knots[self.points.len]);
        const span = findSpan(self.n(), p, u, self.knots);
        var basis: Basis = undefined;
        basisFuns(span, u, p, self.knots, &basis);
        var c: Vec3 = .{ 0, 0, 0 };
        var i: usize = 0;
        while (i <= p) : (i += 1) c = vec.addScaled(c, self.points[span - p + i], basis[i]);
        return c;
    }

    /// The point and its first derivative (A3.2, A4.2 to first order).
    pub fn sample(self: Curve2, t: f64) Sample2 {
        const p = self.degree;
        const u = std.math.clamp(t, self.knots[p], self.knots[self.points.len]);
        const span = findSpan(self.n(), p, u, self.knots);
        var ders: BasisDers = undefined;
        dersBasisFuns(span, u, p, 1, self.knots, &ders);
        var a: Vec3 = .{ 0, 0, 0 };
        var da: Vec3 = .{ 0, 0, 0 };
        var i: usize = 0;
        while (i <= p) : (i += 1) {
            a = vec.addScaled(a, self.points[span - p + i], ders[0][i]);
            da = vec.addScaled(da, self.points[span - p + i], ders[1][i]);
        }
        const w = a[2];
        const pt = Vec2{ a[0] / w, a[1] / w };
        return .{ .p = pt, .d1 = .{ (da[0] - da[2] * pt[0]) / w, (da[1] - da[2] * pt[1]) / w } };
    }

    pub fn bounds(self: Curve2, t0: f64, t1: f64) Box2 {
        const p = self.degree;
        const first = findSpan(self.n(), p, t0, self.knots);
        const last = findSpan(self.n(), p, t1, self.knots);
        var box = Box2.empty;
        var i = first - p;
        while (i <= last) : (i += 1) box.grow(.{ self.points[i][0] / self.points[i][2], self.points[i][1] / self.points[i][2] });
        return box;
    }
};

pub const Sample2 = struct { p: Vec2, d1: Vec2 };

/// Whether `knots` is a clamped knot vector of degree `p`: finite, non-decreasing, end
/// multiplicities `p+1`, interior multiplicities at most `p`, and a non-empty domain.
pub fn knotsValid(knots: []const f64, p: usize) bool {
    const m = knots.len - 1;
    if (knots.len < 2 * (p + 1)) return false;
    for (knots) |k| if (!(k - k == 0)) return false;
    var i: usize = 1;
    while (i <= m) : (i += 1) if (knots[i] < knots[i - 1]) return false;
    i = 0;
    while (i <= p) : (i += 1) if (knots[i] != knots[0] or knots[m - i] != knots[m]) return false;
    if (!(knots[p] < knots[m - p])) return false;
    // Interior multiplicity at most p
    i = p + 1;
    while (i < m - p) {
        var run: usize = 1;
        while (i + run < m - p and knots[i + run] == knots[i]) run += 1;
        if (run > p) return false;
        i += run;
    }
    return true;
}

// ---------------------------------------------------------------------------------------
// Owned curves and the knot algorithms (ch. 5)

/// A curve that owns its arrays.
pub const CurveData = struct {
    degree: u8,
    knots: []f64,
    points: []Vec4,

    pub fn deinit(self: *CurveData, allocator: std.mem.Allocator) void {
        allocator.free(self.knots);
        allocator.free(self.points);
        self.* = undefined;
    }

    pub fn view(self: *const CurveData) Curve {
        return .{ .degree = self.degree, .knots = self.knots, .points = self.points };
    }

    /// §6.5: the same curve run the other way: `Q_i = P_{n−i}`, the knots mirrored in the
    /// domain, so `C̄(a + b − t) = C(t)`.
    pub fn reverse(self: *CurveData) void {
        std.mem.reverse(Vec4, self.points);
        const a = self.knots[0];
        const b = self.knots[self.knots.len - 1];
        std.mem.reverse(f64, self.knots);
        for (self.knots) |*k| k.* = a + b - k.*;
    }

    /// A5.1: the curve with the knot `u` inserted `r` times (`r + its multiplicity <= p`);
    /// the same curve, with `r` more control points.
    pub fn insertKnot(self: *const CurveData, allocator: std.mem.Allocator, u: f64, r: usize) Error!CurveData {
        const p = self.degree;
        const n = self.points.len - 1;
        const k = findSpan(n, p, u, self.knots);
        // s: the multiplicity u already has
        var s: usize = 0;
        var i: usize = k;
        while (self.knots[i] == u) : (i -= 1) {
            s += 1;
            if (i == 0) break;
        }
        std.debug.assert(r + s <= p);
        const knots = try allocator.alloc(f64, self.knots.len + r);
        errdefer allocator.free(knots);
        const points = try allocator.alloc(Vec4, self.points.len + r);
        errdefer allocator.free(points);
        // The new knot vector
        i = 0;
        while (i <= k) : (i += 1) knots[i] = self.knots[i];
        i = 1;
        while (i <= r) : (i += 1) knots[k + i] = u;
        i = k + 1;
        while (i < self.knots.len) : (i += 1) knots[i + r] = self.knots[i];
        // The points not affected
        i = 0;
        while (i + p >= k + 1 and i <= k - p) : (i += 1) {}
        i = 0;
        while (i <= k - p) : (i += 1) points[i] = self.points[i];
        i = k - s;
        while (i <= n) : (i += 1) points[i + r] = self.points[i];
        var rw: [MAX_DEGREE + 1]Vec4 = undefined;
        i = 0;
        while (i <= p - s) : (i += 1) rw[i] = self.points[k - p + i];
        var j: usize = 1;
        var l: usize = 0;
        while (j <= r) : (j += 1) {
            l = k - p + j;
            i = 0;
            while (i <= p - j - s) : (i += 1) {
                const alpha = (u - self.knots[l + i]) / (self.knots[i + k + 1] - self.knots[l + i]);
                rw[i] = vec.add4(vec.scale4(rw[i + 1], alpha), vec.scale4(rw[i], 1.0 - alpha));
            }
            points[l] = rw[0];
            points[k + r - j - s] = rw[p - j - s];
        }
        i = l + 1;
        while (i < k - s) : (i += 1) points[i] = rw[i - l];
        return .{ .degree = self.degree, .knots = knots, .points = points };
    }

    /// A5.4: the curve with the sorted knots `x` (each within the domain) inserted in one
    /// pass; the same curve, with `x.len` more control points.
    pub fn refineKnots(self: *const CurveData, allocator: std.mem.Allocator, x: []const f64) Error!CurveData {
        if (x.len == 0) return .{ .degree = self.degree, .knots = try allocator.dupe(f64, self.knots), .points = try allocator.dupe(Vec4, self.points) };
        const p = self.degree;
        const n = self.points.len - 1;
        const m = n + p + 1;
        const r = x.len - 1;
        const a = findSpan(n, p, x[0], self.knots);
        const b = findSpan(n, p, x[r], self.knots) + 1;
        const knots = try allocator.alloc(f64, self.knots.len + x.len);
        errdefer allocator.free(knots);
        const points = try allocator.alloc(Vec4, self.points.len + x.len);
        errdefer allocator.free(points);
        var j: usize = 0;
        while (j <= a - p) : (j += 1) points[j] = self.points[j];
        j = b - 1;
        while (j <= n) : (j += 1) points[j + r + 1] = self.points[j];
        j = 0;
        while (j <= a) : (j += 1) knots[j] = self.knots[j];
        j = b + p;
        while (j <= m) : (j += 1) knots[j + r + 1] = self.knots[j];
        var i: usize = b + p - 1;
        var k: usize = b + p + r;
        var jj: isize = @intCast(r);
        while (jj >= 0) : (jj -= 1) {
            const xj = x[@intCast(jj)];
            while (xj <= self.knots[i] and i > a) {
                points[k - p - 1] = self.points[i - p - 1];
                knots[k] = self.knots[i];
                k -= 1;
                i -= 1;
            }
            points[k - p - 1] = points[k - p];
            var l: usize = 1;
            while (l <= p) : (l += 1) {
                const ind = k - p + l;
                var alfa = knots[k + l] - xj;
                if (@abs(alfa) == 0.0) {
                    points[ind - 1] = points[ind];
                } else {
                    alfa = alfa / (knots[k + l] - self.knots[i - p + l]);
                    points[ind - 1] = vec.add4(vec.scale4(points[ind - 1], alfa), vec.scale4(points[ind], 1.0 - alfa));
                }
            }
            knots[k] = xj;
            k -= 1;
        }
        return .{ .degree = self.degree, .knots = knots, .points = points };
    }

    /// The piece of the curve over `[t0, t1]` (inside the domain, `t0 < t1`) as a clamped
    /// curve of its own: `t0` and `t1` inserted to multiplicity `p` (A5.1), then the control
    /// points whose basis functions live between them.
    pub fn segment(self: *const CurveData, allocator: std.mem.Allocator, t0: f64, t1: f64) Error!CurveData {
        const p = self.degree;
        var with_start = try self.insertToMultiplicity(allocator, t0, p);
        defer with_start.deinit(allocator);
        var with_both = try with_start.insertToMultiplicity(allocator, t1, p);
        defer with_both.deinit(allocator);
        // L: the last copy of t0; F: the first copy of t1
        var last_start: usize = 0;
        var first_end: usize = 0;
        for (with_both.knots, 0..) |k, i| {
            if (k == t0) last_start = i;
            if (k == t1 and first_end == 0) first_end = i;
        }
        const first_point = last_start - p;
        const count = first_end - last_start + p;
        const points = try allocator.dupe(Vec4, with_both.points[first_point .. first_point + count]);
        errdefer allocator.free(points);
        const knots = try allocator.alloc(f64, count + p + 1);
        var i: usize = 0;
        while (i <= p) : (i += 1) {
            knots[i] = t0;
            knots[knots.len - 1 - i] = t1;
        }
        const interior = with_both.knots[last_start + 1 .. first_end];
        @memcpy(knots[p + 1 .. p + 1 + interior.len], interior);
        return .{ .degree = p, .knots = knots, .points = points };
    }

    /// The curve with `u` at multiplicity `target` (inserted as many times as it lacks).
    fn insertToMultiplicity(self: *const CurveData, allocator: std.mem.Allocator, u: f64, target: usize) Error!CurveData {
        var have: usize = 0;
        for (self.knots) |k| have += @intFromBool(k == u);
        if (have >= target) return .{ .degree = self.degree, .knots = try allocator.dupe(f64, self.knots), .points = try allocator.dupe(Vec4, self.points) };
        return self.insertKnot(allocator, u, target - have);
    }

    /// A5.6: the curve as its Bézier segments, each `p+1` control points, in order: the
    /// same curve span by span.
    pub fn decompose(self: *const CurveData, allocator: std.mem.Allocator) Error![][]Vec4 {
        const p = self.degree;
        const n = self.points.len - 1;
        const m = n + p + 1;
        // Count the non-empty spans
        var spans: usize = 0;
        var i: usize = p;
        while (i < m - p) : (i += 1) {
            if (self.knots[i + 1] > self.knots[i]) spans += 1;
        }
        const out = try allocator.alloc([]Vec4, spans);
        var made: usize = 0;
        errdefer {
            for (out[0..made]) |seg| allocator.free(seg);
            allocator.free(out);
        }
        var seg: usize = 0;
        while (seg < spans) : (seg += 1) {
            out[seg] = try allocator.alloc(Vec4, p + 1);
            made += 1;
        }
        var a: usize = p;
        var b: usize = p + 1;
        var nb: usize = 0;
        i = 0;
        while (i <= p) : (i += 1) out[0][i] = self.points[i];
        var alphas: [MAX_DEGREE + 1]f64 = undefined;
        while (b < m) {
            i = b;
            while (b < m and self.knots[b + 1] == self.knots[b]) b += 1;
            const mult = b - i + 1;
            if (mult < p) {
                const numer = self.knots[b] - self.knots[a];
                var j: usize = p;
                while (j > mult) : (j -= 1) alphas[j - mult - 1] = numer / (self.knots[a + j] - self.knots[a]);
                const r = p - mult;
                j = 1;
                while (j <= r) : (j += 1) {
                    const save = r - j;
                    const s = mult + j;
                    var k: usize = p;
                    while (k >= s) : (k -= 1) {
                        const alpha = alphas[k - s];
                        out[nb][k] = vec.add4(vec.scale4(out[nb][k], alpha), vec.scale4(out[nb][k - 1], 1.0 - alpha));
                    }
                    if (b < m) out[nb + 1][save] = out[nb][p];
                }
            }
            nb += 1;
            if (b < m) {
                i = p - mult;
                while (i <= p) : (i += 1) out[nb][i] = self.points[b - p + i];
                a = b;
                b += 1;
            }
        }
        return out;
    }
};

// ---------------------------------------------------------------------------------------
// Curve constructors (ch. 7, 8)

/// A line segment from `a` to `b` as a degree-1 curve over `[t0, t1]`.
pub fn lineSegment(allocator: std.mem.Allocator, a: Vec3, b: Vec3, t0: f64, t1: f64) Error!CurveData {
    const knots = try allocator.dupe(f64, &.{ t0, t0, t1, t1 });
    errdefer allocator.free(knots);
    const points = try allocator.dupe(Vec4, &.{ vec.weighted(a, 1), vec.weighted(b, 1) });
    return .{ .degree = 1, .knots = knots, .points = points };
}

/// A7.1: the arc of the circle `c + r(cos θ·x + sin θ·y)` from `start` to `end` (`end >
/// start`, at most a full turn) as a rational quadratic of pieces of at most 90°, each with
/// the middle weight `cos(Δθ/2)` and double interior knots. The parameter runs over
/// `[start, end]` and is the angle at each piece's ends and middle, not in between (a
/// rational quadratic cannot follow the angle): the curve is the circle, its
/// parameterization its own.
pub fn circleArc(allocator: std.mem.Allocator, c: Vec3, x: Vec3, y: Vec3, r: f64, start: f64, end: f64) Error!CurveData {
    const sweep = end - start;
    const pieces: usize = @intFromFloat(@ceil(sweep / MAX_ARC_PER_PIECE - 1e-9));
    const narcs = @max(pieces, 1);
    const dtheta = sweep / @as(f64, @floatFromInt(narcs));
    const n = 2 * narcs; // last control point index
    const points = try allocator.alloc(Vec4, n + 1);
    errdefer allocator.free(points);
    const knots = try allocator.alloc(f64, n + 4);
    errdefer allocator.free(knots);
    const w1 = @cos(dtheta / 2.0);
    var p0 = vec.add(c, vec.add(vec.scale(x, r * @cos(start)), vec.scale(y, r * @sin(start))));
    var t0 = vec.add(vec.scale(x, -@sin(start)), vec.scale(y, @cos(start)));
    points[0] = vec.weighted(p0, 1);
    var index: usize = 0;
    var angle = start;
    var i: usize = 1;
    while (i <= narcs) : (i += 1) {
        angle += dtheta;
        const p2 = vec.add(c, vec.add(vec.scale(x, r * @cos(angle)), vec.scale(y, r * @sin(angle))));
        points[index + 2] = vec.weighted(p2, 1);
        const t2 = vec.add(vec.scale(x, -@sin(angle)), vec.scale(y, @cos(angle)));
        // The middle point: where the end tangents meet, at distance r·tan(Δθ/2) along t0
        const p1 = vec.addScaled(p0, t0, r * @tan(dtheta / 2.0));
        points[index + 1] = vec.weighted(p1, w1);
        index += 2;
        if (i < narcs) {
            p0 = p2;
            t0 = t2;
        }
    }
    // Knots: start (3), the piece boundaries doubled, end (3), in the angle parameter
    knots[0] = start;
    knots[1] = start;
    knots[2] = start;
    i = 1;
    while (i < narcs) : (i += 1) {
        const k = start + dtheta * @as(f64, @floatFromInt(i));
        knots[2 * i + 1] = k;
        knots[2 * i + 2] = k;
    }
    knots[n + 1] = end;
    knots[n + 2] = end;
    knots[n + 3] = end;
    return .{ .degree = 2, .knots = knots, .points = points };
}

/// The arc of the ellipse `c + a cos θ·x + b sin θ·y`: the circle arc's control points under
/// the affine map that scales `x` by `a` and `y` by `b` (a rational quadratic stays exact
/// under an affine map).
pub fn ellipseArc(allocator: std.mem.Allocator, c: Vec3, x: Vec3, y: Vec3, a: f64, b: f64, start: f64, end: f64) Error!CurveData {
    const arc = try circleArc(allocator, vec.ZERO3, vec.X3, vec.Y3, 1.0, start, end);
    for (arc.points) |*q| {
        // (wx, wy, wz, w) in the unit circle's frame → c + a·wx·x + b·wy·y, weight kept
        const w = q[3];
        const mapped = vec.add(vec.scale(c, w), vec.add(vec.scale(x, a * q[0]), vec.scale(y, b * q[1])));
        q.* = .{ mapped[0], mapped[1], mapped[2], w };
    }
    return arc;
}

// ---------------------------------------------------------------------------------------
// Surfaces

/// A NURBS surface as a view: control points row-major with `u` fastest, `points[i + j *
/// count_u]` for `i` along `u` and `j` along `v`.
pub const Surface = struct {
    degree_u: u8,
    degree_v: u8,
    knots_u: []const f64,
    knots_v: []const f64,
    count_u: u32,
    count_v: u32,
    points: []const Vec4,

    pub fn domainU(self: Surface) Domain {
        return .{ .t0 = self.knots_u[self.degree_u], .t1 = self.knots_u[self.count_u] };
    }

    pub fn domainV(self: Surface) Domain {
        return .{ .t0 = self.knots_v[self.degree_v], .t1 = self.knots_v[self.count_v] };
    }

    pub fn isValid(self: Surface) bool {
        const p = self.degree_u;
        const q = self.degree_v;
        if (p < 1 or p > MAX_DEGREE or q < 1 or q > MAX_DEGREE) return false;
        if (self.count_u < p + 1 or self.count_v < q + 1) return false;
        if (self.points.len != @as(usize, self.count_u) * self.count_v) return false;
        if (self.knots_u.len != self.count_u + p + 1 or self.knots_v.len != self.count_v + q + 1) return false;
        if (!knotsValid(self.knots_u, p) or !knotsValid(self.knots_v, q)) return false;
        for (self.points) |pt| {
            if (!(pt[3] > 0.0)) return false;
            for (pt) |c| if (!(c - c == 0)) return false;
        }
        return true;
    }

    fn point(self: Surface, i: usize, j: usize) Vec4 {
        return self.points[i + j * self.count_u];
    }

    /// A3.5 with A4.3: the point at `(u, v)`.
    pub fn eval(self: Surface, u: f64, v: f64) Vec3 {
        const p = self.degree_u;
        const q = self.degree_v;
        const uu = std.math.clamp(u, self.knots_u[p], self.knots_u[self.count_u]);
        const vv = std.math.clamp(v, self.knots_v[q], self.knots_v[self.count_v]);
        const su = findSpan(self.count_u - 1, p, uu, self.knots_u);
        const sv = findSpan(self.count_v - 1, q, vv, self.knots_v);
        var nu: Basis = undefined;
        var nv: Basis = undefined;
        basisFuns(su, uu, p, self.knots_u, &nu);
        basisFuns(sv, vv, q, self.knots_v, &nv);
        var s: Vec4 = .{ 0, 0, 0, 0 };
        var l: usize = 0;
        while (l <= q) : (l += 1) {
            var temp: Vec4 = .{ 0, 0, 0, 0 };
            var k: usize = 0;
            while (k <= p) : (k += 1) temp = vec.addScaled4(temp, self.point(su - p + k, sv - q + l), nu[k]);
            s = vec.addScaled4(s, temp, nv[l]);
        }
        return vec.project4(s);
    }

    /// A3.6 with A4.4: the point and its derivatives to second order at `(u, v)`.
    pub fn sample(self: Surface, u: f64, v: f64) SurfaceSample {
        const p = self.degree_u;
        const q = self.degree_v;
        const uu = std.math.clamp(u, self.knots_u[p], self.knots_u[self.count_u]);
        const vv = std.math.clamp(v, self.knots_v[q], self.knots_v[self.count_v]);
        const su = findSpan(self.count_u - 1, p, uu, self.knots_u);
        const sv = findSpan(self.count_v - 1, q, vv, self.knots_v);
        var du: BasisDers = undefined;
        var dv: BasisDers = undefined;
        dersBasisFuns(su, uu, p, MAX_DERIV, self.knots_u, &du);
        dersBasisFuns(sv, vv, q, MAX_DERIV, self.knots_v, &dv);
        // hom[k][l]: the (k, l)-th derivative of the homogeneous surface
        var hom: [MAX_DERIV + 1][MAX_DERIV + 1]Vec4 = undefined;
        var k: usize = 0;
        while (k <= MAX_DERIV) : (k += 1) {
            var l: usize = 0;
            while (l <= MAX_DERIV) : (l += 1) {
                var acc: Vec4 = .{ 0, 0, 0, 0 };
                if (k + l <= MAX_DERIV) {
                    var jj: usize = 0;
                    while (jj <= q) : (jj += 1) {
                        var temp: Vec4 = .{ 0, 0, 0, 0 };
                        var ii: usize = 0;
                        while (ii <= p) : (ii += 1) temp = vec.addScaled4(temp, self.point(su - p + ii, sv - q + jj), du[k][ii]);
                        acc = vec.addScaled4(acc, temp, dv[l][jj]);
                    }
                }
                hom[k][l] = acc;
            }
        }
        // A4.4 to second order
        const w = hom[0][0][3];
        const s = vec.scale(xyz(hom[0][0]), 1.0 / w);
        const s_u = vec.scale(vec.addScaled(xyz(hom[1][0]), s, -hom[1][0][3]), 1.0 / w);
        const s_v = vec.scale(vec.addScaled(xyz(hom[0][1]), s, -hom[0][1][3]), 1.0 / w);
        var t = vec.addScaled(xyz(hom[2][0]), s_u, -2.0 * hom[1][0][3]);
        t = vec.addScaled(t, s, -hom[2][0][3]);
        const s_uu = vec.scale(t, 1.0 / w);
        t = vec.addScaled(xyz(hom[0][2]), s_v, -2.0 * hom[0][1][3]);
        t = vec.addScaled(t, s, -hom[0][2][3]);
        const s_vv = vec.scale(t, 1.0 / w);
        t = vec.addScaled(xyz(hom[1][1]), s_u, -hom[0][1][3]);
        t = vec.addScaled(t, s_v, -hom[1][0][3]);
        t = vec.addScaled(t, s, -hom[1][1][3]);
        const s_uv = vec.scale(t, 1.0 / w);
        return .{ .p = s, .du = s_u, .dv = s_v, .duu = s_uu, .duv = s_uv, .dvv = s_vv };
    }

    /// §6.1: the parameters nearest `target`, Newton from the nearest of a few samples per
    /// span pair.
    pub fn project(self: Surface, target: Vec3, eps: f64, max_steps: u32) Vec2 {
        var best = Vec2{ self.knots_u[self.degree_u], self.knots_v[self.degree_v] };
        var best_d = std.math.inf(f64);
        var su: usize = self.degree_u;
        while (su < self.count_u) : (su += 1) {
            const a = self.knots_u[su];
            const b = self.knots_u[su + 1];
            if (!(b > a)) continue;
            var sv: usize = self.degree_v;
            while (sv < self.count_v) : (sv += 1) {
                const c = self.knots_v[sv];
                const d = self.knots_v[sv + 1];
                if (!(d > c)) continue;
                var i: usize = 0;
                while (i <= PROJECT_SAMPLES_PER_SPAN) : (i += 1) {
                    const uu = a + (b - a) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(PROJECT_SAMPLES_PER_SPAN));
                    var j: usize = 0;
                    while (j <= PROJECT_SAMPLES_PER_SPAN) : (j += 1) {
                        const vv = c + (d - c) * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(PROJECT_SAMPLES_PER_SPAN));
                        const dist = vec.distanceSq(self.eval(uu, vv), target);
                        if (dist < best_d) {
                            best_d = dist;
                            best = .{ uu, vv };
                        }
                    }
                }
            }
        }
        return refineSurfaceProjection(self, target, best, eps, max_steps);
    }

    /// The box of the control points whose spans cover the UV box: a bound on the patch.
    pub fn bounds(self: Surface, box: Box2) Box3 {
        const p = self.degree_u;
        const q = self.degree_v;
        const u_first = findSpan(self.count_u - 1, p, box.min[0], self.knots_u) - p;
        const u_last = findSpan(self.count_u - 1, p, box.max[0], self.knots_u);
        const v_first = findSpan(self.count_v - 1, q, box.min[1], self.knots_v) - q;
        const v_last = findSpan(self.count_v - 1, q, box.max[1], self.knots_v);
        var out = Box3.empty;
        var j = v_first;
        while (j <= v_last) : (j += 1) {
            var i = u_first;
            while (i <= u_last) : (i += 1) out.grow(vec.project4(self.point(i, j)));
        }
        return out;
    }

    pub fn toOwned(self: Surface, allocator: std.mem.Allocator) Error!SurfaceData {
        const knots_u = try allocator.dupe(f64, self.knots_u);
        errdefer allocator.free(knots_u);
        const knots_v = try allocator.dupe(f64, self.knots_v);
        errdefer allocator.free(knots_v);
        const points = try allocator.dupe(Vec4, self.points);
        return .{ .degree_u = self.degree_u, .degree_v = self.degree_v, .knots_u = knots_u, .knots_v = knots_v, .count_u = self.count_u, .count_v = self.count_v, .points = points };
    }
};

pub const SurfaceSample = struct { p: Vec3, du: Vec3, dv: Vec3, duu: Vec3, duv: Vec3, dvv: Vec3 };

fn xyz(h: Vec4) Vec3 {
    return .{ h[0], h[1], h[2] };
}

/// Newton (§6.1) on any surface from `seed`, through math/solve.zig.
pub fn refineSurfaceProjection(surface: anytype, target: Vec3, seed: Vec2, eps: f64, max_steps: u32) Vec2 {
    const Ctx = struct {
        surface: @TypeOf(surface),
        fn sample(self: @This(), u: f64, v: f64) solve.SurfaceSample {
            const s = self.surface.sample(u, v);
            return .{ .p = s.p, .du = s.du, .dv = s.dv, .duu = s.duu, .duv = s.duv, .dvv = s.dvv };
        }
    };
    const du = surface.domainU();
    const dv = surface.domainV();
    const r = solve.projectToSurface(Ctx{ .surface = surface }, Ctx.sample, target, seed, .{
        .u = .{ .range = .{ du.t0, du.t1 }, .periodic = du.periodic },
        .v = .{ .range = .{ dv.t0, dv.t1 }, .periodic = dv.periodic },
    }, eps, eps, max_steps);
    return r.uv;
}

/// A surface that owns its arrays.
pub const SurfaceData = struct {
    degree_u: u8,
    degree_v: u8,
    knots_u: []f64,
    knots_v: []f64,
    count_u: u32,
    count_v: u32,
    points: []Vec4,

    pub fn deinit(self: *SurfaceData, allocator: std.mem.Allocator) void {
        allocator.free(self.knots_u);
        allocator.free(self.knots_v);
        allocator.free(self.points);
        self.* = undefined;
    }

    pub fn view(self: *const SurfaceData) Surface {
        return .{ .degree_u = self.degree_u, .degree_v = self.degree_v, .knots_u = self.knots_u, .knots_v = self.knots_v, .count_u = self.count_u, .count_v = self.count_v, .points = self.points };
    }

    pub const Direction = enum { u, v };

    /// A5.5: the surface with the sorted knots `x` inserted along `direction`, every row (or
    /// column) of control points refined as a curve (A5.4); the same surface.
    pub fn refineKnots(self: *const SurfaceData, allocator: std.mem.Allocator, direction: Direction, x: []const f64) Error!SurfaceData {
        const along_u = direction == .u;
        const degree = if (along_u) self.degree_u else self.degree_v;
        const knots = if (along_u) self.knots_u else self.knots_v;
        const lines: usize = if (along_u) self.count_v else self.count_u;
        const per_line: usize = if (along_u) self.count_u else self.count_v;
        const new_per_line = per_line + x.len;
        const points = try allocator.alloc(Vec4, new_per_line * lines);
        errdefer allocator.free(points);
        var new_knots: ?[]f64 = null;
        errdefer if (new_knots) |k| allocator.free(k);
        const line = try allocator.alloc(Vec4, per_line);
        defer allocator.free(line);
        var l: usize = 0;
        while (l < lines) : (l += 1) {
            var i: usize = 0;
            while (i < per_line) : (i += 1) line[i] = if (along_u) self.points[i + l * self.count_u] else self.points[l + i * self.count_u];
            const curve = CurveData{ .degree = degree, .knots = @constCast(knots), .points = line };
            var refined = try curve.refineKnots(allocator, x);
            defer refined.deinit(allocator);
            i = 0;
            while (i < new_per_line) : (i += 1) {
                if (along_u) points[i + l * new_per_line] = refined.points[i] else points[l + i * self.count_u] = refined.points[i];
            }
            if (new_knots == null) new_knots = try allocator.dupe(f64, refined.knots);
        }
        const other_knots = try allocator.dupe(f64, if (along_u) self.knots_v else self.knots_u);
        return .{
            .degree_u = self.degree_u,
            .degree_v = self.degree_v,
            .knots_u = if (along_u) new_knots.? else other_knots,
            .knots_v = if (along_u) other_knots else new_knots.?,
            .count_u = if (along_u) @intCast(new_per_line) else self.count_u,
            .count_v = if (along_u) self.count_v else @intCast(new_per_line),
            .points = points,
        };
    }

    /// The patch over `box` (inside both domains) as a clamped surface of its own: the
    /// box's bounds inserted to full multiplicity, then the control points between them.
    pub fn segment(self: *const SurfaceData, allocator: std.mem.Allocator, box: Box2) Error!SurfaceData {
        var in_u = try self.refineToMultiplicity(allocator, .u, box.min[0], box.max[0]);
        defer in_u.deinit(allocator);
        var in_both = try in_u.refineToMultiplicity(allocator, .v, box.min[1], box.max[1]);
        defer in_both.deinit(allocator);
        const u_range = pointRange(in_both.knots_u, in_both.degree_u, box.min[0], box.max[0]);
        const v_range = pointRange(in_both.knots_v, in_both.degree_v, box.min[1], box.max[1]);
        const count_u = u_range.count;
        const count_v = v_range.count;
        const points = try allocator.alloc(Vec4, count_u * count_v);
        errdefer allocator.free(points);
        var j: usize = 0;
        while (j < count_v) : (j += 1) {
            var i: usize = 0;
            while (i < count_u) : (i += 1) points[i + j * count_u] = in_both.points[(u_range.first + i) + (v_range.first + j) * in_both.count_u];
        }
        const knots_u = try clampedKnots(allocator, in_both.knots_u, in_both.degree_u, box.min[0], box.max[0], u_range);
        errdefer allocator.free(knots_u);
        const knots_v = try clampedKnots(allocator, in_both.knots_v, in_both.degree_v, box.min[1], box.max[1], v_range);
        return .{ .degree_u = self.degree_u, .degree_v = self.degree_v, .knots_u = knots_u, .knots_v = knots_v, .count_u = @intCast(count_u), .count_v = @intCast(count_v), .points = points };
    }

    fn refineToMultiplicity(self: *const SurfaceData, allocator: std.mem.Allocator, direction: Direction, a: f64, b: f64) Error!SurfaceData {
        const degree = if (direction == .u) self.degree_u else self.degree_v;
        const knots = if (direction == .u) self.knots_u else self.knots_v;
        var have_a: usize = 0;
        var have_b: usize = 0;
        for (knots) |k| {
            have_a += @intFromBool(k == a);
            have_b += @intFromBool(k == b);
        }
        var x: [2 * MAX_DEGREE]f64 = undefined;
        var n: usize = 0;
        while (have_a + n < degree) : (n += 1) x[n] = a;
        const from_b = n;
        while (have_b + (n - from_b) < degree) : (n += 1) x[n] = b;
        return self.refineKnots(allocator, direction, x[0..n]);
    }
};

const PointRange = struct { first: usize, count: usize, last_start: usize, first_end: usize };

/// The control points whose basis functions live between `a` and `b`, both at multiplicity
/// `p` (or `p+1` at a domain end) in `knots`.
fn pointRange(knots: []const f64, p: usize, a: f64, b: f64) PointRange {
    var last_start: usize = 0;
    var first_end: usize = 0;
    var seen_end = false;
    for (knots, 0..) |k, i| {
        if (k == a) last_start = i;
        if (k == b and !seen_end) {
            first_end = i;
            seen_end = true;
        }
    }
    return .{ .first = last_start - p, .count = first_end - last_start + p, .last_start = last_start, .first_end = first_end };
}

/// The clamped knot vector of a segment: `a` and `b` at multiplicity `p+1` around the
/// interior knots between them.
fn clampedKnots(allocator: std.mem.Allocator, knots: []const f64, p: usize, a: f64, b: f64, range: PointRange) Error![]f64 {
    const out = try allocator.alloc(f64, range.count + p + 1);
    var i: usize = 0;
    while (i <= p) : (i += 1) {
        out[i] = a;
        out[out.len - 1 - i] = b;
    }
    const interior = knots[range.last_start + 1 .. range.first_end];
    @memcpy(out[p + 1 .. p + 1 + interior.len], interior);
    return out;
}

// ---------------------------------------------------------------------------------------
// Surface constructors (ch. 8)

/// Ch. 8: the extrusion of `curve` along `d` for `v` in `[v0, v1]`: degree 1 in `v`, the
/// generator's control points at `v0·d` and `v1·d`.
pub fn extrusion(allocator: std.mem.Allocator, curve: Curve, d: Vec3, v0: f64, v1: f64) Error!SurfaceData {
    const knots_u = try allocator.dupe(f64, curve.knots);
    errdefer allocator.free(knots_u);
    const knots_v = try allocator.dupe(f64, &.{ v0, v0, v1, v1 });
    errdefer allocator.free(knots_v);
    const count = curve.points.len;
    const points = try allocator.alloc(Vec4, count * 2);
    for (curve.points, 0..) |q, i| {
        points[i] = vec.addScaled4(q, .{ d[0], d[1], d[2], 0 }, v0 * q[3]);
        points[i + count] = vec.addScaled4(q, .{ d[0], d[1], d[2], 0 }, v1 * q[3]);
    }
    return .{ .degree_u = curve.degree, .degree_v = 1, .knots_u = knots_u, .knots_v = knots_v, .count_u = @intCast(count), .count_v = 2, .points = points };
}

/// The ruled surface between two curves with the same degree and knots (a cylinder or a
/// cone between two circle arcs): degree 1 in `v` over `[v0, v1]`.
pub fn ruled(allocator: std.mem.Allocator, a: Curve, b: Curve, v0: f64, v1: f64) Error!SurfaceData {
    std.debug.assert(a.degree == b.degree and a.points.len == b.points.len);
    const knots_u = try allocator.dupe(f64, a.knots);
    errdefer allocator.free(knots_u);
    const knots_v = try allocator.dupe(f64, &.{ v0, v0, v1, v1 });
    errdefer allocator.free(knots_v);
    const count = a.points.len;
    const points = try allocator.alloc(Vec4, count * 2);
    @memcpy(points[0..count], a.points);
    @memcpy(points[count..], b.points);
    return .{ .degree_u = a.degree, .degree_v = 1, .knots_u = knots_u, .knots_v = knots_v, .count_u = @intCast(count), .count_v = 2, .points = points };
}

/// A8.1: the surface of revolution of `generator` about the axis through `origin` along
/// unit `axis`, from angle `start` to `end` (at most a full turn), `u` the angle (pieces of
/// at most 90°, as A7.1, the parameter the angle at the pieces' ends and middles only) and
/// `v` the generator's parameter. Each generator control point sweeps its own circle arc:
/// `w_ij = w_i^circle · w_j^generator`.
pub fn revolution(allocator: std.mem.Allocator, generator: Curve, origin: Vec3, axis: Vec3, start: f64, end: f64) Error!SurfaceData {
    const sweep = end - start;
    const pieces: usize = @intFromFloat(@ceil(sweep / MAX_ARC_PER_PIECE - 1e-9));
    const narcs = @max(pieces, 1);
    const dtheta = sweep / @as(f64, @floatFromInt(narcs));
    const count_u = 2 * narcs + 1;
    const count_v = generator.points.len;
    const knots_u = try allocator.alloc(f64, count_u + 3);
    errdefer allocator.free(knots_u);
    const knots_v = try allocator.dupe(f64, generator.knots);
    errdefer allocator.free(knots_v);
    const points = try allocator.alloc(Vec4, count_u * count_v);
    errdefer allocator.free(points);
    knots_u[0] = start;
    knots_u[1] = start;
    knots_u[2] = start;
    var i: usize = 1;
    while (i < narcs) : (i += 1) {
        const k = start + dtheta * @as(f64, @floatFromInt(i));
        knots_u[2 * i + 1] = k;
        knots_u[2 * i + 2] = k;
    }
    knots_u[count_u] = end;
    knots_u[count_u + 1] = end;
    knots_u[count_u + 2] = end;
    const wm = @cos(dtheta / 2.0);
    const frame = types.Frame.fromAxis(origin, axis);
    // Each generator point: its radius and height about the axis, then its own circle
    for (generator.points, 0..) |q, j| {
        const w = q[3];
        const pt = vec.project4(q);
        const local = frame.toLocal(pt);
        const radius = @sqrt(local[0] * local[0] + local[1] * local[1]);
        const height = local[2];
        const phase = types.angleOf(local[0], local[1]);
        const center = vec.addScaled(origin, axis, height);
        var angle = start + phase;
        var p0 = vec.add(center, vec.add(vec.scale(frame.x, radius * @cos(angle)), vec.scale(frame.y, radius * @sin(angle))));
        var t0 = vec.add(vec.scale(frame.x, -@sin(angle)), vec.scale(frame.y, @cos(angle)));
        points[0 + j * count_u] = vec.weighted(p0, w);
        var index: usize = 0;
        i = 1;
        while (i <= narcs) : (i += 1) {
            angle += dtheta;
            const p2 = vec.add(center, vec.add(vec.scale(frame.x, radius * @cos(angle)), vec.scale(frame.y, radius * @sin(angle))));
            const t2 = vec.add(vec.scale(frame.x, -@sin(angle)), vec.scale(frame.y, @cos(angle)));
            const p1 = vec.addScaled(p0, t0, radius * @tan(dtheta / 2.0));
            points[index + 1 + j * count_u] = vec.weighted(p1, wm * w);
            points[index + 2 + j * count_u] = vec.weighted(p2, w);
            index += 2;
            p0 = p2;
            t0 = t2;
        }
    }
    return .{ .degree_u = 2, .degree_v = generator.degree, .knots_u = knots_u, .knots_v = knots_v, .count_u = @intCast(count_u), .count_v = @intCast(count_v), .points = points };
}

/// A bilinear patch: the four corners `p00, p10, p01, p11` (`u` first), degree 1 × 1.
pub fn bilinear(allocator: std.mem.Allocator, p00: Vec3, p10: Vec3, p01: Vec3, p11: Vec3, u: [2]f64, v: [2]f64) Error!SurfaceData {
    const knots_u = try allocator.dupe(f64, &.{ u[0], u[0], u[1], u[1] });
    errdefer allocator.free(knots_u);
    const knots_v = try allocator.dupe(f64, &.{ v[0], v[0], v[1], v[1] });
    errdefer allocator.free(knots_v);
    const points = try allocator.dupe(Vec4, &.{ vec.weighted(p00, 1), vec.weighted(p10, 1), vec.weighted(p01, 1), vec.weighted(p11, 1) });
    return .{ .degree_u = 1, .degree_v = 1, .knots_u = knots_u, .knots_v = knots_v, .count_u = 2, .count_v = 2, .points = points };
}
