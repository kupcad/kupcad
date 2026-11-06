const std = @import("std");
const testing = std.testing;
const predicates = @import("predicates.zig");
const orient2d = predicates.orient2d;
const orient3d = predicates.orient3d;
const incircle = predicates.incircle;

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
