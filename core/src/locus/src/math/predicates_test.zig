const std = @import("std");
const testing = std.testing;
const predicates = @import("predicates.zig");
const orient2d = predicates.orient2d;
const orient3d = predicates.orient3d;
const incircle = predicates.incircle;
const inCircle = predicates.inCircle;
const lineCircleDiscriminant = predicates.lineCircleDiscriminant;
const lineCircleCrossing = predicates.lineCircleCrossing;
const compareArcX = predicates.compareArcX;
const compareArcXWithLine = predicates.compareArcXWithLine;
const compareLineX = predicates.compareLineX;
const Side = predicates.Side;
const Root = predicates.Root;
const Place = predicates.Place;

/// Random cases per predicate in the cross-check against exact arithmetic.
pub const FUZZ_CASES = 1000;
/// The seed of the fuzz, fixed: a failure must come back.
pub const SEED = 0x5eed_10c5;
/// Coordinates of the fuzz near a degenerate configuration are a few ulps apart
const MAX_ULPS = 4;

const Managed = std.math.big.int.Managed;

/// A double as an integer times 2^`exponent`, exactly.
const Scaled = struct { mantissa: i64, exponent: i32 };

fn scaled(x: f64) Scaled {
    if (x == 0.0) return .{ .mantissa = 0, .exponent = 0 };
    const f = std.math.frexp(x);
    // significand in [0.5, 1): times 2^53 it is a whole number
    return .{ .mantissa = @intFromFloat(f.significand * 9007199254740992.0), .exponent = f.exponent - 53 };
}

/// The exact determinant's sign through big integers: every coordinate becomes an integer
/// over one common power of two, which the determinant's sign ignores.
const Exact = struct {
    allocator: std.mem.Allocator,
    shift_base: i32,

    fn init(allocator: std.mem.Allocator, coordinates: []const f64) Exact {
        var lowest: i32 = std.math.maxInt(i32);
        for (coordinates) |x| {
            const s = scaled(x);
            if (s.mantissa != 0 and s.exponent < lowest) lowest = s.exponent;
        }
        return .{ .allocator = allocator, .shift_base = if (lowest == std.math.maxInt(i32)) 0 else lowest };
    }

    fn int(self: Exact, x: f64) !Managed {
        var m = try Managed.init(self.allocator);
        errdefer m.deinit();
        const s = scaled(x);
        try m.set(s.mantissa);
        if (s.mantissa != 0) try m.shiftLeft(&m, @intCast(s.exponent - self.shift_base));
        return m;
    }

    fn diff(self: Exact, x: f64, y: f64) !Managed {
        var a = try self.int(x);
        defer a.deinit();
        var b = try self.int(y);
        defer b.deinit();
        var r = try Managed.init(self.allocator);
        errdefer r.deinit();
        try r.sub(&a, &b);
        return r;
    }

    fn mul(self: Exact, a: *const Managed, b: *const Managed) !Managed {
        var r = try Managed.init(self.allocator);
        errdefer r.deinit();
        try r.mul(a, b);
        return r;
    }

    fn sub(self: Exact, a: *const Managed, b: *const Managed) !Managed {
        var r = try Managed.init(self.allocator);
        errdefer r.deinit();
        try r.sub(a, b);
        return r;
    }

    fn add(self: Exact, a: *const Managed, b: *const Managed) !Managed {
        var r = try Managed.init(self.allocator);
        errdefer r.deinit();
        try r.add(a, b);
        return r;
    }

    /// `a·d − b·c`
    fn det2(self: Exact, a: *const Managed, b: *const Managed, c: *const Managed, d: *const Managed) !Managed {
        var ad = try self.mul(a, d);
        defer ad.deinit();
        var bc = try self.mul(b, c);
        defer bc.deinit();
        return self.sub(&ad, &bc);
    }

    /// The determinant of the 3×3 matrix `m` (rows).
    fn det3(self: Exact, m: *const [3][3]Managed) !Managed {
        var c0 = try self.det2(&m[1][1], &m[1][2], &m[2][1], &m[2][2]);
        defer c0.deinit();
        var c1 = try self.det2(&m[1][0], &m[1][2], &m[2][0], &m[2][2]);
        defer c1.deinit();
        var c2 = try self.det2(&m[1][0], &m[1][1], &m[2][0], &m[2][1]);
        defer c2.deinit();
        var t0 = try self.mul(&m[0][0], &c0);
        defer t0.deinit();
        var t1 = try self.mul(&m[0][1], &c1);
        defer t1.deinit();
        var t2 = try self.mul(&m[0][2], &c2);
        defer t2.deinit();
        var s = try self.sub(&t0, &t1);
        defer s.deinit();
        return self.add(&s, &t2);
    }
};

fn signOf(m: *const Managed) i8 {
    if (m.eqlZero()) return 0;
    return if (m.isPositive()) 1 else -1;
}

pub fn signOfFloat(x: f64) i8 {
    if (x > 0.0) return 1;
    if (x < 0.0) return -1;
    return 0;
}

pub fn exactOrient2d(allocator: std.mem.Allocator, a: [2]f64, b: [2]f64, c: [2]f64) !i8 {
    const exact = Exact.init(allocator, &.{ a[0], a[1], b[0], b[1], c[0], c[1] });
    var acx = try exact.diff(a[0], c[0]);
    defer acx.deinit();
    var acy = try exact.diff(a[1], c[1]);
    defer acy.deinit();
    var bcx = try exact.diff(b[0], c[0]);
    defer bcx.deinit();
    var bcy = try exact.diff(b[1], c[1]);
    defer bcy.deinit();
    var det = try exact.det2(&acx, &acy, &bcx, &bcy);
    defer det.deinit();
    return signOf(&det);
}

fn exactOrient3d(allocator: std.mem.Allocator, a: [3]f64, b: [3]f64, c: [3]f64, d: [3]f64) !i8 {
    const exact = Exact.init(allocator, &.{ a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2], d[0], d[1], d[2] });
    var m: [3][3]Managed = undefined;
    const rows = [3][3]f64{ a, b, c };
    var made: usize = 0;
    defer for (0..made) |i| for (0..3) |j| m[i][j].deinit();
    for (0..3) |i| {
        for (0..3) |j| m[i][j] = try exact.diff(rows[i][j], d[j]);
        made += 1;
    }
    var det = try exact.det3(&m);
    defer det.deinit();
    return signOf(&det);
}

fn exactIncircle(allocator: std.mem.Allocator, a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) !i8 {
    const exact = Exact.init(allocator, &.{ a[0], a[1], b[0], b[1], c[0], c[1], d[0], d[1] });
    var m: [3][3]Managed = undefined;
    const rows = [3][2]f64{ a, b, c };
    var made: usize = 0;
    defer for (0..made) |i| for (0..3) |j| m[i][j].deinit();
    for (0..3) |i| {
        m[i][0] = try exact.diff(rows[i][0], d[0]);
        errdefer m[i][0].deinit();
        m[i][1] = try exact.diff(rows[i][1], d[1]);
        errdefer m[i][1].deinit();
        var xx = try exact.mul(&m[i][0], &m[i][0]);
        defer xx.deinit();
        var yy = try exact.mul(&m[i][1], &m[i][1]);
        defer yy.deinit();
        m[i][2] = try exact.add(&xx, &yy);
        made += 1;
    }
    var det = try exact.det3(&m);
    defer det.deinit();
    return signOf(&det);
}

/// The sign of `a + s·√b` over big integers, from the definition: `b < 0` counts as zero
/// (as the predicates count it), else the side with the larger square wins.
fn exactSignPlusSqrt(exact: Exact, a: *const Managed, s: i8, b: *const Managed) !i8 {
    if (!b.isPositive() or b.eqlZero()) return signOf(a);
    const sa = signOf(a);
    if (s > 0 and sa >= 0) return 1;
    if (s < 0 and sa <= 0) return -1;
    var aa = try exact.mul(a, a);
    defer aa.deinit();
    var d = try exact.sub(b, &aa);
    defer d.deinit();
    // `a` and `s·√b` pull against each other: the larger magnitude decides
    return if (s > 0) signOf(&d) else -signOf(&d);
}

/// `r² − |p − c|²` over big integers.
fn exactInCircleValue(exact: Exact, c: [2]f64, r: f64, p: [2]f64) !Managed {
    var rr = try exact.int(r);
    defer rr.deinit();
    var r2 = try exact.mul(&rr, &rr);
    defer r2.deinit();
    var dx = try exact.diff(p[0], c[0]);
    defer dx.deinit();
    var dy = try exact.diff(p[1], c[1]);
    defer dy.deinit();
    var xx = try exact.mul(&dx, &dx);
    defer xx.deinit();
    var yy = try exact.mul(&dy, &dy);
    defer yy.deinit();
    var d2 = try exact.add(&xx, &yy);
    defer d2.deinit();
    return exact.sub(&r2, &d2);
}

fn exactInCircle(allocator: std.mem.Allocator, c: [2]f64, r: f64, p: [2]f64) !i8 {
    const exact = Exact.init(allocator, &.{ c[0], c[1], r, p[0], p[1] });
    var v = try exactInCircleValue(exact, c, r, p);
    defer v.deinit();
    return signOf(&v);
}

/// `(b − a)·(d − c)` over big integers.
fn exactDot(exact: Exact, a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) !Managed {
    var ux = try exact.diff(b[0], a[0]);
    defer ux.deinit();
    var uy = try exact.diff(b[1], a[1]);
    defer uy.deinit();
    var vx = try exact.diff(d[0], c[0]);
    defer vx.deinit();
    var vy = try exact.diff(d[1], c[1]);
    defer vy.deinit();
    var xx = try exact.mul(&ux, &vx);
    defer xx.deinit();
    var yy = try exact.mul(&uy, &vy);
    defer yy.deinit();
    return exact.add(&xx, &yy);
}

/// `r²|d|² − (f × d)²` over big integers, `d = b − a`, `f = a − c`.
fn exactDiscriminantValue(exact: Exact, a: [2]f64, b: [2]f64, c: [2]f64, r: f64) !Managed {
    var rr = try exact.int(r);
    defer rr.deinit();
    var r2 = try exact.mul(&rr, &rr);
    defer r2.deinit();
    var dd = try exactDot(exact, a, b, a, b);
    defer dd.deinit();
    var r2dd = try exact.mul(&r2, &dd);
    defer r2dd.deinit();
    var fx = try exact.diff(a[0], c[0]);
    defer fx.deinit();
    var fy = try exact.diff(a[1], c[1]);
    defer fy.deinit();
    var dx = try exact.diff(b[0], a[0]);
    defer dx.deinit();
    var dy = try exact.diff(b[1], a[1]);
    defer dy.deinit();
    var cross = try exact.det2(&fx, &fy, &dx, &dy);
    defer cross.deinit();
    var cross2 = try exact.mul(&cross, &cross);
    defer cross2.deinit();
    return exact.sub(&r2dd, &cross2);
}

fn exactDiscriminant(allocator: std.mem.Allocator, a: [2]f64, b: [2]f64, c: [2]f64, r: f64) !i8 {
    const exact = Exact.init(allocator, &.{ a[0], a[1], b[0], b[1], c[0], c[1], r });
    var v = try exactDiscriminantValue(exact, a, b, c, r);
    defer v.deinit();
    return signOf(&v);
}

/// Where root `root` of the segment's crossing lies, from the formula itself:
/// `t·|d|² = −f·d ± √Δ`, compared with 0 and with `|d|²` over big integers.
fn exactCrossing(allocator: std.mem.Allocator, a: [2]f64, b: [2]f64, c: [2]f64, r: f64, root: Root) !?Place {
    if (a[0] == b[0] and a[1] == b[1]) return null;
    const exact = Exact.init(allocator, &.{ a[0], a[1], b[0], b[1], c[0], c[1], r });
    var disc = try exactDiscriminantValue(exact, a, b, c, r);
    defer disc.deinit();
    if (!disc.isPositive() and !disc.eqlZero()) return null;
    const s: i8 = if (root == .first) -1 else 1;
    // `−f·d = (c − a)·(b − a)`
    var minus_fd = try exactDot(exact, a, c, a, b);
    defer minus_fd.deinit();
    const t_sign = try exactSignPlusSqrt(exact, &minus_fd, s, &disc);
    if (t_sign < 0) return .before;
    if (t_sign == 0) return .start;
    // `|d|² − (−f·d ∓ √Δ)` has the sign of `1 − t`
    var dd = try exactDot(exact, a, b, a, b);
    defer dd.deinit();
    var rest = try exact.sub(&dd, &minus_fd);
    defer rest.deinit();
    const rest_sign = try exactSignPlusSqrt(exact, &rest, -s, &disc);
    if (rest_sign < 0) return .after;
    if (rest_sign == 0) return .end;
    return .inside;
}

/// `r² − (y − cy)²` over big integers.
fn exactRadicand(exact: Exact, c: [2]f64, r: f64, y: f64) !Managed {
    var rr = try exact.int(r);
    defer rr.deinit();
    var r2 = try exact.mul(&rr, &rr);
    defer r2.deinit();
    var dy = try exact.diff(y, c[1]);
    defer dy.deinit();
    var dy2 = try exact.mul(&dy, &dy);
    defer dy2.deinit();
    return exact.sub(&r2, &dy2);
}

fn sideSign(side: Side) i8 {
    return if (side == .east) 1 else -1;
}

/// The sign of `cx₁ + s₁√b₁ − cx₂ − s₂√b₂` over big integers: the first root's side is
/// found, then, when the second pulls the other way, the two are compared squared.
fn exactCompareArcX(allocator: std.mem.Allocator, c1: [2]f64, r1: f64, side1: Side, c2: [2]f64, r2: f64, side2: Side, y: f64) !i8 {
    const exact = Exact.init(allocator, &.{ c1[0], c1[1], r1, c2[0], c2[1], r2, y });
    var e = try exact.diff(c1[0], c2[0]);
    defer e.deinit();
    var b1 = try exactRadicand(exact, c1, r1, y);
    defer b1.deinit();
    var b2 = try exactRadicand(exact, c2, r2, y);
    defer b2.deinit();
    const s1 = sideSign(side1);
    const s2: i8 = -sideSign(side2);
    const left = try exactSignPlusSqrt(exact, &e, s1, &b1);
    const right: i8 = if (b2.isPositive() and !b2.eqlZero()) s2 else 0;
    if (left == 0) return right;
    if (right == 0 or right == left) return left;
    var e2 = try exact.mul(&e, &e);
    defer e2.deinit();
    // A first radicand at or below zero counted as zero in `left`; so here
    var zero = try Managed.initSet(allocator, 0);
    defer zero.deinit();
    const b1_pos = b1.isPositive() and !b1.eqlZero();
    var sum = try exact.add(&e2, if (b1_pos) &b1 else &zero);
    defer sum.deinit();
    var a2 = try exact.sub(&sum, &b2);
    defer a2.deinit();
    const se = signOf(&e);
    if (se == 0 or !b1_pos) return left * signOf(&a2);
    var e2b1 = try exact.mul(&e2, &b1);
    defer e2b1.deinit();
    var four = try Managed.initSet(allocator, 4);
    defer four.deinit();
    var radicand = try exact.mul(&four, &e2b1);
    defer radicand.deinit();
    const compared = try exactSignPlusSqrt(exact, &a2, s1 * se, &radicand);
    if (compared > 0) return left;
    if (compared < 0) return right;
    return 0;
}

/// The sign of `x_arc − x_line` over big integers, multiplied through by `h = by − ay`.
fn exactCompareArcXWithLine(allocator: std.mem.Allocator, c: [2]f64, r: f64, side: Side, y: f64, a: [2]f64, b: [2]f64) !?i8 {
    if (a[1] == b[1]) return null;
    const exact = Exact.init(allocator, &.{ c[0], c[1], r, y, a[0], a[1], b[0], b[1] });
    var h = try exact.diff(b[1], a[1]);
    defer h.deinit();
    const sh = signOf(&h);
    var cx_ax = try exact.diff(c[0], a[0]);
    defer cx_ax.deinit();
    var h_cx = try exact.mul(&h, &cx_ax);
    defer h_cx.deinit();
    var y_ay = try exact.diff(y, a[1]);
    defer y_ay.deinit();
    var bx_ax = try exact.diff(b[0], a[0]);
    defer bx_ax.deinit();
    var along = try exact.mul(&y_ay, &bx_ax);
    defer along.deinit();
    var lhs = try exact.sub(&h_cx, &along);
    defer lhs.deinit();
    var h2 = try exact.mul(&h, &h);
    defer h2.deinit();
    var radicand = try exactRadicand(exact, c, r, y);
    defer radicand.deinit();
    var h2b = try exact.mul(&h2, &radicand);
    defer h2b.deinit();
    return sh * try exactSignPlusSqrt(exact, &lhs, sideSign(side) * sh, &h2b);
}

/// The sign of `x₁ − x₂` at height `y` for two lines over big integers, from the formula
/// multiplied through by `h₁h₂`.
fn exactCompareLineX(allocator: std.mem.Allocator, y: f64, a1: [2]f64, b1: [2]f64, a2: [2]f64, b2: [2]f64) !?i8 {
    if (a1[1] == b1[1] or a2[1] == b2[1]) return null;
    const exact = Exact.init(allocator, &.{ y, a1[0], a1[1], b1[0], b1[1], a2[0], a2[1], b2[0], b2[1] });
    var h1 = try exact.diff(b1[1], a1[1]);
    defer h1.deinit();
    var h2 = try exact.diff(b2[1], a2[1]);
    defer h2.deinit();
    var n1 = try exactLineXNumerator(exact, y, a1, b1);
    defer n1.deinit();
    var n2 = try exactLineXNumerator(exact, y, a2, b2);
    defer n2.deinit();
    var h2n1 = try exact.mul(&h2, &n1);
    defer h2n1.deinit();
    var h1n2 = try exact.mul(&h1, &n2);
    defer h1n2.deinit();
    var lhs = try exact.sub(&h2n1, &h1n2);
    defer lhs.deinit();
    return signOf(&h1) * signOf(&h2) * signOf(&lhs);
}

fn exactLineXNumerator(exact: Exact, y: f64, a: [2]f64, b: [2]f64) !Managed {
    var ax = try exact.int(a[0]);
    defer ax.deinit();
    var h = try exact.diff(b[1], a[1]);
    defer h.deinit();
    var axh = try exact.mul(&ax, &h);
    defer axh.deinit();
    var dy = try exact.diff(y, a[1]);
    defer dy.deinit();
    var dx = try exact.diff(b[0], a[0]);
    defer dx.deinit();
    var along = try exact.mul(&dy, &dx);
    defer along.deinit();
    return exact.add(&axh, &along);
}

/// The `side` crossing's `x` in quadruple precision, for a cross-check where it decides;
/// `null` where its own radicand cancels (two terms within 1e-25 of each other), since
/// quadruple precision is no oracle there (wasm's and the native soft floats even differed
/// on one such case).
fn arcX128(c: [2]f64, r: f64, side: Side, y: f64) ?f128 {
    const dy: f128 = @as(f128, y) - @as(f128, c[1]);
    const rr = @as(f128, r) * @as(f128, r);
    const radicand = rr - dy * dy;
    if (@abs(radicand) <= 1e-25 * (rr + dy * dy)) return null;
    const root: f128 = if (radicand > 0) @sqrt(radicand) else 0;
    return @as(f128, c[0]) + @as(f128, @floatFromInt(sideSign(side))) * root;
}

test "orient2d: the sign of a turn, and zero for collinear points however they are scaled" {
    try testing.expect(orient2d(.{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }) > 0);
    try testing.expect(orient2d(.{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 }) < 0);
    try testing.expectEqual(@as(f64, 0), orient2d(.{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }));
    try testing.expectEqual(@as(f64, 0), orient2d(.{ 0.5, 0.5 }, .{ 12, 12 }, .{ 24, 24 }));
    try testing.expectEqual(@as(f64, 0), orient2d(.{ 1e-100, 1e-100 }, .{ 2e-100, 2e-100 }, .{ 3e-100, 3e-100 }));
    try testing.expectEqual(@as(f64, 0), orient2d(.{ 1e100, 1e100 }, .{ 2e100, 2e100 }, .{ 3e100, 3e100 }));
    // A point one ulp off the line, at 1e-100 scale: still a turn
    const tiny = std.math.nextAfter(f64, 2e-100, 1.0);
    try testing.expect(orient2d(.{ 1e-100, 1e-100 }, .{ 2e-100, tiny }, .{ 3e-100, 3e-100 }) < 0);
    try testing.expect(orient2d(.{ 1e-100, 1e-100 }, .{ tiny, 2e-100 }, .{ 3e-100, 3e-100 }) > 0);
}

test "orient2d: Kettner's near-collinear grid, where the naive determinant fails" {
    // Points p + k ulps in x and y around (0.5, 0.5), against q = (12, 12), r = (24, 24):
    // the naive determinant's sign is wrong on many of them; the exact one agrees with
    // big-integer arithmetic on all.
    const q = [2]f64{ 12, 12 };
    const r = [2]f64{ 24, 24 };
    var disagreements: usize = 0;
    var x: f64 = 0.5;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var y: f64 = 0.5;
        var j: usize = 0;
        while (j < 64) : (j += 1) {
            const p = [2]f64{ x, y };
            const expected = try exactOrient2d(testing.allocator, p, q, r);
            try testing.expectEqual(expected, signOfFloat(orient2d(p, q, r)));
            const naive = (p[0] - r[0]) * (q[1] - r[1]) - (p[1] - r[1]) * (q[0] - r[0]);
            if (signOfFloat(naive) != expected) disagreements += 1;
            y = std.math.nextAfter(f64, y, 1.0);
        }
        x = std.math.nextAfter(f64, x, 1.0);
    }
    // The grid is the well-known one: the naive predicate is wrong on part of it
    try testing.expect(disagreements > 0);
}

test "orient2d: the sign is the same under cyclic permutation and reversed under a swap" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    for (0..FUZZ_CASES) |_| {
        const a = randomPoint2(random, 2);
        const b = randomPoint2(random, 2);
        const c = randomPoint2(random, 2);
        const s = signOfFloat(orient2d(a, b, c));
        try testing.expectEqual(s, signOfFloat(orient2d(b, c, a)));
        try testing.expectEqual(s, signOfFloat(orient2d(c, a, b)));
        try testing.expectEqual(-s, signOfFloat(orient2d(b, a, c)));
    }
}

test "orient2d: agrees with big-integer arithmetic on random near-degenerate points" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    for (0..FUZZ_CASES) |_| {
        const a = randomPoint2(random, 2);
        const b = randomPoint2(random, 2);
        const c = randomPoint2(random, 2);
        try testing.expectEqual(try exactOrient2d(testing.allocator, a, b, c), signOfFloat(orient2d(a, b, c)));
    }
}

test "incircle: inside, outside, and zero for cocircular points" {
    const a = [2]f64{ 1, 0 };
    const b = [2]f64{ 0, 1 };
    const c = [2]f64{ -1, 0 };
    try testing.expect(incircle(a, b, c, .{ 0, 0 }) > 0);
    try testing.expect(incircle(a, b, c, .{ 2, 2 }) < 0);
    try testing.expectEqual(@as(f64, 0), incircle(a, b, c, .{ 0, -1 }));
    // Clockwise order reverses the sign
    try testing.expect(incircle(c, b, a, .{ 0, 0 }) < 0);
    // Cocircular at a scale that overflows the naive lift
    try testing.expectEqual(@as(f64, 0), incircle(.{ 1e60, 0 }, .{ 0, 1e60 }, .{ -1e60, 0 }, .{ 0, -1e60 }));
    try testing.expectEqual(@as(f64, 0), incircle(.{ 1e-60, 0 }, .{ 0, 1e-60 }, .{ -1e-60, 0 }, .{ 0, -1e-60 }));
}

test "incircle: agrees with big-integer arithmetic on random near-degenerate points" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    for (0..FUZZ_CASES) |_| {
        const a = randomPoint2(random, 4);
        const b = randomPoint2(random, 4);
        const c = randomPoint2(random, 4);
        const d = randomPoint2(random, 4);
        try testing.expectEqual(try exactIncircle(testing.allocator, a, b, c, d), signOfFloat(incircle(a, b, c, d)));
    }
}

test "orient3d: the side of a plane, and zero for coplanar points" {
    const a = [3]f64{ 0, 0, 0 };
    const b = [3]f64{ 1, 0, 0 };
    const c = [3]f64{ 0, 1, 0 };
    try testing.expect(orient3d(a, b, c, .{ 0, 0, -1 }) > 0);
    try testing.expect(orient3d(a, b, c, .{ 0, 0, 1 }) < 0);
    try testing.expectEqual(@as(f64, 0), orient3d(a, b, c, .{ 5, -3, 0 }));
    try testing.expectEqual(@as(f64, 0), orient3d(.{ 1e-90, 2e-90, 3e-90 }, .{ 2e-90, 4e-90, 6e-90 }, .{ 3e-90, 6e-90, 9e-90 }, .{ 0, 0, 1e-90 }));
}

test "orient3d: agrees with big-integer arithmetic on random near-degenerate points" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    for (0..FUZZ_CASES) |_| {
        const a = randomPoint3(random);
        const b = randomPoint3(random);
        const c = randomPoint3(random);
        const d = randomPoint3(random);
        try testing.expectEqual(try exactOrient3d(testing.allocator, a, b, c, d), signOfFloat(orient3d(a, b, c, d)));
    }
}

/// A coordinate from a small set at a random scale, moved by a few ulps: most triples and
/// quadruples are then degenerate or a few ulps from it, where the estimates can't decide.
/// The scales keep the predicate's products (of degree `degree` in the coordinates) from
/// overflowing or underflowing, which the exact arithmetic assumes (predicates.zig).
fn randomCoordinate(random: std.Random, comptime degree: u8) f64 {
    const grid = [_]f64{ 0, 0.5, 1, 2, 3, 12, 24, -1, -2 };
    // The expansions' lowest components are about 2^(-53·degree) of the products
    const small: f64 = switch (degree) {
        2 => 1e-100,
        3 => 1e-60,
        4 => 1e-40,
        8 => 1e-20,
        else => unreachable,
    };
    const scales = [_]f64{ 1, 1e-20, 1e20, small, 1.0 / small };
    var x = grid[random.uintLessThan(usize, grid.len)] * scales[random.uintLessThan(usize, scales.len)];
    // Zero stays zero: a nudge from it is a subnormal, below the exactness range
    var ulps = if (x == 0.0) 0 else random.uintLessThan(usize, MAX_ULPS + 1);
    const up = random.boolean();
    while (ulps > 0) : (ulps -= 1) x = std.math.nextAfter(f64, x, if (up) std.math.inf(f64) else -std.math.inf(f64));
    return x;
}

pub fn randomPoint2(random: std.Random, comptime degree: u8) [2]f64 {
    return .{ randomCoordinate(random, degree), randomCoordinate(random, degree) };
}

fn randomPoint3(random: std.Random) [3]f64 {
    return .{ randomCoordinate(random, 3), randomCoordinate(random, 3), randomCoordinate(random, 3) };
}

test "inCircle: inside, outside, on the circle at integer points, and a ulp off it" {
    const c = [2]f64{ 0, 0 };
    try testing.expectEqual(@as(f64, 1), inCircle(c, 5, .{ 1, 1 }));
    try testing.expectEqual(@as(f64, -1), inCircle(c, 5, .{ 5, 5 }));
    try testing.expectEqual(@as(f64, 0), inCircle(c, 5, .{ 3, 4 }));
    // The same at a scale the naive squares underflow at (powers of two keep it exact)
    const tiny = std.math.pow(f64, 2.0, -100);
    try testing.expectEqual(@as(f64, 0), inCircle(.{ tiny, 2 * tiny }, 5 * tiny, .{ 4 * tiny, 6 * tiny }));
    // One ulp off the circle: the naive `r² − x² − y²` cannot tell, the predicate can
    const in = std.math.nextAfter(f64, 3.0, 0.0);
    const out = std.math.nextAfter(f64, 3.0, 10.0);
    try testing.expectEqual(@as(f64, 1), inCircle(c, 5, .{ in, 4 }));
    try testing.expectEqual(@as(f64, -1), inCircle(c, 5, .{ out, 4 }));
    // A grid of points a few ulps about (3, 4): every answer agrees with big integers
    var x: f64 = std.math.nextAfter(f64, std.math.nextAfter(f64, 3.0, 0.0), 0.0);
    for (0..5) |_| {
        var y: f64 = std.math.nextAfter(f64, std.math.nextAfter(f64, 4.0, 0.0), 0.0);
        for (0..5) |_| {
            try testing.expectEqual(try exactInCircle(testing.allocator, c, 5, .{ x, y }), signOfFloat(inCircle(c, 5, .{ x, y })));
            y = std.math.nextAfter(f64, y, 10.0);
        }
        x = std.math.nextAfter(f64, x, 10.0);
    }
}

test "inCircle: agrees with big-integer arithmetic on random near-degenerate inputs" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    for (0..FUZZ_CASES) |_| {
        const c = randomPoint2(random, 2);
        const r = randomCoordinate(random, 2);
        const p = randomPoint2(random, 2);
        try testing.expectEqual(try exactInCircle(testing.allocator, c, r, p), signOfFloat(inCircle(c, r, p)));
    }
}

test "lineCircleDiscriminant: a tangent is zero, a ulp either side crosses or misses" {
    const c = [2]f64{ 0, 0 };
    try testing.expectEqual(@as(f64, 1), lineCircleDiscriminant(.{ 0, -1 }, .{ 0, 1 }, c, 5));
    try testing.expectEqual(@as(f64, -1), lineCircleDiscriminant(.{ 6, -1 }, .{ 6, 1 }, c, 5));
    // The line x = 5 touches the circle of radius 5
    try testing.expectEqual(@as(f64, 0), lineCircleDiscriminant(.{ 5, -1 }, .{ 5, 1 }, c, 5));
    // The line through (3, 4) with slope −3/4 touches too (its points are integers)
    try testing.expectEqual(@as(f64, 0), lineCircleDiscriminant(.{ 7, 1 }, .{ -1, 7 }, c, 5));
    // One ulp inward crosses, one ulp outward misses: the floating discriminant is within
    // its own rounding here and the exact path decides
    const inward = std.math.nextAfter(f64, 5.0, 0.0);
    const outward = std.math.nextAfter(f64, 5.0, 10.0);
    try testing.expectEqual(@as(f64, 1), lineCircleDiscriminant(.{ inward, -1 }, .{ inward, 1 }, c, 5));
    try testing.expectEqual(@as(f64, -1), lineCircleDiscriminant(.{ outward, -1 }, .{ outward, 1 }, c, 5));
    // The same at a scale the naive products underflow at, and far from the origin
    try testing.expectEqual(@as(f64, 0), lineCircleDiscriminant(.{ 5e-30, -1e-30 }, .{ 5e-30, 1e-30 }, c, 5e-30));
    try testing.expectEqual(@as(f64, 0), lineCircleDiscriminant(.{ 1005, 999 }, .{ 1005, 1001 }, .{ 1000, 1000 }, 5));
    // A grid of tangent-like lines a few ulps about x = 5, against big integers
    var x: f64 = std.math.nextAfter(f64, std.math.nextAfter(f64, 5.0, 0.0), 0.0);
    for (0..5) |_| {
        var top: f64 = std.math.nextAfter(f64, std.math.nextAfter(f64, 5.0, 0.0), 0.0);
        for (0..5) |_| {
            const a = [2]f64{ x, -1 };
            const b = [2]f64{ top, 1 };
            try testing.expectEqual(try exactDiscriminant(testing.allocator, a, b, c, 5), signOfFloat(lineCircleDiscriminant(a, b, c, 5)));
            top = std.math.nextAfter(f64, top, 10.0);
        }
        x = std.math.nextAfter(f64, x, 10.0);
    }
}

test "lineCircleDiscriminant: agrees with big-integer arithmetic on random near-degenerate inputs" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    for (0..FUZZ_CASES) |_| {
        const a = randomPoint2(random, 4);
        const b = randomPoint2(random, 4);
        if (a[0] == b[0] and a[1] == b[1]) continue;
        const c = randomPoint2(random, 4);
        const r = randomCoordinate(random, 4);
        try testing.expectEqual(try exactDiscriminant(testing.allocator, a, b, c, r), signOfFloat(lineCircleDiscriminant(a, b, c, r)));
    }
}

test "lineCircleCrossing: where each root lies along the segment" {
    const c = [2]f64{ 0, 0 };
    // Through the circle: both crossings inside
    try testing.expectEqual(Place.inside, lineCircleCrossing(.{ -10, 0 }, .{ 10, 0 }, c, 5, .first).?);
    try testing.expectEqual(Place.inside, lineCircleCrossing(.{ -10, 0 }, .{ 10, 0 }, c, 5, .second).?);
    // Starting on the circle, ending on it, stopping short, starting inside
    try testing.expectEqual(Place.start, lineCircleCrossing(.{ -5, 0 }, .{ 10, 0 }, c, 5, .first).?);
    try testing.expectEqual(Place.end, lineCircleCrossing(.{ -10, 0 }, .{ 5, 0 }, c, 5, .second).?);
    try testing.expectEqual(Place.after, lineCircleCrossing(.{ -10, 0 }, .{ -6, 0 }, c, 5, .first).?);
    try testing.expectEqual(Place.after, lineCircleCrossing(.{ -10, 0 }, .{ -6, 0 }, c, 5, .second).?);
    try testing.expectEqual(Place.before, lineCircleCrossing(.{ -4, 0 }, .{ 4, 0 }, c, 5, .first).?);
    try testing.expectEqual(Place.after, lineCircleCrossing(.{ -4, 0 }, .{ 4, 0 }, c, 5, .second).?);
    try testing.expectEqual(Place.before, lineCircleCrossing(.{ 6, 0 }, .{ 10, 0 }, c, 5, .first).?);
    try testing.expectEqual(Place.before, lineCircleCrossing(.{ 6, 0 }, .{ 10, 0 }, c, 5, .second).?);
    // A tangent: both roots at the touching point, inside the segment or at its start
    try testing.expectEqual(Place.inside, lineCircleCrossing(.{ 5, -1 }, .{ 5, 1 }, c, 5, .first).?);
    try testing.expectEqual(Place.inside, lineCircleCrossing(.{ 5, -1 }, .{ 5, 1 }, c, 5, .second).?);
    try testing.expectEqual(Place.start, lineCircleCrossing(.{ 5, 0 }, .{ 5, 1 }, c, 5, .first).?);
    try testing.expectEqual(Place.start, lineCircleCrossing(.{ 5, 0 }, .{ 5, 1 }, c, 5, .second).?);
    try testing.expectEqual(Place.end, lineCircleCrossing(.{ 5, -1 }, .{ 5, 0 }, c, 5, .second).?);
    // A miss and a point segment
    try testing.expectEqual(@as(?Place, null), lineCircleCrossing(.{ 6, -1 }, .{ 6, 1 }, c, 5, .first));
    try testing.expectEqual(@as(?Place, null), lineCircleCrossing(.{ 1, 1 }, .{ 1, 1 }, c, 5, .first));
    // One ulp decides between ending on the circle and short of it
    const short = std.math.nextAfter(f64, 5.0, 0.0);
    try testing.expectEqual(Place.after, lineCircleCrossing(.{ -10, 0 }, .{ short, 0 }, c, 5, .second).?);
}

test "lineCircleCrossing: agrees with the formula over big integers on random inputs" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    for (0..FUZZ_CASES) |_| {
        const a = randomPoint2(random, 4);
        const b = randomPoint2(random, 4);
        const c = randomPoint2(random, 4);
        const r = randomCoordinate(random, 4);
        for ([_]Root{ .first, .second }) |root| {
            try testing.expectEqual(try exactCrossing(testing.allocator, a, b, c, r, root), lineCircleCrossing(a, b, c, r, root));
        }
    }
}

test "compareArcX: two crossings at a height, equal when irrational and told apart by a ulp" {
    // Unit circles at 0 and 1: the east of the first is right of the west of the second
    try testing.expectEqual(@as(f64, 1), compareArcX(.{ 0, 0 }, 1, .east, .{ 1, 0 }, 1, .west, 0));
    try testing.expectEqual(@as(f64, -1), compareArcX(.{ 0, 0 }, 1, .west, .{ 1, 0 }, 1, .west, 0));
    // Touching circles: the east of one is the west of the other, exactly
    try testing.expectEqual(@as(f64, 0), compareArcX(.{ 0, 0 }, 1, .east, .{ 2, 0 }, 1, .west, 0));
    // Two circles of radius 2 one above the other: at height 1 both reach x = √3
    try testing.expectEqual(@as(f64, 0), compareArcX(.{ 0, 0 }, 2, .east, .{ 0, 2 }, 2, .east, 1));
    // The second moved 2^-60 east, far below the spacing of doubles near √3: its crossing
    // is east of the first's (the floating difference is zero)
    const nudge = std.math.pow(f64, 2.0, -60);
    try testing.expectEqual(@as(f64, -1), compareArcX(.{ 0, 0 }, 2, .east, .{ nudge, 2 }, 2, .east, 1));
    try testing.expectEqual(@as(f64, 1), compareArcX(.{ 0, 0 }, 2, .east, .{ -nudge, 2 }, 2, .east, 1));
    // A height above a circle: its radicand counts as zero, the crossing is at its centre
    try testing.expectEqual(@as(f64, 0), compareArcX(.{ 3, 0 }, 1, .east, .{ 0, 0 }, 5, .east, 4));
    try testing.expectEqual(@as(f64, 1), compareArcX(.{ 3, 0 }, 1, .east, .{ 0, 0 }, 5, .east, std.math.nextAfter(f64, 4.0, 10.0)));
}

test "compareArcX: agrees with big-integer arithmetic and with quadruple precision on random inputs" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    var decided: usize = 0;
    for (0..FUZZ_CASES) |_| {
        const c1 = randomPoint2(random, 8);
        const r1 = randomCoordinate(random, 8);
        const c2 = randomPoint2(random, 8);
        const r2 = randomCoordinate(random, 8);
        const y = randomCoordinate(random, 8);
        const side1: Side = if (random.boolean()) .east else .west;
        const side2: Side = if (random.boolean()) .east else .west;
        const got = signOfFloat(compareArcX(c1, r1, side1, c2, r2, side2, y));
        try testing.expectEqual(try exactCompareArcX(testing.allocator, c1, r1, side1, c2, r2, side2, y), got);
        // Where quadruple precision is far from zero relative to the operands, it agrees
        const x1 = arcX128(c1, r1, side1, y) orelse continue;
        const x2 = arcX128(c2, r2, side2, y) orelse continue;
        const scale = @max(@abs(x1), @abs(x2));
        if (@abs(x1 - x2) > scale * 1e-25) {
            try testing.expectEqual(@as(i8, if (x1 > x2) 1 else -1), got);
            decided += 1;
        }
    }
    try testing.expect(decided > 0);
}

test "compareArcXWithLine: a crossing against a line at a height" {
    const c = [2]f64{ 0, 0 };
    // The circle of radius 5 at height 3 reaches x = 4: the line x = 4 meets it exactly,
    // the line through the origin and (8, 6) too
    try testing.expectEqual(@as(f64, 0), compareArcXWithLine(c, 5, .east, 3, .{ 4, 0 }, .{ 4, 10 }).?);
    try testing.expectEqual(@as(f64, 0), compareArcXWithLine(c, 5, .east, 3, .{ 0, 0 }, .{ 8, 6 }).?);
    try testing.expectEqual(@as(f64, 0), compareArcXWithLine(c, 5, .east, 3, .{ 8, 6 }, .{ 0, 0 }).?);
    try testing.expectEqual(@as(f64, 1), compareArcXWithLine(c, 5, .east, 3, .{ 3, 0 }, .{ 3, 10 }).?);
    try testing.expectEqual(@as(f64, -1), compareArcXWithLine(c, 5, .west, 3, .{ 3, 0 }, .{ 3, 10 }).?);
    // √3 is above its double: the line at the double of √3 is west of the crossing
    const root3 = @sqrt(3.0);
    try testing.expectEqual(@as(f64, 1), compareArcXWithLine(c, 2, .east, 1, .{ root3, 0 }, .{ root3, 2 }).?);
    try testing.expectEqual(@as(f64, -1), compareArcXWithLine(c, 2, .west, 1, .{ -root3, 0 }, .{ -root3, 2 }).?);
    // A horizontal line has no x at a height
    try testing.expectEqual(@as(?f64, null), compareArcXWithLine(c, 5, .east, 3, .{ 0, 1 }, .{ 4, 1 }));
}

test "compareArcXWithLine: agrees with big-integer arithmetic on random inputs" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    for (0..FUZZ_CASES) |_| {
        const c = randomPoint2(random, 4);
        const r = randomCoordinate(random, 4);
        const y = randomCoordinate(random, 4);
        const a = randomPoint2(random, 4);
        const b = randomPoint2(random, 4);
        const side: Side = if (random.boolean()) .east else .west;
        const expected = try exactCompareArcXWithLine(testing.allocator, c, r, side, y, a, b);
        const got = compareArcXWithLine(c, r, side, y, a, b);
        if (expected) |e| {
            try testing.expectEqual(e, signOfFloat(got.?));
        } else {
            try testing.expectEqual(@as(?f64, null), got);
        }
    }
}

test "compareLineX: two lines at a height, equal where they cross, horizontal refused" {
    // The lines y = x and y = 2 − x cross at (1, 1)
    const a1 = [2]f64{ 0, 0 };
    const b1 = [2]f64{ 2, 2 };
    const a2 = [2]f64{ 0, 2 };
    const b2 = [2]f64{ 2, 0 };
    try testing.expectEqual(@as(f64, 0), compareLineX(1, a1, b1, a2, b2).?);
    try testing.expectEqual(@as(f64, -1), compareLineX(0.5, a1, b1, a2, b2).?);
    try testing.expectEqual(@as(f64, 1), compareLineX(1.5, a1, b1, a2, b2).?);
    try testing.expectEqual(@as(f64, 1), compareLineX(0.5, a2, b2, a1, b1).?);
    // Reversing a line's points changes nothing
    try testing.expectEqual(@as(f64, -1), compareLineX(0.5, b1, a1, b2, a2).?);
    try testing.expectEqual(@as(?f64, null), compareLineX(0.5, a1, b1, .{ 0, 1 }, .{ 1, 1 }));
    // A ulp below the crossing the first is still west, however the floating x rounds
    try testing.expectEqual(@as(f64, -1), compareLineX(std.math.nextAfter(f64, 1.0, 0.0), a1, b1, a2, b2).?);
    try testing.expectEqual(@as(f64, 1), compareLineX(std.math.nextAfter(f64, 1.0, 2.0), a1, b1, a2, b2).?);
}

test "compareLineX: agrees with big-integer arithmetic on random near-degenerate inputs" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    for (0..FUZZ_CASES) |_| {
        const y = randomCoordinate(random, 3);
        const a1 = randomPoint2(random, 3);
        const b1 = randomPoint2(random, 3);
        const a2 = randomPoint2(random, 3);
        const b2 = randomPoint2(random, 3);
        const expected = try exactCompareLineX(testing.allocator, y, a1, b1, a2, b2);
        const got = compareLineX(y, a1, b1, a2, b2);
        if (expected) |e| {
            try testing.expectEqual(e, signOfFloat(got.?));
        } else {
            try testing.expectEqual(@as(?f64, null), got);
        }
    }
}

test "circlePair: how two circles lie, exactly, where the square-rooted distance says otherwise" {
    const circlePair = predicates.circlePair;
    // Dyadic numbers, every relation exact
    try testing.expectEqual(predicates.CirclePair.apart, circlePair(.{ 0, 0 }, 1, .{ 3, 0 }, 1.5));
    try testing.expectEqual(predicates.CirclePair.touching_outside, circlePair(.{ 0, 0 }, 1, .{ 0.75, 1 }, 0.25));
    try testing.expectEqual(predicates.CirclePair.crossing, circlePair(.{ 0, 0 }, 1, .{ 1, 0 }, 1));
    try testing.expectEqual(predicates.CirclePair.touching_inside, circlePair(.{ 0, 0 }, 3, .{ 0.75, 1 }, 1.75));
    try testing.expectEqual(predicates.CirclePair.nested, circlePair(.{ 0, 0 }, 3, .{ 0.5, 0 }, 1));
    // Centres √2 apart (d² = 2 exactly), radii fl(√2)/2 each: their sum fl(√2) is past √2,
    // so they cross; `√d²` rounds to that same fl(√2) and would have them touch
    const r = @sqrt(2.0) / 2.0;
    try testing.expect(@sqrt(@as(f64, 2)) == r + r);
    try testing.expectEqual(predicates.CirclePair.crossing, circlePair(.{ 0, 0 }, r, .{ 1, 1 }, r));
}
