//! Real roots of a polynomial of low degree (a ray against a plane, a quadric or a torus,
//! docs/architecture.md §7.6) on a closed interval, by derivative isolation: the roots of
//! `p'` cut the interval into pieces on which `p` is monotone, and each piece whose ends
//! differ in sign holds exactly one root, found by bisection to the last bit. No closed
//! formula, so no cancellation in a discriminant and no complex detour for the quartic
//! (Ferrari's is notoriously ill-conditioned); a double root (a tangent ray) is a critical
//! point where `p` vanishes, which `criticalPoints` hands the caller to judge by distance.

const std = @import("std");

/// The highest degree handled: a torus is quartic.
pub const MAX_DEGREE: usize = 4;
/// Bisection steps at most: past the 64 a double's bits allow, a guard.
const MAX_BISECTIONS: usize = 200;

/// A polynomial `c[0] + c[1] t + … + c[degree] t^degree`.
pub const Poly = struct {
    c: [MAX_DEGREE + 1]f64 = .{ 0, 0, 0, 0, 0 },
    degree: usize = 0,

    pub fn of(coefficients: []const f64) Poly {
        std.debug.assert(coefficients.len >= 1 and coefficients.len <= MAX_DEGREE + 1);
        var p: Poly = .{ .degree = coefficients.len - 1 };
        @memcpy(p.c[0..coefficients.len], coefficients);
        return p.trimmed();
    }

    /// The same polynomial with leading zero coefficients dropped.
    fn trimmed(self: Poly) Poly {
        var p = self;
        while (p.degree > 0 and p.c[p.degree] == 0) p.degree -= 1;
        return p;
    }

    /// Horner's rule.
    pub fn eval(self: Poly, t: f64) f64 {
        var v = self.c[self.degree];
        var i = self.degree;
        while (i > 0) {
            i -= 1;
            v = v * t + self.c[i];
        }
        return v;
    }

    pub fn derivative(self: Poly) Poly {
        if (self.degree == 0) return .{};
        var d: Poly = .{ .degree = self.degree - 1 };
        for (1..self.degree + 1) |i| d.c[i - 1] = self.c[i] * @as(f64, @floatFromInt(i));
        return d.trimmed();
    }

    pub fn mul(a: Poly, b: Poly) Poly {
        std.debug.assert(a.degree + b.degree <= MAX_DEGREE);
        var p: Poly = .{ .degree = a.degree + b.degree };
        for (0..a.degree + 1) |i| {
            for (0..b.degree + 1) |j| p.c[i + j] += a.c[i] * b.c[j];
        }
        return p.trimmed();
    }

    pub fn add(a: Poly, b: Poly) Poly {
        var p: Poly = .{ .degree = @max(a.degree, b.degree) };
        for (0..p.degree + 1) |i| p.c[i] = (if (i <= a.degree) a.c[i] else 0) + (if (i <= b.degree) b.c[i] else 0);
        return p.trimmed();
    }

    pub fn scale(a: Poly, k: f64) Poly {
        var p = a;
        for (0..p.degree + 1) |i| p.c[i] *= k;
        return p.trimmed();
    }
};

/// Up to `MAX_DEGREE` values in increasing order.
pub const Roots = struct {
    t: [MAX_DEGREE]f64 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Roots) []const f64 {
        return self.t[0..self.len];
    }

    fn push(self: *Roots, t: f64) void {
        if (self.len > 0 and self.t[self.len - 1] == t) return;
        std.debug.assert(self.len < MAX_DEGREE);
        self.t[self.len] = t;
        self.len += 1;
    }
};

/// The real roots of `p` in `[lo, hi]`, in increasing order, each once; none for the zero
/// polynomial (no isolated root to report) or a constant.
pub fn roots(p: Poly, lo: f64, hi: f64) Roots {
    var out: Roots = .{};
    if (!(lo <= hi) or p.degree == 0) return out;
    if (p.degree == 1) {
        const t = -p.c[0] / p.c[1];
        if (t >= lo and t <= hi) out.push(t);
        return out;
    }
    // The pieces between the derivative's roots, on each of which `p` is monotone
    const crit = roots(p.derivative(), lo, hi);
    var cuts: [MAX_DEGREE + 2]f64 = undefined;
    var n: usize = 0;
    cuts[n] = lo;
    n += 1;
    for (crit.slice()) |t| {
        if (t > cuts[n - 1] and t < hi) {
            cuts[n] = t;
            n += 1;
        }
    }
    cuts[n] = hi;
    n += 1;
    for (0..n - 1) |i| {
        const a = cuts[i];
        const b = cuts[i + 1];
        const fa = p.eval(a);
        const fb = p.eval(b);
        if (fa == 0) {
            out.push(a);
            continue;
        }
        if (fb == 0) {
            out.push(b);
            continue;
        }
        if ((fa < 0) == (fb < 0)) continue;
        out.push(bisect(p, a, b, fa));
    }
    return out;
}

/// The critical points of `p` (the roots of `p'`) in `[lo, hi]`: where a double root, a
/// tangency, can only be.
pub fn criticalPoints(p: Poly, lo: f64, hi: f64) Roots {
    return roots(p.derivative(), lo, hi);
}

/// The root of `p` in `[a, b]`, `p` monotone there with a sign change, `fa = p(a)`.
fn bisect(p: Poly, a0: f64, b0: f64, fa0: f64) f64 {
    var a = a0;
    var b = b0;
    const a_negative = fa0 < 0;
    var step: usize = 0;
    while (step < MAX_BISECTIONS) : (step += 1) {
        const m = a + (b - a) / 2;
        if (m == a or m == b) break;
        const fm = p.eval(m);
        if (fm == 0) return m;
        if ((fm < 0) == a_negative) a = m else b = m;
    }
    return a + (b - a) / 2;
}
