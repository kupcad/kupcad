//! Rounded interval arithmetic (docs/architecture.md §6; research/opengeometry.md §3): an
//! `Interval` encloses a real value, or a range of them, and every operation widens its
//! result by one ulp each side, so the enclosure holds under round-to-nearest without
//! directed rounding modes. This is the kernel's one bounding tool: boxes of curves and
//! surfaces, pruning in intersections, chord-deviation certificates (M3, M5). It is never
//! a deciding tool: a sign comes from `predicates.zig`; an interval only says "cannot meet"
//! or "lies within".
//!
//! Sine and cosine of an interval: the argument is reduced by whole turns with `PI`'s own
//! enclosure, the series at zero is run in interval arithmetic with its remainder added,
//! and a crest or trough the interval may hold brings in ±1; a number's sine is enclosed
//! to about 1e-13. The widening assumes the arithmetic neither overflows nor underflows,
//! as the predicates do.

const std = @import("std");

comptime {
    @setFloatMode(.strict);
}

/// π as an interval: the double below it and the one above (`std.math.pi` rounds down).
pub const PI: Interval = .{ .lo = 3.141592653589793, .hi = 3.1415926535897936 };
/// The sine series at zero is run to this many terms (degree 29); the first term left out,
/// `|r|³¹ / 31!`, is under `SIN_REMAINDER` for `|r| ≤ 3.2`, which a reduction by whole
/// turns guarantees (`|r| ≤ π` up to rounding).
const SIN_TERMS: usize = 15;
const SIN_REMAINDER: f64 = 1e-18;
/// How far, in turns, the search for a crest inside an interval of angles reaches past
/// its ends, so a crest a rounding away is never missed (conservative: an extra ±1).
const CREST_SLACK: f64 = 1e-9;

/// A closed interval `[lo, hi]` of reals, `lo ≤ hi`.
pub const Interval = struct {
    lo: f64,
    hi: f64,

    /// The interval holding `x` alone.
    pub fn of(x: f64) Interval {
        return .{ .lo = x, .hi = x };
    }

    /// The interval from `lo` to `hi`.
    pub fn span(lo: f64, hi: f64) Interval {
        std.debug.assert(lo <= hi);
        return .{ .lo = lo, .hi = hi };
    }

    /// The least interval holding both.
    pub fn hull(a: Interval, b: Interval) Interval {
        return .{ .lo = @min(a.lo, b.lo), .hi = @max(a.hi, b.hi) };
    }

    pub fn contains(self: Interval, x: f64) bool {
        return self.lo <= x and x <= self.hi;
    }

    /// Whether `other` lies within `self`.
    pub fn encloses(self: Interval, other: Interval) bool {
        return self.lo <= other.lo and other.hi <= self.hi;
    }

    /// Whether the two share a point.
    pub fn meets(self: Interval, other: Interval) bool {
        return self.lo <= other.hi and other.lo <= self.hi;
    }

    pub fn width(self: Interval) f64 {
        return self.hi - self.lo;
    }

    pub fn mid(self: Interval) f64 {
        return 0.5 * (self.lo + self.hi);
    }

    /// The interval grown by `by` each side (`by ≥ 0`).
    pub fn grown(self: Interval, by: f64) Interval {
        return widen(self.lo - by, self.hi + by);
    }

    pub fn neg(a: Interval) Interval {
        return .{ .lo = -a.hi, .hi = -a.lo };
    }

    pub fn abs(a: Interval) Interval {
        if (a.lo >= 0) return a;
        if (a.hi <= 0) return a.neg();
        return .{ .lo = 0, .hi = @max(-a.lo, a.hi) };
    }

    pub fn add(a: Interval, b: Interval) Interval {
        return widen(a.lo + b.lo, a.hi + b.hi);
    }

    pub fn sub(a: Interval, b: Interval) Interval {
        return widen(a.lo - b.hi, a.hi - b.lo);
    }

    pub fn mul(a: Interval, b: Interval) Interval {
        const p = [4]f64{ a.lo * b.lo, a.lo * b.hi, a.hi * b.lo, a.hi * b.hi };
        return widen(@min(@min(p[0], p[1]), @min(p[2], p[3])), @max(@max(p[0], p[1]), @max(p[2], p[3])));
    }

    /// The interval times the number `k`.
    pub fn scale(a: Interval, k: f64) Interval {
        return a.mul(of(k));
    }

    pub fn square(a: Interval) Interval {
        const lo2 = a.lo * a.lo;
        const hi2 = a.hi * a.hi;
        if (a.lo >= 0) return widen(lo2, hi2);
        if (a.hi <= 0) return widen(hi2, lo2);
        return widen(0, @max(lo2, hi2));
    }

    /// `a / b`, when `b` cannot be zero; `null` otherwise.
    pub fn div(a: Interval, b: Interval) ?Interval {
        if (b.lo <= 0 and 0 <= b.hi) return null;
        const q = [4]f64{ a.lo / b.lo, a.lo / b.hi, a.hi / b.lo, a.hi / b.hi };
        return widen(@min(@min(q[0], q[1]), @min(q[2], q[3])), @max(@max(q[0], q[1]), @max(q[2], q[3])));
    }

    /// `√a` over the part of `a` at or above zero; `null` when all of `a` is below it.
    pub fn sqrt(a: Interval) ?Interval {
        if (a.hi < 0) return null;
        return widen(@sqrt(@max(a.lo, 0)), @sqrt(a.hi));
    }

    /// The sine of every angle (radians) in `a`.
    pub fn sin(a: Interval) Interval {
        if (a.width() >= 2 * PI.lo) return .{ .lo = -1, .hi = 1 };
        var r = hull(sinPoint(a.lo), sinPoint(a.hi));
        // A crest (π/2 + 2πk) or a trough (−π/2 + 2πk) inside the interval
        if (holdsTurnPoint(a, 0.25)) r.hi = 1;
        if (holdsTurnPoint(a, -0.25)) r.lo = -1;
        return .{ .lo = @max(r.lo, -1), .hi = @min(r.hi, 1) };
    }

    /// The cosine of every angle (radians) in `a`.
    pub fn cos(a: Interval) Interval {
        return a.add(PI.scale(0.5)).sin();
    }

    /// `[lo, hi]` grown by one ulp each side, what one rounded operation may have moved
    /// the exact endpoints by. An endpoint of exactly zero stays (a rounded result of zero
    /// is exact in the range the arithmetic assumes).
    fn widen(lo: f64, hi: f64) Interval {
        return .{
            .lo = if (lo == 0) lo else std.math.nextAfter(f64, lo, -std.math.inf(f64)),
            .hi = if (hi == 0) hi else std.math.nextAfter(f64, hi, std.math.inf(f64)),
        };
    }
};

/// The sine of the number `x`: `x` less the nearest whole number of turns (an interval,
/// since π is one), the series at that interval's midpoint, grown by half its width (the
/// sine moves at most as fast as its argument) and by the series' remainder.
fn sinPoint(x: f64) Interval {
    const turns = @round(x / (2 * PI.lo));
    const reduced = Interval.of(x).sub(PI.scale(2 * turns));
    const r = Interval.of(reduced.mid());
    std.debug.assert(@abs(r.lo) <= 3.2);
    // Horner over the odd series: sin r = r · (1 − r²/(2·3) · (1 − r²/(4·5) · (1 − …)))
    const r2 = r.square();
    var p = Interval.of(1);
    var n: usize = SIN_TERMS - 1;
    while (n >= 1) : (n -= 1) {
        const divisor: f64 = @floatFromInt((2 * n) * (2 * n + 1));
        p = Interval.of(1).sub(r2.mul(p).div(Interval.of(divisor)).?);
    }
    return r.mul(p).grown(reduced.width() + SIN_REMAINDER);
}

/// Whether some angle `2π(k + turn)`, `k` whole, lies in `a` (or within the slack of it).
fn holdsTurnPoint(a: Interval, turn: f64) bool {
    const slack = CREST_SLACK * (1 + @abs(a.lo) / (2 * PI.lo));
    const first = @ceil(a.lo / (2 * PI.lo) - turn - slack);
    const last = @floor(a.hi / (2 * PI.lo) - turn + slack);
    return first <= last;
}

/// An axis-aligned box of `n` intervals.
pub fn Box(comptime n: usize) type {
    return struct {
        axes: [n]Interval,

        const Self = @This();

        pub fn of(point: [n]f64) Self {
            var self: Self = undefined;
            for (point, 0..) |x, i| self.axes[i] = Interval.of(x);
            return self;
        }

        pub fn hull(a: Self, b: Self) Self {
            var self: Self = undefined;
            for (0..n) |i| self.axes[i] = Interval.hull(a.axes[i], b.axes[i]);
            return self;
        }

        pub fn contains(self: Self, point: [n]f64) bool {
            for (point, 0..) |x, i| if (!self.axes[i].contains(x)) return false;
            return true;
        }

        pub fn encloses(self: Self, other: Self) bool {
            for (0..n) |i| if (!self.axes[i].encloses(other.axes[i])) return false;
            return true;
        }

        /// Whether the two share a point: every axis overlaps.
        pub fn meets(self: Self, other: Self) bool {
            for (0..n) |i| if (!self.axes[i].meets(other.axes[i])) return false;
            return true;
        }

        /// The largest width over the axes.
        pub fn width(self: Self) f64 {
            var w: f64 = 0;
            for (self.axes) |axis| w = @max(w, axis.width());
            return w;
        }

        pub fn grown(self: Self, by: f64) Self {
            var r = self;
            for (&r.axes) |*axis| axis.* = axis.grown(by);
            return r;
        }
    };
}

pub const Box2 = Box(2);
pub const Box3 = Box(3);
pub const Box4 = Box(4);
