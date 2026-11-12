//! Two closed triangle meshes compared without booleans (locus-plan research/solidcraft.md
//! §1): how far apart their surfaces are, sampled both ways, and the volume where only one
//! of them has material, integrated along a grid of parallel lines. Nothing intersects the
//! two surfaces, so two meshes of one solid cut at different places compare as well as two
//! different solids do. The case rig compares the two engines' meshes of every corpus case
//! by it (tools/dev/case_rig_test.zig).
//!
//! The distance: each triangle of one mesh is sampled at its corners and, when it is larger
//! than `spacing`, on a grid of barycentric points at most `spacing` apart; each sample's
//! distance to the other surface comes from a bounding-volume tree of its triangles,
//! searched nearest box first (the closest point on a triangle by its Voronoi regions,
//! Ericson §5.1.5). The volume: lines parallel to z through a grid over both meshes' boxes
//! seen from above; along each, every triangle it passes through (the point in the
//! triangle's shadow by a half-open rule, so a line through a shared edge passes one of
//! the two) is a step in and out of its mesh by its normal's side, and the stretches inside
//! exactly one mesh, summed, times the cell's area, are the volume.

const std = @import("std");

pub const Mesh = struct {
    points: []const [3]f64,
    /// Counter-clockwise about the outward normal, as indices into `points`.
    triangles: []const [3]u32,
};

pub const Options = struct {
    /// The most a sample of a triangle lies from the next.
    spacing: f64,
    /// The lines of the volume's grid along each side.
    lines: u32 = 128,
};

pub const Comparison = struct {
    /// The largest distance from a sample of the first mesh to the second's surface.
    a_to_b: f64,
    /// And from the second's to the first's.
    b_to_a: f64,
    /// The volume inside exactly one of the two.
    only_one: f64,

    /// The sampled symmetric distance: the larger of the two.
    pub fn distance(self: Comparison) f64 {
        return @max(self.a_to_b, self.b_to_a);
    }
};

pub const Error = std.mem.Allocator.Error;

/// The most samples one triangle gets along an edge: a guard against a spacing far below
/// a triangle's size (the samples are this squared over two at most).
const MAX_STEPS = 256;
/// Triangles per leaf of the tree.
const LEAF = 4;
/// Where in its cell each of the volume grid's lines passes, as shares of the cell along x
/// and y: off the centre, and by amounts whose sum and difference are no simple fraction,
/// so a line passes no vertex, and no diagonal, of a mesh in round numbers.
const LINE_AT: [2]f64 = .{ 0.6180339887, 0.3819660113 + 0.0414213562 };

/// Compares `a` and `b`. Each must be closed and oriented (the volume counts a crossing in
/// or out by its triangle's normal); an empty mesh is nothing, at no distance from nothing.
pub fn compare(allocator: std.mem.Allocator, a: Mesh, b: Mesh, options: Options) Error!Comparison {
    var tree_a = try Tree.build(allocator, a);
    defer tree_a.deinit(allocator);
    var tree_b = try Tree.build(allocator, b);
    defer tree_b.deinit(allocator);
    return .{
        .a_to_b = farthestSample(a, &tree_b, options.spacing),
        .b_to_a = farthestSample(b, &tree_a, options.spacing),
        .only_one = try volumeOfOnlyOne(allocator, a, b, options.lines),
    };
}

// --- distance ---

/// The farthest any sample of `mesh` lies from the surface `tree` holds.
fn farthestSample(mesh: Mesh, tree: *const Tree, spacing: f64) f64 {
    if (tree.nodes.items.len == 0) return if (mesh.triangles.len == 0) 0 else std.math.inf(f64);
    var farthest: f64 = 0;
    for (mesh.triangles) |t| {
        const p = [3][3]f64{ mesh.points[t[0]], mesh.points[t[1]], mesh.points[t[2]] };
        const longest = @max(distance(p[0], p[1]), @max(distance(p[1], p[2]), distance(p[2], p[0])));
        const steps: usize = if (!(spacing > 0) or longest <= spacing) 1 else @min(MAX_STEPS, @as(usize, @intFromFloat(@ceil(longest / spacing))));
        const n: f64 = @floatFromInt(steps);
        for (0..steps + 1) |i| {
            for (0..steps + 1 - i) |j| {
                const u = @as(f64, @floatFromInt(i)) / n;
                const v = @as(f64, @floatFromInt(j)) / n;
                const q = add(add(scale(p[0], 1 - u - v), scale(p[1], u)), scale(p[2], v));
                farthest = @max(farthest, tree.nearest(q, farthest));
            }
        }
    }
    return farthest;
}

/// A bounding-volume tree of a mesh's triangles: nodes in preorder, each a box over a range
/// of `order` (a leaf) or over its two children (the right one at `right`).
const Tree = struct {
    mesh: Mesh,
    order: []u32,
    nodes: std.ArrayList(Node) = .empty,

    const Node = struct { box: Box, first: u32, count: u32, right: u32 };

    fn build(allocator: std.mem.Allocator, mesh: Mesh) Error!Tree {
        const order = try allocator.alloc(u32, mesh.triangles.len);
        errdefer allocator.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        var tree: Tree = .{ .mesh = mesh, .order = order };
        errdefer tree.nodes.deinit(allocator);
        if (order.len > 0) _ = try tree.split(allocator, 0, @intCast(order.len));
        return tree;
    }

    fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        allocator.free(self.order);
        self.nodes.deinit(allocator);
    }

    fn boxOf(self: *const Tree, triangle: u32) Box {
        var box = Box.empty;
        for (self.mesh.triangles[triangle]) |v| box.grow(self.mesh.points[v]);
        return box;
    }

    /// The node over `order[first..first + count]`, split at the median of the longest
    /// axis of its triangles' centres.
    fn split(self: *Tree, allocator: std.mem.Allocator, first: u32, count: u32) Error!u32 {
        const index: u32 = @intCast(self.nodes.items.len);
        var box = Box.empty;
        var centres = Box.empty;
        for (self.order[first..][0..count]) |t| {
            const b = self.boxOf(t);
            box = box.merge(b);
            centres.grow(b.centre());
        }
        try self.nodes.append(allocator, .{ .box = box, .first = first, .count = count, .right = 0 });
        if (count <= LEAF) return index;
        const axis = centres.longestAxis();
        const Context = struct {
            tree: *const Tree,
            axis: usize,
            fn lessThan(ctx: @This(), x: u32, y: u32) bool {
                return ctx.tree.boxOf(x).centre()[ctx.axis] < ctx.tree.boxOf(y).centre()[ctx.axis];
            }
        };
        std.mem.sort(u32, self.order[first..][0..count], Context{ .tree = self, .axis = axis }, Context.lessThan);
        const half = count / 2;
        _ = try self.split(allocator, first, half);
        const right = try self.split(allocator, first + half, count - half);
        self.nodes.items[index].right = right;
        self.nodes.items[index].count = 0;
        return index;
    }

    /// The distance from `p` to the nearest triangle, or `at_least` when every triangle is
    /// farther than that (the search stops there: a sample nearer than the farthest so
    /// far changes nothing).
    fn nearest(self: *const Tree, p: [3]f64, at_least: f64) f64 {
        var best = std.math.inf(f64);
        var stack: [64]u32 = undefined;
        var top: usize = 1;
        stack[0] = 0;
        while (top > 0) {
            top -= 1;
            const node = self.nodes.items[stack[top]];
            const gap = node.box.distanceTo(p);
            if (gap >= best) continue;
            if (node.count > 0) {
                for (self.order[node.first..][0..node.count]) |t| {
                    const tri = self.mesh.triangles[t];
                    best = @min(best, distance(p, closestOnTriangle(p, self.mesh.points[tri[0]], self.mesh.points[tri[1]], self.mesh.points[tri[2]])));
                }
                if (best <= at_least) return at_least;
                continue;
            }
            // The nearer child last, so it is searched first
            const left = stack[top] + 1;
            const nodes = self.nodes.items;
            const right_first = nodes[left].box.distanceTo(p) > nodes[node.right].box.distanceTo(p);
            // Median splits: a depth of 32 holds 2³² leaves, more than a u32 counts
            std.debug.assert(top + 2 <= stack.len);
            stack[top] = if (right_first) left else node.right;
            stack[top + 1] = if (right_first) node.right else left;
            top += 2;
        }
        return best;
    }
};

/// The point of triangle `abc` nearest `p` (Ericson, Real-Time Collision Detection §5.1.5):
/// a corner, a point on an edge, or the projection inside, by `p`'s Voronoi region.
fn closestOnTriangle(p: [3]f64, a: [3]f64, b: [3]f64, c: [3]f64) [3]f64 {
    const ab = sub(b, a);
    const ac = sub(c, a);
    const ap = sub(p, a);
    const d1 = dot(ab, ap);
    const d2 = dot(ac, ap);
    if (d1 <= 0 and d2 <= 0) return a;
    const bp = sub(p, b);
    const d3 = dot(ab, bp);
    const d4 = dot(ac, bp);
    if (d3 >= 0 and d4 <= d3) return b;
    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 and d1 >= 0 and d3 <= 0) return add(a, scale(ab, d1 / (d1 - d3)));
    const cp = sub(p, c);
    const d5 = dot(ab, cp);
    const d6 = dot(ac, cp);
    if (d6 >= 0 and d5 <= d6) return c;
    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 and d2 >= 0 and d6 <= 0) return add(a, scale(ac, d2 / (d2 - d6)));
    const va = d3 * d6 - d5 * d4;
    if (va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0) return add(b, scale(sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6))));
    const denom = 1 / (va + vb + vc);
    return add(a, add(scale(ab, vb * denom), scale(ac, vc * denom)));
}

// --- volume ---

/// A line's crossing of a mesh: where along z, and +1 going in, −1 going out.
const Crossing = struct {
    z: f64,
    step: i8,
    mesh: u1,

    fn below(_: void, x: Crossing, y: Crossing) bool {
        return x.z < y.z;
    }
};

/// The volume inside exactly one of `a` and `b`, by `lines` × `lines` lines along z over
/// the box of both seen from above.
fn volumeOfOnlyOne(allocator: std.mem.Allocator, a: Mesh, b: Mesh, lines: u32) Error!f64 {
    var box = Box.empty;
    for ([_]Mesh{ a, b }) |m| for (m.triangles) |t| for (t) |v| box.grow(m.points[v]);
    if (box.isEmpty() or lines == 0) return 0;
    const n: usize = lines;
    const step: [2]f64 = .{ (box.max[0] - box.min[0]) / @as(f64, @floatFromInt(n)), (box.max[1] - box.min[1]) / @as(f64, @floatFromInt(n)) };
    if (!(step[0] > 0) or !(step[1] > 0)) return 0;
    // Each cell's triangles (those whose shadow's box reaches it), both meshes', as a
    // compressed list: `starts[cell]..starts[cell + 1]` of `entries`
    const Entry = struct { mesh: u1, triangle: u32 };
    const counts = try allocator.alloc(u32, n * n + 1);
    defer allocator.free(counts);
    @memset(counts, 0);
    const cells = struct {
        fn range(lo: f64, hi: f64, origin: f64, size: f64, count: usize) [2]usize {
            const first = @as(isize, @intFromFloat(@floor((lo - origin) / size)));
            const last = @as(isize, @intFromFloat(@floor((hi - origin) / size)));
            const top: isize = @intCast(count - 1);
            return .{ @intCast(std.math.clamp(first, 0, top)), @intCast(std.math.clamp(last, 0, top)) };
        }
    };
    for ([_]Mesh{ a, b }) |m| for (m.triangles) |t| {
        var shadow = Box.empty;
        for (t) |v| shadow.grow(m.points[v]);
        const xs = cells.range(shadow.min[0], shadow.max[0], box.min[0], step[0], n);
        const ys = cells.range(shadow.min[1], shadow.max[1], box.min[1], step[1], n);
        for (ys[0]..ys[1] + 1) |y| for (xs[0]..xs[1] + 1) |x| {
            counts[y * n + x + 1] += 1;
        };
    };
    for (1..counts.len) |i| counts[i] += counts[i - 1];
    const entries = try allocator.alloc(Entry, counts[n * n]);
    defer allocator.free(entries);
    const fill = try allocator.alloc(u32, n * n);
    defer allocator.free(fill);
    @memset(fill, 0);
    for ([_]Mesh{ a, b }, 0..) |m, which| for (m.triangles, 0..) |t, ti| {
        var shadow = Box.empty;
        for (t) |v| shadow.grow(m.points[v]);
        const xs = cells.range(shadow.min[0], shadow.max[0], box.min[0], step[0], n);
        const ys = cells.range(shadow.min[1], shadow.max[1], box.min[1], step[1], n);
        for (ys[0]..ys[1] + 1) |y| for (xs[0]..xs[1] + 1) |x| {
            const cell = y * n + x;
            entries[counts[cell] + fill[cell]] = .{ .mesh = @intCast(which), .triangle = @intCast(ti) };
            fill[cell] += 1;
        };
    };
    var crossings: std.ArrayList(Crossing) = .empty;
    defer crossings.deinit(allocator);
    var total: f64 = 0;
    for (0..n) |y| for (0..n) |x| {
        const at: [2]f64 = .{ box.min[0] + (@as(f64, @floatFromInt(x)) + LINE_AT[0]) * step[0], box.min[1] + (@as(f64, @floatFromInt(y)) + LINE_AT[1]) * step[1] };
        crossings.clearRetainingCapacity();
        const cell = y * n + x;
        for (entries[counts[cell]..counts[cell + 1]]) |entry| {
            const m = if (entry.mesh == 0) a else b;
            const t = m.triangles[entry.triangle];
            if (crossingAt(at, m.points[t[0]], m.points[t[1]], m.points[t[2]])) |c| {
                try crossings.append(allocator, .{ .z = c.z, .step = c.step, .mesh = entry.mesh });
            }
        }
        std.mem.sort(Crossing, crossings.items, {}, Crossing.below);
        var winding: [2]i32 = .{ 0, 0 };
        var last: f64 = 0;
        for (crossings.items) |c| {
            if ((winding[0] > 0) != (winding[1] > 0)) total += c.z - last;
            winding[c.mesh] += c.step;
            last = c.z;
        }
    };
    return total * step[0] * step[1];
}

/// Where the line along z through `at` passes through triangle `abc` (its shadow holding
/// `at` by the half-open rule: inside each edge, or on an edge that is a top or a left one
/// of the shadow taken counter-clockwise), with +1 when it goes in (the outward normal
/// down) and −1 when it goes out; null when it misses or the triangle stands on edge.
fn crossingAt(at: [2]f64, a: [3]f64, b: [3]f64, c: [3]f64) ?struct { z: f64, step: i8 } {
    const area = orient(a, b, c);
    if (area == 0) return null;
    // The shadow counter-clockwise; the normal's side is the original order's
    const p = if (area > 0) [3][3]f64{ a, b, c } else [3][3]f64{ a, c, b };
    var w: [3]f64 = undefined;
    for (0..3) |k| {
        const u = p[(k + 1) % 3];
        const v = p[(k + 2) % 3];
        w[k] = orient2(u, v, at);
        if (w[k] < 0) return null;
        if (w[k] == 0 and !topLeft(u, v)) return null;
    }
    const sum = w[0] + w[1] + w[2];
    const z = (w[0] * p[0][2] + w[1] * p[1][2] + w[2] * p[2][2]) / sum;
    return .{ .z = z, .step = if (area > 0) -1 else 1 };
}

/// Twice the signed area of the shadow of `abc` (counter-clockwise positive).
fn orient(a: [3]f64, b: [3]f64, c: [3]f64) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

/// Which side of the line from `u` to `v` the point `p` lies on (positive to the left),
/// computed from the lesser end of the two whichever way the edge runs: the triangles on
/// either side of an edge, which run it opposite ways, get exactly opposite values, so a
/// line near the edge passes one of them, never both or neither.
fn orient2(u: [3]f64, v: [3]f64, p: [2]f64) f64 {
    const swap = v[0] < u[0] or (v[0] == u[0] and v[1] < u[1]);
    const lo = if (swap) v else u;
    const hi = if (swap) u else v;
    const w = (hi[0] - lo[0]) * (p[1] - lo[1]) - (hi[1] - lo[1]) * (p[0] - lo[0]);
    return if (swap) -w else w;
}

/// A counter-clockwise shadow's top edge (level, running west) or left edge (running
/// south): the edges a point on them belongs to.
fn topLeft(u: [3]f64, v: [3]f64) bool {
    return (u[1] == v[1] and v[0] < u[0]) or v[1] < u[1];
}

// --- small vectors and boxes ---

const Box = struct {
    min: [3]f64,
    max: [3]f64,

    const empty: Box = .{ .min = @splat(std.math.inf(f64)), .max = @splat(-std.math.inf(f64)) };

    fn isEmpty(self: Box) bool {
        return self.min[0] > self.max[0];
    }

    fn grow(self: *Box, p: [3]f64) void {
        for (0..3) |k| {
            self.min[k] = @min(self.min[k], p[k]);
            self.max[k] = @max(self.max[k], p[k]);
        }
    }

    fn merge(self: Box, other: Box) Box {
        var out = self;
        for (0..3) |k| {
            out.min[k] = @min(out.min[k], other.min[k]);
            out.max[k] = @max(out.max[k], other.max[k]);
        }
        return out;
    }

    fn centre(self: Box) [3]f64 {
        return .{ (self.min[0] + self.max[0]) / 2, (self.min[1] + self.max[1]) / 2, (self.min[2] + self.max[2]) / 2 };
    }

    fn longestAxis(self: Box) usize {
        var axis: usize = 0;
        for (1..3) |k| {
            if (self.max[k] - self.min[k] > self.max[axis] - self.min[axis]) axis = k;
        }
        return axis;
    }

    fn distanceTo(self: Box, p: [3]f64) f64 {
        var sq: f64 = 0;
        for (0..3) |k| {
            const d = @max(self.min[k] - p[k], 0, p[k] - self.max[k]);
            sq += d * d;
        }
        return @sqrt(sq);
    }
};

fn add(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn sub(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn scale(a: [3]f64, s: f64) [3]f64 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}

fn dot(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn distance(a: [3]f64, b: [3]f64) f64 {
    const d = sub(a, b);
    return @sqrt(dot(d, d));
}
