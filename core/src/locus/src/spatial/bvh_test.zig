const std = @import("std");
const testing = std.testing;
const geometry = @import("../geometry/types.zig");
const bvh = @import("bvh.zig");
const Box3 = geometry.Box3;

const BOXES = 500;
const QUERIES = 200;
const SEED = 0xb0b;

fn randomBox(random: std.Random) Box3 {
    const c = [3]f64{ random.float(f64) * 100, random.float(f64) * 100, random.float(f64) * 20 };
    const h = [3]f64{ random.float(f64) * 5, random.float(f64) * 5, random.float(f64) * 5 };
    return .{ .min = .{ c[0] - h[0], c[1] - h[1], c[2] - h[2] }, .max = .{ c[0] + h[0], c[1] + h[1], c[2] + h[2] } };
}

const Collect = struct {
    found: std.ArrayList(u32) = .empty,
    allocator: std.mem.Allocator,
    fn visit(self: *Collect, item: u32) bool {
        self.found.append(self.allocator, item) catch return false;
        return true;
    }
};

test "Bvh: a box query finds exactly what the linear scan finds, in some order" {
    var prng = std.Random.DefaultPrng.init(SEED);
    const random = prng.random();
    var boxes: [BOXES]Box3 = undefined;
    for (&boxes) |*b| b.* = randomBox(random);
    // Some identical boxes: the split then falls back to the median
    for (0..8) |i| boxes[i] = boxes[8];
    var tree = try bvh.Bvh.build(testing.allocator, &boxes);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, BOXES), tree.count());
    try testing.expect(tree.nodes.len <= 2 * BOXES);
    // Every leaf holds at most LEAF_SIZE items, and every item is in one leaf
    var covered: [BOXES]u8 = @splat(0);
    for (tree.nodes) |n| {
        if (!n.isLeaf()) continue;
        try testing.expect(n.count <= bvh.LEAF_SIZE);
        for (tree.items[n.right .. n.right + n.count]) |it| covered[it] += 1;
    }
    for (covered) |c| try testing.expectEqual(@as(u8, 1), c);
    for (0..QUERIES) |_| {
        const q = randomBox(random);
        var got = Collect{ .allocator = testing.allocator };
        defer got.found.deinit(testing.allocator);
        tree.query(q, &got, Collect.visit);
        std.mem.sort(u32, got.found.items, {}, std.sort.asc(u32));
        var expected = std.ArrayList(u32).empty;
        defer expected.deinit(testing.allocator);
        for (boxes, 0..) |b, i| if (b.overlaps(q)) try expected.append(testing.allocator, @intCast(i));
        try testing.expectEqualSlices(u32, expected.items, got.found.items);
    }
    // An empty tree answers nothing
    var none = try bvh.Bvh.build(testing.allocator, &.{});
    defer none.deinit(testing.allocator);
    var got = Collect{ .allocator = testing.allocator };
    defer got.found.deinit(testing.allocator);
    none.query(randomBox(random), &got, Collect.visit);
    try testing.expectEqual(@as(usize, 0), got.found.items.len);
}

const Pairs = struct {
    found: std.ArrayList([2]u32) = .empty,
    allocator: std.mem.Allocator,
    fn visit(self: *Pairs, a: u32, b: u32) bool {
        self.found.append(self.allocator, .{ a, b }) catch return false;
        return true;
    }
    fn lessThan(_: void, x: [2]u32, y: [2]u32) bool {
        return if (x[0] != y[0]) x[0] < y[0] else x[1] < y[1];
    }
};

test "Bvh: the overlapping pairs of two trees are exactly the linear scan's" {
    var prng = std.Random.DefaultPrng.init(SEED + 1);
    const random = prng.random();
    var a: [120]Box3 = undefined;
    var b: [90]Box3 = undefined;
    for (&a) |*x| x.* = randomBox(random);
    for (&b) |*x| x.* = randomBox(random);
    var ta = try bvh.Bvh.build(testing.allocator, &a);
    defer ta.deinit(testing.allocator);
    var tb = try bvh.Bvh.build(testing.allocator, &b);
    defer tb.deinit(testing.allocator);
    var got = Pairs{ .allocator = testing.allocator };
    defer got.found.deinit(testing.allocator);
    ta.queryPairs(&tb, &got, Pairs.visit);
    std.mem.sort([2]u32, got.found.items, {}, Pairs.lessThan);
    var expected = std.ArrayList([2]u32).empty;
    defer expected.deinit(testing.allocator);
    for (a, 0..) |x, i| for (b, 0..) |y, j| if (x.overlaps(y)) try expected.append(testing.allocator, .{ @intCast(i), @intCast(j) });
    try testing.expectEqualSlices([2]u32, expected.items, got.found.items);
    try testing.expect(expected.items.len > 0);
}

test "Bvh: a segment visits exactly the boxes it meets, by slab tests, axis-parallel and skew" {
    const allocator = testing.allocator;
    // A row of unit boxes along x, at x = 0, 2, 4, …, 18
    var boxes: [10]Box3 = undefined;
    for (&boxes, 0..) |*b, i| {
        const x: f64 = @floatFromInt(2 * i);
        b.* = .{ .min = .{ x, 0, 0 }, .max = .{ x + 1, 1, 1 } };
    }
    var tree = try bvh.Bvh.build(allocator, &boxes);
    defer tree.deinit(allocator);
    const Seen = struct {
        seen: std.ArrayList(u32) = .empty,
        fn visit(self: *@This(), item: u32) bool {
            self.seen.append(testing.allocator, item) catch return false;
            return true;
        }
    };
    // Along y through x = 4.5: only box 2
    var a: Seen = .{};
    defer a.seen.deinit(allocator);
    tree.querySegment(.{ 4.5, -5, 0.5 }, .{ 0, 1, 0 }, 0, 10, &a, Seen.visit);
    try testing.expectEqualSlices(u32, &.{2}, a.seen.items);
    // Along x from 3.5 to 9 at y = z = 0.5: boxes 2, 3, 4 (in any order; a box is closed,
    // so a start at x = 3 would touch box 1)
    var b: Seen = .{};
    defer b.seen.deinit(allocator);
    tree.querySegment(.{ 3.5, 0.5, 0.5 }, .{ 1, 0, 0 }, 0, 5.5, &b, Seen.visit);
    std.mem.sort(u32, b.seen.items, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, &.{ 2, 3, 4 }, b.seen.items);
    // The same line between boxes 2 and 3 (x from 5.5 to 5.9): nothing
    var c: Seen = .{};
    defer c.seen.deinit(allocator);
    tree.querySegment(.{ 5.5, 0.5, 0.5 }, .{ 1, 0, 0 }, 0, 0.4, &c, Seen.visit);
    try testing.expectEqual(@as(usize, 0), c.seen.items.len);
    // A skew segment above the row: nothing
    var d: Seen = .{};
    defer d.seen.deinit(allocator);
    tree.querySegment(.{ 0, 0, 2 }, .{ 1, 1, 0.1 }, 0, 20, &d, Seen.visit);
    try testing.expectEqual(@as(usize, 0), d.seen.items.len);
    // Every box against a brute-force slab test on random segments
    var prng = std.Random.DefaultPrng.init(0xb7);
    const random = prng.random();
    for (0..200) |_| {
        const o: [3]f64 = .{ random.float(f64) * 24 - 2, random.float(f64) * 4 - 1.5, random.float(f64) * 4 - 1.5 };
        const dir: [3]f64 = .{ random.float(f64) * 2 - 1, random.float(f64) * 2 - 1, random.float(f64) * 2 - 1 };
        var e: Seen = .{};
        defer e.seen.deinit(allocator);
        tree.querySegment(o, dir, 0, 5, &e, Seen.visit);
        var want: usize = 0;
        for (boxes) |box| want += @intFromBool(bvh.segmentMeetsBox(box, o, dir, 0, 5));
        try testing.expectEqual(want, e.seen.items.len);
    }
}
