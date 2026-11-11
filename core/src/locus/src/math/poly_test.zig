//! Polynomial roots by derivative isolation: known roots of every degree up to four, a
//! double root seen as a critical point, interval ends, degenerate leading coefficients,
//! and random products of linear factors.

const std = @import("std");
const testing = std.testing;
const poly = @import("poly.zig");
const Poly = poly.Poly;

fn fromRoots(rs: []const f64) Poly {
    var p = Poly.of(&.{1});
    for (rs) |r| p = p.mul(Poly.of(&.{ -r, 1 }));
    return p;
}

fn expectRoots(p: Poly, lo: f64, hi: f64, want: []const f64) !void {
    const got = poly.roots(p, lo, hi);
    try testing.expectEqual(want.len, got.len);
    for (want, got.slice()) |w, g| try testing.expectApproxEqAbs(w, g, 1e-12 * @max(1, @abs(w)));
}

test "poly: roots of each degree, in order, within the interval only" {
    try expectRoots(Poly.of(&.{ -3, 2 }), -10, 10, &.{1.5});
    try expectRoots(Poly.of(&.{ -3, 2 }), 2, 10, &.{});
    try expectRoots(fromRoots(&.{ -2, 5 }), -10, 10, &.{ -2, 5 });
    try expectRoots(fromRoots(&.{ -2, 5 }), 0, 10, &.{5});
    try expectRoots(fromRoots(&.{ -3, 0.5, 7 }), -10, 10, &.{ -3, 0.5, 7 });
    try expectRoots(fromRoots(&.{ -4, -1, 2, 3 }), -10, 10, &.{ -4, -1, 2, 3 });
    // No real roots: x² + 1, and the torus-like (x² + 1)(x² + 4)
    try expectRoots(Poly.of(&.{ 1, 0, 1 }), -10, 10, &.{});
    try expectRoots(Poly.of(&.{ 1, 0, 1 }).mul(Poly.of(&.{ 4, 0, 1 })), -10, 10, &.{});
    // A root at an end of the interval
    try expectRoots(fromRoots(&.{ 1, 4 }), 1, 4, &.{ 1, 4 });
    // A zero leading coefficient is a lower degree
    try expectRoots(Poly.of(&.{ -6, 3, 0, 0 }), -10, 10, &.{2});
    // The zero polynomial and a constant have no isolated root
    try expectRoots(Poly.of(&.{0}), -1, 1, &.{});
    try expectRoots(Poly.of(&.{ 2, 0, 0 }), -1, 1, &.{});
}

test "poly: a double root is a critical point where the polynomial vanishes" {
    const p = fromRoots(&.{ 2, 2 });
    const crit = poly.criticalPoints(p, -10, 10);
    try testing.expectEqual(@as(usize, 1), crit.len);
    try testing.expectApproxEqAbs(@as(f64, 2), crit.t[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), p.eval(crit.t[0]), 1e-12);
    // Two double roots of a quartic: (t − 1)²(t + 3)²
    const q = fromRoots(&.{ 1, 1, -3, -3 });
    const qc = poly.criticalPoints(q, -10, 10);
    try testing.expectEqual(@as(usize, 3), qc.len);
    try testing.expectApproxEqAbs(@as(f64, -3), qc.t[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), qc.t[2], 1e-9);
}

test "poly: random products of linear factors give back their roots" {
    var prng = std.Random.DefaultPrng.init(0x9017);
    const random = prng.random();
    for (0..500) |_| {
        const degree = 1 + random.uintLessThan(usize, 4);
        var rs: [4]f64 = undefined;
        for (rs[0..degree]) |*r| r.* = (random.float(f64) - 0.5) * 20;
        std.mem.sort(f64, rs[0..degree], {}, std.sort.asc(f64));
        // Distinct enough to be told apart in doubles
        var distinct = true;
        for (1..degree) |i| distinct = distinct and rs[i] - rs[i - 1] > 1e-3;
        if (!distinct) continue;
        const p = fromRoots(rs[0..degree]).scale(0.5 + random.float(f64) * 3);
        const got = poly.roots(p, -11, 11);
        try testing.expectEqual(degree, got.len);
        for (rs[0..degree], got.slice()) |w, g| try testing.expectApproxEqAbs(w, g, 1e-9);
    }
}
