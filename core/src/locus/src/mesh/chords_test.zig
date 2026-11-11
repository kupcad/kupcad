//! Certified chords of free-form edges: every span's bow within the resolution's budget,
//! checked by dense evaluation (which can only confirm what the enclosure certified),
//! sample counts comparable to a circle's grid for an arc, knots among the samples, a
//! line as a degree-one curve uncut, refusals for a cusp, and a random run.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const curves = @import("../geometry/curves.zig");
const nurbs = @import("../geometry/nurbs.zig");
const tolerance = @import("../tolerance.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const chords = @import("chords.zig");
const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;

const PI = std.math.pi;
/// Evaluations per span of the dense check.
const DENSE = 64;
/// Rounding slack on the budget comparison.
const SLACK = 1e-9;

/// `sampleParams` on `curve` over `[t0, t1]`, then every span (the ends included) dense
/// checked: each point within the bow budget across its chord and within the budget past
/// its ends. The interior samples, owned by the caller.
fn expectCertified(curve: curves.Curve, t0: f64, t1: f64, resolution: tolerance.Resolution) ![]f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var out: std.ArrayList(f64) = .empty;
    errdefer out.deinit(testing.allocator);
    try chords.sampleParams(testing.allocator, curve, t0, t1, resolution, &out, &diag, .none);
    var prev = t0;
    for (out.items) |t| {
        try testing.expect(t > prev and t < t1);
        prev = t;
    }
    var a = t0;
    for (0..out.items.len + 1) |k| {
        const b = if (k < out.items.len) out.items[k] else t1;
        try expectSpanWithin(curve, a, b, resolution);
        a = b;
    }
    return out.toOwnedSlice(testing.allocator);
}

fn expectSpanWithin(curve: curves.Curve, a: f64, b: f64, resolution: tolerance.Resolution) !void {
    const pa = curve.eval(a);
    const pb = curve.eval(b);
    const chord = vec.sub(pb, pa);
    const length = vec.length(chord);
    try testing.expect(length > 0);
    const dir = vec.scale(chord, 1.0 / length);
    const budget = resolution.chordBow(length) + SLACK * @max(length, 1);
    for (0..DENSE + 1) |i| {
        const t = a + (b - a) * @as(f64, @floatFromInt(i)) / DENSE;
        const d = vec.sub(curve.eval(t), pa);
        const along = vec.dot(d, dir);
        const across = vec.length(vec.sub(d, vec.scale(dir, along)));
        try testing.expect(across <= budget);
        try testing.expect(along >= -budget and along <= length + budget);
    }
}

test "chords: the bow budget is a circle segment's sagitta, coarser of the angle and the length rules" {
    const r: tolerance.Resolution = .{};
    // A long chord: the angle rule, 12° of turning
    try testing.expectApproxEqAbs(0.5 * 10 * @tan(12.0 * PI / 180.0 / 4.0), r.chordBow(10), 1e-15);
    // A short chord: the coarsest circle's 72°
    try testing.expectApproxEqAbs(0.5 * 1 * @tan(72.0 * PI / 180.0 / 4.0), r.chordBow(1), 1e-15);
    // A fixed count: its own turning
    const fixed: tolerance.Resolution = .{ .segments = 36 };
    try testing.expectApproxEqAbs(0.5 * 1 * @tan(10.0 * PI / 180.0 / 4.0), fixed.chordBow(1), 1e-15);
}

test "chords: a rational arc is cut about as a circle of its radius, every span certified" {
    var arc = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 2, 0, PI / 2.0);
    defer arc.deinit(testing.allocator);
    const curve: curves.Curve = .{ .nurbs = arc.view() };
    const t1 = arc.knots[arc.knots.len - 1];
    const samples = try expectCertified(curve, 0, t1, .{});
    defer testing.allocator.free(samples);
    // A circle of radius 2 gets 7 segments a turn at the default resolution, so its
    // quarter one or two interior points; the enclosure is a little fatter than the arc
    try testing.expect(samples.len >= 1 and samples.len <= 4);
    for (samples) |t| try testing.expectApproxEqAbs(@as(f64, 2), vec.length(curve.eval(t)), 1e-12);
    // At 64 a turn, the quarter gets about 16 pieces
    const fine = try expectCertified(curve, 0, t1, .{ .segments = 64 });
    defer testing.allocator.free(fine);
    try testing.expect(fine.len >= 15 and fine.len <= 40);
    // A big arc is cut by length: chords of about min_length
    var big = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 100, 0, PI / 2.0);
    defer big.deinit(testing.allocator);
    const big_curve: curves.Curve = .{ .nurbs = big.view() };
    const coarse = try expectCertified(big_curve, 0, big.knots[big.knots.len - 1], .{});
    defer testing.allocator.free(coarse);
    // The angle rule holds for chords past min_length: 90° in 12° steps is 8 pieces
    try testing.expect(coarse.len >= 7 and coarse.len <= 16);
}

test "chords: an ellipse's spans are certified by intervals, in any frame" {
    const e: curves.Ellipse = .{ .c = .{ 1, 2, 3 }, .x = vec.normalized(.{ 1, 1, 0 }).?, .y = vec.normalized(.{ -1, 1, 1 }).?, .a = 5, .b = 2 };
    const curve: curves.Curve = .{ .ellipse = e };
    const samples = try expectCertified(curve, 0, 2 * PI, .{});
    defer testing.allocator.free(samples);
    try testing.expect(samples.len >= 12 and samples.len <= 64);
    // A short arc of it
    const short = try expectCertified(curve, 0.3, 0.9, .{ .segments = 90 });
    defer testing.allocator.free(short);
    try testing.expect(short.len >= 1);
}

test "chords: a line as a degree-one curve is uncut; a cubic's knots are among its samples" {
    var line = try nurbs.lineSegment(testing.allocator, .{ 0, 0, 0 }, .{ 10, 5, 1 }, 0, 1);
    defer line.deinit(testing.allocator);
    const straight = try expectCertified(.{ .nurbs = line.view() }, 0, 1, .{});
    defer testing.allocator.free(straight);
    try testing.expectEqual(@as(usize, 0), straight.len);
    // A cubic with two spans, a wiggle through its control polygon
    const knots = [_]f64{ 0, 0, 0, 0, 1, 2, 2, 2, 2 };
    const points = [_]Vec4{ .{ 0, 0, 0, 1 }, .{ 1, 2, 0, 1 }, .{ 2, -2, 0, 1 }, .{ 3, 2, 0, 1 }, .{ 4, 0, 0, 1 } };
    const cubic: curves.Curve = .{ .nurbs = .{ .degree = 3, .knots = &knots, .points = &points } };
    const samples = try expectCertified(cubic, 0, 2, .{});
    defer testing.allocator.free(samples);
    var has_knot = false;
    for (samples) |t| has_knot = has_knot or t == 1;
    try testing.expect(has_knot);
    try testing.expect(samples.len >= 3);
    // The same over a part of the domain across the knot, and over one span
    const part = try expectCertified(cubic, 0.5, 1.5, .{});
    defer testing.allocator.free(part);
    const one = try expectCertified(cubic, 1.2, 1.9, .{ .segments = 16 });
    defer testing.allocator.free(one);
}

test "chords: a cusp is refused with a finding, not sampled and hoped for" {
    // A quadratic that runs out and back along one line: its halves are straight and
    // pass; a cusp that turns at a point no chord budget can hold does not
    const knots = [_]f64{ 0, 0, 0, 0, 1, 1, 1, 1 };
    // The curve goes (0,0) → towards (3,1) → back: a cusp near the middle where the
    // tangent vanishes and turns
    const points = [_]Vec4{ .{ 0, 0, 0, 1 }, .{ 3, 1, 0, 1 }, .{ -3, 1, 0, 1 }, .{ 0, 0, 0, 1 } };
    const curve: curves.Curve = .{ .nurbs = .{ .degree = 3, .knots = &knots, .points = &points } };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var out: std.ArrayList(f64) = .empty;
    defer out.deinit(testing.allocator);
    // Over a range whose chord is a point (closed): halved until the halves pass
    const result = chords.sampleParams(testing.allocator, curve, 0, 1, .{}, &out, &diag, .of(.edge, 3));
    if (result) |_| {
        // Every span still holds its budget
        var a: f64 = 0;
        for (0..out.items.len + 1) |k| {
            const b = if (k < out.items.len) out.items[k] else 1;
            try expectSpanWithin(curve, a, b, .{});
            a = b;
        }
    } else |err| {
        try testing.expectEqual(error.LimitExceeded, err);
        try testing.expectEqual(@as(u32, 3), diag.first().?.entity.index);
    }
}

test "chords: random ellipses and curves are certified at random resolutions" {
    var prng = std.Random.DefaultPrng.init(0xc40d);
    const random = prng.random();
    for (0..40) |_| {
        const resolution: tolerance.Resolution = if (random.boolean()) .{} else .{ .segments = 5 + random.uintLessThan(u32, 60) };
        if (random.boolean()) {
            const x = vec.normalized(.{ random.float(f64) - 0.5, random.float(f64) - 0.5, random.float(f64) - 0.5 }) orelse vec.X3;
            const y0 = vec.perpendicular(x);
            const e: curves.Ellipse = .{ .c = .{ random.float(f64) * 10, 0, 0 }, .x = x, .y = y0, .a = 0.1 + random.float(f64) * 20, .b = 0.1 + random.float(f64) * 20 };
            const t0 = random.float(f64) * 2;
            const t1 = t0 + 0.1 + random.float(f64) * 5;
            const samples = try expectCertified(.{ .ellipse = e }, t0, t1, resolution);
            testing.allocator.free(samples);
        } else {
            const degree: u8 = 1 + random.uintLessThan(u8, 4);
            const count: usize = degree + 1 + random.uintLessThan(usize, 4);
            var points: [8]Vec4 = undefined;
            for (points[0..count]) |*q| q.* = .{ random.float(f64) * 10, random.float(f64) * 10, random.float(f64) * 10, 0.5 + random.float(f64) };
            var knots: [16]f64 = undefined;
            const m = count + degree + 1;
            for (0..m) |i| knots[i] = if (i <= degree) 0 else if (i >= count) 1 else @as(f64, @floatFromInt(i - degree)) / @as(f64, @floatFromInt(count - degree));
            const curve: curves.Curve = .{ .nurbs = .{ .degree = degree, .knots = knots[0..m], .points = points[0..count] } };
            try testing.expect(curve.nurbs.isValid());
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            var out: std.ArrayList(f64) = .empty;
            defer out.deinit(testing.allocator);
            // A random polygon may fold into a cusp: a refusal is clean; a result certified
            chords.sampleParams(testing.allocator, curve, 0, 1, resolution, &out, &diag, .none) catch |err| {
                try testing.expectEqual(error.LimitExceeded, err);
                continue;
            };
            var a: f64 = 0;
            for (0..out.items.len + 1) |k| {
                const b = if (k < out.items.len) out.items[k] else 1;
                try expectSpanWithin(curve, a, b, resolution);
                a = b;
            }
        }
    }
}
