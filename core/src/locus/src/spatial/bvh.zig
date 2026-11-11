//! A bounding-volume hierarchy over boxes (RTCD ch. 6, docs/architecture.md §12): built
//! top-down by splitting at the object mean along the longest side (object-median when the
//! mean leaves a side empty), leaves of at most `LEAF_SIZE` items, stored as a flat array
//! in preorder (a node's left child follows it; `right` names the right child; a leaf holds
//! its items' range). Queries descend with an explicit stack, so no recursion and no
//! allocation per query. The items are the caller's indices; the tree keeps a copy of
//! their boxes.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const Vec3 = vec.Vec3;
const Box3 = geometry.Box3;

pub const Error = error{OutOfMemory};

/// Items per leaf, at most.
pub const LEAF_SIZE: u32 = 4;
/// The deepest the tree gets before a leaf is forced: 2^48 items, far past any body.
const MAX_DEPTH: usize = 48;

pub const Node = struct {
    box: Box3,
    /// For an inner node, the index of its right child (the left is `index + 1`); for a
    /// leaf, the first of its items.
    right: u32,
    /// The leaf's item count; 0 for an inner node.
    count: u32,

    pub fn isLeaf(self: Node) bool {
        return self.count > 0;
    }
};

pub const Bvh = struct {
    nodes: []Node = &.{},
    /// The items, reordered so each leaf's are contiguous.
    items: []u32 = &.{},
    boxes: []Box3 = &.{},

    pub fn deinit(self: *Bvh, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        allocator.free(self.items);
        allocator.free(self.boxes);
        self.* = undefined;
    }

    /// The tree over `boxes` (item `i` is `boxes[i]`); an empty set gives an empty tree.
    pub fn build(allocator: std.mem.Allocator, boxes: []const Box3) Error!Bvh {
        var tree = Bvh{};
        errdefer tree.deinit(allocator);
        tree.boxes = try allocator.dupe(Box3, boxes);
        tree.items = try allocator.alloc(u32, boxes.len);
        for (tree.items, 0..) |*it, i| it.* = @intCast(i);
        if (boxes.len == 0) {
            tree.nodes = try allocator.alloc(Node, 0);
            return tree;
        }
        var nodes = std.ArrayList(Node).empty;
        defer nodes.deinit(allocator);
        // A node for every leaf and inner node: at most 2n − 1
        try nodes.ensureTotalCapacity(allocator, 2 * boxes.len);
        try tree.buildRange(allocator, &nodes, 0, @intCast(boxes.len), 0);
        tree.nodes = try nodes.toOwnedSlice(allocator);
        return tree;
    }

    fn buildRange(self: *Bvh, allocator: std.mem.Allocator, nodes: *std.ArrayList(Node), start: u32, end: u32, depth: usize) Error!void {
        var box = Box3.empty;
        var mean = vec.ZERO3;
        var i = start;
        while (i < end) : (i += 1) {
            const b = self.boxes[self.items[i]];
            box = Box3.merge(box, b);
            mean = vec.add(mean, b.center());
        }
        const index = nodes.items.len;
        try nodes.append(allocator, .{ .box = box, .right = 0, .count = 0 });
        const n = end - start;
        if (n <= LEAF_SIZE or depth >= MAX_DEPTH) {
            nodes.items[index] = .{ .box = box, .right = start, .count = n };
            return;
        }
        // Split at the mean of the centres along the longest side; when every centre is
        // on one side (equal centres), at the median
        const axis = vec.maxAxis(box.size());
        const split = mean[axis] / @as(f64, @floatFromInt(n));
        var mid = partition(self.items[start..end], self.boxes, axis, split) + start;
        if (mid == start or mid == end) {
            std.mem.sort(u32, self.items[start..end], SortContext{ .boxes = self.boxes, .axis = axis }, SortContext.lessThan);
            mid = start + n / 2;
        }
        try self.buildRange(allocator, nodes, start, mid, depth + 1);
        nodes.items[index].right = @intCast(nodes.items.len);
        try self.buildRange(allocator, nodes, mid, end, depth + 1);
    }

    /// Calls `visit(ctx, item)` for every item whose box overlaps `box`; `visit` returns
    /// false to stop.
    pub fn query(self: *const Bvh, box: Box3, ctx: anytype, comptime visit: fn (@TypeOf(ctx), u32) bool) void {
        if (self.nodes.len == 0) return;
        var stack: [MAX_DEPTH + 2]u32 = undefined;
        var top: usize = 1;
        stack[0] = 0;
        while (top > 0) {
            top -= 1;
            const index = stack[top];
            const node = self.nodes[index];
            if (!node.box.overlaps(box)) continue;
            if (node.isLeaf()) {
                var i = node.right;
                while (i < node.right + node.count) : (i += 1) {
                    const item = self.items[i];
                    if (self.boxes[item].overlaps(box) and !visit(ctx, item)) return;
                }
            } else {
                stack[top] = node.right;
                stack[top + 1] = index + 1;
                top += 2;
            }
        }
    }

    /// Calls `visit(ctx, item)` for every item whose box the segment `origin + t·dir`,
    /// `t` in `[lo, hi]`, meets (the slab test, RTCD §5.3.3); `visit` returns false to stop.
    pub fn querySegment(self: *const Bvh, origin: Vec3, dir: Vec3, lo: f64, hi: f64, ctx: anytype, comptime visit: fn (@TypeOf(ctx), u32) bool) void {
        if (self.nodes.len == 0) return;
        var stack: [MAX_DEPTH + 2]u32 = undefined;
        var top: usize = 1;
        stack[0] = 0;
        while (top > 0) {
            top -= 1;
            const index = stack[top];
            const node = self.nodes[index];
            if (!segmentMeetsBox(node.box, origin, dir, lo, hi)) continue;
            if (node.isLeaf()) {
                var i = node.right;
                while (i < node.right + node.count) : (i += 1) {
                    const item = self.items[i];
                    if (segmentMeetsBox(self.boxes[item], origin, dir, lo, hi) and !visit(ctx, item)) return;
                }
            } else {
                stack[top] = node.right;
                stack[top + 1] = index + 1;
                top += 2;
            }
        }
    }

    /// The pairs of items of two trees whose boxes overlap, through `visit(ctx, a, b)`,
    /// descending the larger node first (RTCD §6.4).
    pub fn queryPairs(self: *const Bvh, other: *const Bvh, ctx: anytype, comptime visit: fn (@TypeOf(ctx), u32, u32) bool) void {
        if (self.nodes.len == 0 or other.nodes.len == 0) return;
        var stack: [2 * (2 * MAX_DEPTH + 4)]u32 = undefined;
        var top: usize = 2;
        stack[0] = 0;
        stack[1] = 0;
        while (top > 0) {
            top -= 2;
            const ia = stack[top];
            const ib = stack[top + 1];
            const a = self.nodes[ia];
            const b = other.nodes[ib];
            if (!a.box.overlaps(b.box)) continue;
            if (a.isLeaf() and b.isLeaf()) {
                var i = a.right;
                while (i < a.right + a.count) : (i += 1) {
                    var j = b.right;
                    while (j < b.right + b.count) : (j += 1) {
                        const x = self.items[i];
                        const y = other.items[j];
                        if (self.boxes[x].overlaps(other.boxes[y]) and !visit(ctx, x, y)) return;
                    }
                }
            } else if (b.isLeaf() or (!a.isLeaf() and a.box.extent() >= b.box.extent())) {
                stack[top] = a.right;
                stack[top + 1] = ib;
                stack[top + 2] = ia + 1;
                stack[top + 3] = ib;
                top += 4;
            } else {
                stack[top] = ia;
                stack[top + 1] = b.right;
                stack[top + 2] = ia;
                stack[top + 3] = ib + 1;
                top += 4;
            }
        }
    }

    pub fn count(self: *const Bvh) usize {
        return self.items.len;
    }
};

/// Whether the segment `origin + t·dir`, `t` in `[lo, hi]`, meets `box` (closed): the
/// parameter range left after clipping by each axis's slab is not empty. A direction
/// component of zero keeps the range when the origin is within the slab, empties it else.
pub fn segmentMeetsBox(box: Box3, origin: Vec3, dir: Vec3, lo: f64, hi: f64) bool {
    if (box.isEmpty()) return false;
    var t0 = lo;
    var t1 = hi;
    for (0..3) |axis| {
        if (dir[axis] == 0) {
            if (origin[axis] < box.min[axis] or origin[axis] > box.max[axis]) return false;
            continue;
        }
        const inv = 1.0 / dir[axis];
        var near = (box.min[axis] - origin[axis]) * inv;
        var far = (box.max[axis] - origin[axis]) * inv;
        if (near > far) std.mem.swap(f64, &near, &far);
        t0 = @max(t0, near);
        t1 = @min(t1, far);
        if (t0 > t1) return false;
    }
    return true;
}

/// Moves the items whose box centre is below `split` on `axis` to the front; returns how
/// many.
fn partition(items: []u32, boxes: []const Box3, axis: usize, split: f64) u32 {
    var left: usize = 0;
    var right: usize = items.len;
    while (left < right) {
        if (boxes[items[left]].center()[axis] < split) {
            left += 1;
        } else {
            right -= 1;
            std.mem.swap(u32, &items[left], &items[right]);
        }
    }
    return @intCast(left);
}

const SortContext = struct {
    boxes: []const Box3,
    axis: usize,
    fn lessThan(self: SortContext, a: u32, b: u32) bool {
        return self.boxes[a].center()[self.axis] < self.boxes[b].center()[self.axis];
    }
};
