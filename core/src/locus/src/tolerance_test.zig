const std = @import("std");
const testing = std.testing;
const tolerance = @import("tolerance.zig");
const Tolerance = tolerance.Tolerance;
const Resolution = tolerance.Resolution;

test "Tolerance: fromZone keeps SMLib's proportions, fromSize follows the decade table" {
    const t = Tolerance.fromZone(1e-5);
    try testing.expectEqual(@as(f64, 1e-5), t.zone);
    try testing.expectEqual(@as(f64, 2e-5), t.xsect);
    try testing.expectEqual(@as(f64, 5e-6), t.approx);
    try testing.expectEqual(@as(f64, 1e-5), t.param);
    try testing.expectEqual(@as(f64, 1e-4), t.angle);
    try testing.expect(t.isValid());

    try testing.expectEqual(@as(f64, 1e-6), Tolerance.fromSize(0.5).zone);
    try testing.expectEqual(@as(f64, 1e-5), Tolerance.fromSize(1).zone);
    try testing.expectEqual(@as(f64, 1e-5), Tolerance.fromSize(99).zone);
    try testing.expectEqual(@as(f64, 1e-4), Tolerance.fromSize(100).zone);
    try testing.expectEqual(@as(f64, 1e-4), Tolerance.fromSize(9_999).zone);
    try testing.expectEqual(@as(f64, 1e-3), Tolerance.fromSize(10_000).zone);
    try testing.expectEqual(@as(f64, 1e-3), Tolerance.fromSize(1e9).zone);
    // A size that is not a number gets the finest zone, never a NaN
    try testing.expectEqual(@as(f64, 1e-6), Tolerance.fromSize(std.math.nan(f64)).zone);
}

test "Tolerance: merge takes the looser of each field; a bad tolerance is not valid" {
    const a = Tolerance.fromZone(1e-5);
    const b = Tolerance.fromZone(1e-3);
    const m = Tolerance.merge(a, b);
    try testing.expectEqual(b.zone, m.zone);
    try testing.expectEqual(b.xsect, m.xsect);
    try testing.expectEqual(b.approx, m.approx);
    try testing.expect(m.isValid());

    try testing.expect(!Tolerance.fromZone(0).isValid());
    try testing.expect(!Tolerance.fromZone(-1e-5).isValid());
    try testing.expect(!Tolerance.fromZone(std.math.nan(f64)).isValid());
    try testing.expect(!Tolerance.fromZone(std.math.inf(f64)).isValid());
    var upside_down = Tolerance.fromZone(1e-5);
    upside_down.xsect = 1e-6;
    try testing.expect(!upside_down.isValid());
}

test "Tolerance: the comparisons" {
    const t = Tolerance.fromZone(1e-5);
    try testing.expect(t.samePoint(.{ 0, 0, 0 }, .{ 0.6e-5, 0.6e-5, 0.4e-5 }));
    try testing.expect(!t.samePoint(.{ 0, 0, 0 }, .{ 1e-5, 1e-5, 0 }));
    try testing.expect(t.meets(2e-5));
    try testing.expect(!t.meets(2.1e-5));
    const z = [3]f64{ 0, 0, 1 };
    const tilted = [3]f64{ @sin(0.01), 0, @cos(0.01) }; // 0.57°: 1 − cos ≈ 5e-5
    try testing.expect(t.sameDirection(z, tilted));
    try testing.expect(!t.sameDirection(z, .{ 0, 0, -1 }));
    try testing.expect(t.parallel(z, .{ 0, 0, -1 }));
    try testing.expect(!t.parallel(z, .{ @sin(0.02), 0, @cos(0.02) })); // 1.1°: 2e-4
    try testing.expect(t.sameParam(0.5, 0.5 + 0.9e-5, 1.0));
    try testing.expect(!t.sameParam(0.5, 0.5 + 1.1e-5, 1.0));
    // A long domain scales the parametric tolerance with it
    try testing.expect(t.sameParam(100, 100 + 5e-4, 1000));
}

test "Resolution: segments when set, else by angle and length, never under five" {
    try testing.expectEqual(@as(u32, 12), (Resolution{ .segments = 12 }).segmentsFor(1000));
    const auto: Resolution = .{};
    try testing.expectEqual(@as(u32, 30), auto.segmentsFor(1000)); // 360 / 12
    try testing.expectEqual(@as(u32, 5), auto.segmentsFor(0.1)); // 2π·0.1 / 2 < 5
    try testing.expectEqual(@as(u32, 5), auto.segmentsFor(0));
    try testing.expectEqual(@as(u32, 5), auto.segmentsFor(-1));
    try testing.expectEqual(@as(u32, 16), auto.segmentsFor(5)); // ⌈2π·5 / 2⌉ = 16
}
