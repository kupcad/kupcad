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
