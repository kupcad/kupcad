//! A loft between two outlines of any shape, concave ones too: the ruled surface between
//! points matched along them, the base at z = 0 and the top at the height, closed by the
//! outlines themselves. Points are matched by how far along its outline each lies (as a
//! share of its length), so a square lofted to a circle keeps its corners; the top's start
//! is the one of its points that turns it least against the base. Both outlines' own
//! points are kept: each is sampled where either has a point. The evaluator lofts a
//! concave profile with it (a convex pair is their hull, exact).

const std = @import("std");
const triangulate = @import("triangulate.zig");

/// How many places along the outlines the twist is measured at, choosing the top's start.
const TWIST_SAMPLES = 64;
/// Shares of an outline's length this close are one place.
const SHARE_SLACK = 1e-12;

pub const Error = error{
    /// An outline has fewer than three points, or no length.
    Degenerate,
} || triangulate.Error;

/// The solid's points (the base's ring at z = 0, then the top's at the height) and its
/// triangles, each counter-clockwise seen from outside. Owned by the allocator.
pub const Mesh = struct {
    points: [][3]f64,
    triangles: [][3]u32,

    pub fn deinit(self: Mesh, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.triangles);
    }
};

/// The loft from the closed outline `base` to `top`, `height` above it (below it, for a
/// negative one; none is Degenerate).
pub fn ruled(allocator: std.mem.Allocator, base: []const [2]f64, top: []const [2]f64, height: f64) Error!Mesh {
    if (height == 0) return error.Degenerate;
    var a = try Outline.init(allocator, base);
    defer a.deinit(allocator);
    var b = try Outline.init(allocator, top);
    defer b.deinit(allocator);
    b.startAt(bestStart(a, b));

    // Every place either outline has a point, as a share of its length
    var shares: std.ArrayList(f64) = .empty;
    defer shares.deinit(allocator);
    try shares.appendSlice(allocator, a.shares);
    try shares.appendSlice(allocator, b.shares);
    std.mem.sort(f64, shares.items, {}, std.sort.asc(f64));
    var n: usize = 0;
    for (shares.items) |s| {
        if (n > 0 and s - shares.items[n - 1] <= SHARE_SLACK) continue;
        shares.items[n] = s;
        n += 1;
    }
    shares.shrinkRetainingCapacity(n);

    const points = try allocator.alloc([3]f64, 2 * n);
    errdefer allocator.free(points);
    for (shares.items, 0..) |s, i| {
        const p = a.at(s);
        const q = b.at(s);
        points[i] = .{ p[0], p[1], 0 };
        points[n + i] = .{ q[0], q[1], height };
    }

    var triangles: std.ArrayList([3]u32) = .empty;
    errdefer triangles.deinit(allocator);
    try triangles.ensureTotalCapacity(allocator, 4 * n);
    // The sides: each pair of matched points and the next, as two triangles
    for (0..n) |i| {
        const j = (i + 1) % n;
        const a0: u32 = @intCast(i);
        const a1: u32 = @intCast(j);
        const b0: u32 = @intCast(n + i);
        const b1: u32 = @intCast(n + j);
        triangles.appendSliceAssumeCapacity(&.{ .{ a0, a1, b1 }, .{ a0, b1, b0 } });
    }
    // The ends: the top as its ring runs (counter-clockwise from above), the base reversed
    const ring = try allocator.alloc(u32, n);
    defer allocator.free(ring);
    for (ring, 0..) |*corner, i| corner.* = @intCast(n + i);
    try triangulate.face(allocator, points, ring, &triangles);
    for (ring, 0..) |*corner, i| corner.* = @intCast(n - 1 - i);
    try triangulate.face(allocator, points, ring, &triangles);
    // Below the base, the solid is the one above mirrored: its triangles turn the other way
    if (height < 0) for (triangles.items) |*t| std.mem.swap(u32, &t[1], &t[2]);
    return .{ .points = points, .triangles = try triangles.toOwnedSlice(allocator) };
}

/// A closed outline, counter-clockwise, with how far along it each point lies.
const Outline = struct {
    points: [][2]f64,
    /// Each point's distance along the outline from the first, as a share of its length
    shares: []f64,
    center: [2]f64,

    fn init(allocator: std.mem.Allocator, given: []const [2]f64) Error!Outline {
        if (given.len < 3) return error.Degenerate;
        const points = try allocator.dupe([2]f64, given);
        errdefer allocator.free(points);
        var twice_area: f64 = 0;
        for (points, 0..) |p, i| {
            const q = points[(i + 1) % points.len];
            twice_area += p[0] * q[1] - q[0] * p[1];
        }
        if (twice_area < 0) std.mem.reverse([2]f64, points);
        const shares = try allocator.alloc(f64, points.len);
        errdefer allocator.free(shares);
        var outline = Outline{ .points = points, .shares = shares, .center = .{ 0, 0 } };
        try outline.measure();
        return outline;
    }

    fn deinit(self: *Outline, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.shares);
    }

    /// The shares and the centre (the points' mean) from the points as they now run.
    fn measure(self: *Outline) error{Degenerate}!void {
        var total: f64 = 0;
        var sum = [2]f64{ 0, 0 };
        for (self.points, self.shares, 0..) |p, *share, i| {
            share.* = total;
            const q = self.points[(i + 1) % self.points.len];
            total += std.math.hypot(q[0] - p[0], q[1] - p[1]);
            sum = .{ sum[0] + p[0], sum[1] + p[1] };
        }
        if (!(total > 0)) return error.Degenerate;
        for (self.shares) |*share| share.* /= total;
        const count: f64 = @floatFromInt(self.points.len);
        self.center = .{ sum[0] / count, sum[1] / count };
    }

    /// The outline run from its point `k`.
    fn startAt(self: *Outline, k: usize) void {
        std.mem.rotate([2]f64, self.points, k);
        // The lengths don't change; only where they are counted from
        self.measure() catch unreachable;
    }

    /// The point `share` of the way along it.
    fn at(self: Outline, share: f64) [2]f64 {
        // The last point at or before the share, then on along its edge
        var lo: usize = 0;
        var hi: usize = self.shares.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (self.shares[mid] <= share) lo = mid else hi = mid;
        }
        const p = self.points[lo];
        const q = self.points[(lo + 1) % self.points.len];
        const end = if (lo + 1 < self.shares.len) self.shares[lo + 1] else 1;
        const t = if (end > self.shares[lo]) (share - self.shares[lo]) / (end - self.shares[lo]) else 0;
        return .{ p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t };
    }
};

/// The point of `top` to start it at so it twists least against `base`: the least sum of
/// squared distances between places matched along both, each from its centre.
fn bestStart(base: Outline, top: Outline) usize {
    var best: usize = 0;
    var best_cost = std.math.inf(f64);
    for (0..top.points.len) |k| {
        const offset = top.shares[k];
        var cost: f64 = 0;
        for (0..TWIST_SAMPLES) |j| {
            const s = @as(f64, @floatFromInt(j)) / TWIST_SAMPLES;
            const p = base.at(s);
            const shifted = s + offset;
            const q = top.at(if (shifted >= 1) shifted - 1 else shifted);
            const dx = (q[0] - top.center[0]) - (p[0] - base.center[0]);
            const dy = (q[1] - top.center[1]) - (p[1] - base.center[1]);
            cost += dx * dx + dy * dy;
        }
        if (cost < best_cost) {
            best_cost = cost;
            best = k;
        }
    }
    return best;
}
