const std = @import("std");
const testing = std.testing;
const interval = @import("interval.zig");
const Interval = interval.Interval;
const Box3 = interval.Box3;

/// Random cases per property.
const CASES = 2000;
const SEED = 0x1a7e_4a15;
/// Random operands lie within this many decades of 1 either way: wide enough to cross
/// scales, inside the range where the widening is sound.
const DECADES = 20;

fn containsReal(i: Interval, v: f128) bool {
    return @as(f128, i.lo) <= v and v <= @as(f128, i.hi);
}

fn randomValue(random: std.Random) f64 {
    const magnitude = std.math.pow(f64, 10.0, random.float(f64) * 2 * DECADES - DECADES);
    return if (random.boolean()) magnitude else -magnitude;
}

/// A random interval about a random value, sometimes a point.
fn randomInterval(random: std.Random) Interval {
    const x = randomValue(random);
    if (random.boolean()) return Interval.of(x);
    const w = @abs(x) * random.float(f64);
    return Interval.span(x - w, x + w);
}

/// A random real inside `i`, as an f128 (the endpoints and a point between).
fn pointIn(random: std.Random, i: Interval) f128 {
    const t: f128 = @floatCast(random.float(f64));
    return @as(f128, i.lo) + t * (@as(f128, i.hi) - @as(f128, i.lo));
}

test "Interval: π is bracketed and the basic queries hold" {
    try testing.expect(@as(f128, interval.PI.lo) < @as(f128, std.math.pi));
    try testing.expect(@as(f128, std.math.pi) < @as(f128, interval.PI.hi));
    const a = Interval.span(1, 3);
    try testing.expect(a.contains(1) and a.contains(2) and a.contains(3) and !a.contains(3.1));
    try testing.expect(a.encloses(Interval.span(1.5, 2)) and !a.encloses(Interval.span(0.5, 2)));
    try testing.expect(a.meets(Interval.span(3, 4)) and !a.meets(Interval.span(3.1, 4)));
    try testing.expectEqual(@as(f64, 2), a.width());
    try testing.expectEqual(@as(f64, 2), a.mid());
    try testing.expectEqual(Interval.span(-3, -1), a.neg());
    try testing.expectEqual(Interval.span(0, 3), Interval.span(-2, 3).abs());
    try testing.expectEqual(Interval.span(1, 2), Interval.span(-2, -1).abs());
    try testing.expectEqual(Interval.span(1, 4), Interval.hull(Interval.span(1, 2), Interval.span(3, 4)));
}

test "Interval: every operation encloses the exact result on random operands" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    for (0..CASES) |_| {
        const a = randomInterval(random);
        const b = randomInterval(random);
        const x = pointIn(random, a);
        const y = pointIn(random, b);
        try testing.expect(containsReal(a.add(b), x + y));
        try testing.expect(containsReal(a.sub(b), x - y));
        try testing.expect(containsReal(a.mul(b), x * y));
        try testing.expect(containsReal(a.square(), x * x));
        try testing.expect(containsReal(a.scale(b.lo), x * @as(f128, b.lo)));
        if (a.div(b)) |q| {
            try testing.expect(containsReal(q, x / y));
        } else {
            try testing.expect(b.contains(0));
        }
        if (a.sqrt()) |root| {
            try testing.expect(containsReal(root, @sqrt(@max(x, 0))));
        } else {
            try testing.expect(a.hi < 0);
        }
        // Widening is tight: a point's sum is within two ulps
        const p = Interval.of(a.lo).add(Interval.of(b.lo));
        try testing.expect(p.width() <= 2 * std.math.floatEps(f64) * @max(@abs(p.lo), @abs(p.hi)) + std.math.floatTrueMin(f64) * 4);
    }
}

test "Interval: division by an interval holding zero and the root of a negative one are refused" {
    try testing.expectEqual(@as(?Interval, null), Interval.span(1, 2).div(Interval.span(-1, 1)));
    try testing.expectEqual(@as(?Interval, null), Interval.span(1, 2).div(Interval.of(0)));
    try testing.expect(Interval.span(1, 2).div(Interval.span(2, 4)) != null);
    try testing.expectEqual(@as(?Interval, null), Interval.span(-2, -1).sqrt());
    // A root over an interval crossing zero starts at zero
    const r = Interval.span(-1, 4).sqrt().?;
    try testing.expectEqual(@as(f64, 0), r.lo);
    try testing.expect(r.contains(2));
}

test "Interval: sine and cosine enclose the library's values, tightly, and hold the crests" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    for (0..CASES) |_| {
        const x = (random.float(f64) * 2 - 1) * 40;
        const s = Interval.of(x).sin();
        const c = Interval.of(x).cos();
        try testing.expect(s.contains(@sin(x)));
        try testing.expect(c.contains(@cos(x)));
        // About 1e-13 at worst: the series' thirty roundings and π's own width, times |r|
        try testing.expect(s.width() < 2e-13);
        try testing.expect(c.width() < 2e-13);
        // An interval's sine holds the sine of a point in it
        const w = random.float(f64) * 3;
        const i = Interval.span(x, x + w);
        const inside = x + random.float(f64) * w;
        try testing.expect(i.sin().contains(@sin(inside)));
        try testing.expect(i.cos().contains(@cos(inside)));
    }
    // Exact angles
    try testing.expect(Interval.of(0).sin().contains(0));
    try testing.expect(Interval.of(0).cos().contains(1));
    try testing.expect(Interval.of(std.math.pi).sin().width() < 1e-13);
    try testing.expect(Interval.of(std.math.pi).cos().contains(-1));
    try testing.expect(Interval.of(std.math.pi / 2.0).sin().hi >= 1 - 1e-15);
    // An interval over a crest reaches 1; one short of it does not
    try testing.expectEqual(@as(f64, 1), Interval.span(0, 2).sin().hi);
    try testing.expect(Interval.span(0, 1).sin().hi < 0.85);
    try testing.expectEqual(@as(f64, -1), Interval.span(3, 6).sin().lo);
    try testing.expectEqual(@as(f64, 1), Interval.span(-1, 1).cos().hi);
    // A full turn is everything
    try testing.expectEqual(Interval.span(-1, 1), Interval.span(0, 7).sin());
    // Far from zero the reduction still holds
    try testing.expect(Interval.of(1e6).sin().contains(@sin(1e6)));
}

test "Box: hull, meets, contains, width" {
    const a = Box3.of(.{ 0, 0, 0 }).hull(Box3.of(.{ 1, 2, 3 }));
    try testing.expect(a.contains(.{ 0.5, 1, 2 }));
    try testing.expect(!a.contains(.{ 0.5, 1, 4 }));
    try testing.expect(a.meets(Box3.of(.{ 1, 2, 3 })));
    try testing.expect(!a.meets(Box3.of(.{ 1, 2, 3.5 })));
    try testing.expect(a.encloses(Box3.of(.{ 0.5, 0.5, 0.5 })));
    try testing.expectEqual(@as(f64, 3), a.width());
    try testing.expect(a.grown(0.5).contains(.{ -0.5, 2.5, 3.5 }));
}
