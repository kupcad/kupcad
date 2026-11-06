//! A constrained Delaunay triangulation of a polygon with holes (docs/architecture.md
//! §7.7, D13; KNOWLEDGE §8): the polygon is cut into y-monotone pieces by a plane sweep
//! with helpers (BKOS §3.2, holes native), each piece is triangulated by the two-chain
//! stack walk (BKOS §3.3), and Lawson flips (BKOS Lemma 9.4) turn the result into the
//! constrained Delaunay triangulation, the polygon's own edges never flipped. Every turn
//! and every circle test is an exact predicate and every tie is broken by the
//! lexicographic order (y, then x), so the output is deterministic for any simple input in
//! any position, collinear vertices included. Indices are the caller's point indices;
//! triangles come out counter-clockwise.

const std = @import("std");
const vec = @import("../math/vec.zig");
const predicates = @import("../math/predicates.zig");
const diagnostics = @import("../diagnostics.zig");
const Vec2 = vec.Vec2;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

const NONE: u32 = std.math.maxInt(u32);
/// Points a polygon may have: its rings' half-edges, two per point, and its diagonals',
/// fewer than two per point, are indexed by a u32.
const MAX_POINTS: usize = 1 << 29;
/// A triangle's side `i` runs from its vertex `i` to its vertex `i + 1`.
const SIDES = 3;

/// A polygon with holes as closed rings of points.
pub const Polygon = struct {
    points: []const Vec2,
    /// Ring `i` is `points[starts[i]..starts[i + 1]]`, its last point joined to its first,
    /// the region on its left: the outer ring counter-clockwise, holes clockwise. Every
    /// point is in one ring; `starts` has the ring count plus one entries, the last the
    /// point count.
    starts: []const u32,

    pub fn rings(self: Polygon) usize {
        return self.starts.len - 1;
    }

    pub fn ring(self: Polygon, i: usize) []const Vec2 {
        return self.points[self.starts[i]..self.starts[i + 1]];
    }
};

/// The triangles of `polygon`, counter-clockwise, as indices into its points; owned by
/// `allocator`. The rings must be simple and disjoint; a polygon that isn't, a ring of
/// fewer than three points, or one that repeats a point is `error.InvalidInput` with a
/// finding that says which.
pub fn triangulate(allocator: std.mem.Allocator, polygon: Polygon, diag: *Diagnostics) Error![][3]u32 {
    try validate(polygon, diag);
    var partition = try Partition.init(allocator, polygon);
    defer partition.deinit(allocator);
    try partition.run(diag);
    var graph = try Graph.init(allocator, polygon, partition.diagonals.items);
    defer graph.deinit(allocator);
    var triangles: std.ArrayList([3]u32) = .empty;
    errdefer triangles.deinit(allocator);
    try graph.triangulatePieces(allocator, &triangles, diag);
    // Every simple polygon of n points and h holes has n + 2h − 2 triangles (BKOS Thm 3.9)
    const expected = polygon.points.len + 2 * (polygon.rings() - 1) - 2;
    if (triangles.items.len != expected) return notSimple(diag, triangles.items.len, expected);
    try delaunay(allocator, polygon, triangles.items);
    return triangles.toOwnedSlice(allocator);
}

fn validate(polygon: Polygon, diag: *Diagnostics) Error!void {
    if (polygon.starts.len < 2 or polygon.starts[0] != 0 or polygon.starts[polygon.starts.len - 1] != polygon.points.len) {
        return diag.fail(error.InvalidInput, .{ .code = .ring_starts, .label = "the polygon's ring starts" });
    }
    if (polygon.points.len > MAX_POINTS) return diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "the polygon's points", .measured = @floatFromInt(polygon.points.len), .threshold = @floatFromInt(MAX_POINTS) });
    for (0..polygon.rings()) |r| {
        if (polygon.starts[r + 1] < polygon.starts[r] + 3) return diag.fail(error.InvalidInput, .{ .code = .ring_too_small, .label = "a ring of the polygon", .measured = @floatFromInt(polygon.starts[r + 1] -| polygon.starts[r]), .threshold = 3 });
        const ring = polygon.ring(r);
        for (ring, 0..) |p, i| {
            if (!vec.isFinite2(p)) return diag.fail(error.InvalidInput, .{ .code = .not_finite, .label = "a point of the polygon" });
            const q = ring[(i + 1) % ring.len];
            if (p[0] == q[0] and p[1] == q[1]) return diag.fail(error.InvalidInput, .{ .code = .not_simple, .label = "the polygon", .measured = @floatFromInt(polygon.starts[r] + i) });
        }
    }
}

fn notSimple(diag: *Diagnostics, measured: usize, threshold: usize) Error {
    return diag.fail(error.InvalidInput, .{ .code = .not_simple, .label = "the polygon", .measured = @floatFromInt(measured), .threshold = @floatFromInt(threshold) });
}

/// The sweep's order (BKOS p. 50): `a` is above `b` when higher, or as high and further
/// left; so no two distinct points are level, and a horizontal edge runs downward from its
/// left end.
fn above(a: Vec2, b: Vec2) bool {
    return a[1] > b[1] or (a[1] == b[1] and a[0] < b[0]);
}

fn edgeKey(a: u32, b: u32) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

/// The monotone partition: a sweep from the top down over the rings' vertices, the
/// edges whose interior is to their right kept in a status ordered left to right, each
/// with its helper, the vertex a diagonal from a split vertex goes to (BKOS §3.2). Edge
/// `i` runs from point `i` to the next point of its ring.
const Partition = struct {
    allocator: std.mem.Allocator,
    points: []const Vec2,
    next: []u32,
    prev: []u32,
    kind: []Kind,
    /// The points, top down.
    order: []u32,
    /// The edges the sweep line crosses, left to right, with the interior to their right.
    status: std.ArrayList(u32) = .empty,
    helper: []u32,
    diagonals: std.ArrayList([2]u32) = .empty,

    const Kind = enum(u8) { start, end, split, merge, regular };

    fn init(allocator: std.mem.Allocator, polygon: Polygon) Error!Partition {
        const n = polygon.points.len;
        const next = try allocator.alloc(u32, n);
        errdefer allocator.free(next);
        const prev = try allocator.alloc(u32, n);
        errdefer allocator.free(prev);
        for (0..polygon.rings()) |r| {
            const first = polygon.starts[r];
            const last = polygon.starts[r + 1] - 1;
            for (first..last + 1) |i| {
                next[i] = if (i == last) first else @intCast(i + 1);
                prev[i] = if (i == first) last else @intCast(i - 1);
            }
        }
        const kind = try allocator.alloc(Kind, n);
        errdefer allocator.free(kind);
        const order = try allocator.alloc(u32, n);
        errdefer allocator.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, polygon.points, lessAbove);
        const helper = try allocator.alloc(u32, n);
        errdefer allocator.free(helper);
        @memset(helper, NONE);
        var self: Partition = .{ .allocator = allocator, .points = polygon.points, .next = next, .prev = prev, .kind = kind, .order = order, .helper = helper };
        for (0..n) |i| self.kind[i] = self.classify(@intCast(i));
        return self;
    }

    fn deinit(self: *Partition, allocator: std.mem.Allocator) void {
        allocator.free(self.next);
        allocator.free(self.prev);
        allocator.free(self.kind);
        allocator.free(self.order);
        allocator.free(self.helper);
        self.status.deinit(allocator);
        self.diagonals.deinit(allocator);
        self.* = undefined;
    }

    fn lessAbove(points: []const Vec2, a: u32, b: u32) bool {
        if (above(points[a], points[b])) return true;
        if (above(points[b], points[a])) return false;
        return a < b;
    }

    /// A vertex by its neighbours (BKOS p. 50): a start or an end when both are below or
    /// above it and the corner is convex, a split or a merge when it is reflex, regular
    /// when the chain passes through.
    fn classify(self: *const Partition, v: u32) Kind {
        const u = self.points[self.prev[v]];
        const p = self.points[v];
        const w = self.points[self.next[v]];
        const convex = predicates.orient2d(u, p, w) > 0;
        if (above(p, u) and above(p, w)) return if (convex) .start else .split;
        if (above(u, p) and above(w, p)) return if (convex) .end else .merge;
        return .regular;
    }

    fn run(self: *Partition, diag: *Diagnostics) Error!void {
        for (self.order) |v| {
            const u = self.prev[v];
            switch (self.kind[v]) {
                .start => try self.insert(v),
                .end => {
                    try self.fixUp(u, v);
                    try self.remove(u, diag);
                },
                .split => {
                    const j = try self.leftOf(v, diag);
                    try self.diagonal(v, self.helper[j]);
                    self.helper[j] = v;
                    try self.insert(v);
                },
                .merge => {
                    try self.fixUp(u, v);
                    try self.remove(u, diag);
                    const j = try self.leftOf(v, diag);
                    try self.fixUp(j, v);
                    self.helper[j] = v;
                },
                .regular => {
                    // The interior is to the right of a vertex the chain passes downward
                    if (above(self.points[u], self.points[v])) {
                        try self.fixUp(u, v);
                        try self.remove(u, diag);
                        try self.insert(v);
                    } else {
                        const j = try self.leftOf(v, diag);
                        try self.fixUp(j, v);
                        self.helper[j] = v;
                    }
                },
            }
        }
    }

    /// A merge vertex left as an edge's helper gets its diagonal from the vertex that
    /// replaces it.
    fn fixUp(self: *Partition, e: u32, v: u32) Error!void {
        const h = self.helper[e];
        if (h != NONE and self.kind[h] == .merge) try self.diagonal(v, h);
    }

    fn diagonal(self: *Partition, a: u32, b: u32) Error!void {
        try self.diagonals.append(self.allocator, .{ a, b });
    }

    /// Whether `p` is strictly to the right of status edge `e`, which runs downward.
    fn rightOf(self: *const Partition, e: u32, p: Vec2) bool {
        return predicates.orient2d(self.points[e], self.points[self.next[e]], p) > 0;
    }

    /// The first status index whose edge `p` is not to the right of.
    fn position(self: *const Partition, p: Vec2) usize {
        var lo: usize = 0;
        var hi: usize = self.status.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.rightOf(self.status.items[mid], p)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Edge `e` leaves its upper vertex `e` downward: it joins the status at that vertex.
    fn insert(self: *Partition, e: u32) Error!void {
        self.helper[e] = e;
        try self.status.insert(self.allocator, self.position(self.points[e]), e);
    }

    /// Edge `e` ends at its lower vertex: it leaves the status there.
    fn remove(self: *Partition, e: u32, diag: *Diagnostics) Error!void {
        const at = self.position(self.points[self.next[e]]);
        if (at < self.status.items.len and self.status.items[at] == e) {
            _ = self.status.orderedRemove(at);
            return;
        }
        // Another edge through the vertex (rings that touch): find it the slow way
        for (self.status.items, 0..) |s, i| {
            if (s == e) {
                _ = self.status.orderedRemove(i);
                return;
            }
        }
        return notSimple(diag, e, 0);
    }

    /// The status edge directly left of vertex `v`.
    fn leftOf(self: *const Partition, v: u32, diag: *Diagnostics) Error!u32 {
        const at = self.position(self.points[v]);
        if (at == 0) return notSimple(diag, v, 0);
        return self.status.items[at - 1];
    }
};

/// The rings and the diagonals as a half-edge graph (the DCEL, BKOS §2.2) whose bounded
/// faces are the monotone pieces: half-edge `2k` and `2k + 1` are twins, the rings' first
/// (points `0..n`, forward, the piece on the left, then backward, outside), then the
/// diagonals'. The half-edges leaving each vertex are sorted by angle and linked: the
/// twin of each continues into the next one clockwise.
const Graph = struct {
    points: []const Vec2,
    origin: []u32,
    target: []u32,
    next: []u32,
    outside: []bool,

    fn init(allocator: std.mem.Allocator, polygon: Polygon, diagonals: []const [2]u32) Error!Graph {
        const n = polygon.points.len;
        const halves = 2 * (n + diagonals.len);
        const origin = try allocator.alloc(u32, halves);
        errdefer allocator.free(origin);
        const target = try allocator.alloc(u32, halves);
        errdefer allocator.free(target);
        const next = try allocator.alloc(u32, halves);
        errdefer allocator.free(next);
        const outside = try allocator.alloc(bool, halves);
        errdefer allocator.free(outside);
        @memset(outside, false);
        for (0..polygon.rings()) |r| {
            const first = polygon.starts[r];
            const last = polygon.starts[r + 1] - 1;
            for (first..last + 1) |i| {
                const j: u32 = if (i == last) first else @intCast(i + 1);
                origin[2 * i] = @intCast(i);
                target[2 * i] = j;
                origin[2 * i + 1] = j;
                target[2 * i + 1] = @intCast(i);
                outside[2 * i + 1] = true;
            }
        }
        for (diagonals, 0..) |d, k| {
            origin[2 * (n + k)] = d[0];
            target[2 * (n + k)] = d[1];
            origin[2 * (n + k) + 1] = d[1];
            target[2 * (n + k) + 1] = d[0];
        }
        var self: Graph = .{ .points = polygon.points, .origin = origin, .target = target, .next = next, .outside = outside };
        try self.link(allocator);
        return self;
    }

    fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        allocator.free(self.origin);
        allocator.free(self.target);
        allocator.free(self.next);
        allocator.free(self.outside);
        self.* = undefined;
    }

    /// The half-edges leaving each vertex, counter-clockwise from the positive x axis;
    /// then each half-edge arriving at a vertex (the twin of a leaving one) continues into
    /// the leaving half-edge next clockwise, so a cycle keeps its face on its left.
    fn link(self: *Graph, allocator: std.mem.Allocator) Error!void {
        const n = self.points.len;
        const start = try allocator.alloc(u32, n + 1);
        defer allocator.free(start);
        @memset(start, 0);
        for (self.origin) |o| start[o + 1] += 1;
        for (1..n + 1) |v| start[v] += start[v - 1];
        const out = try allocator.alloc(u32, self.origin.len);
        defer allocator.free(out);
        const fill = try allocator.alloc(u32, n);
        defer allocator.free(fill);
        @memset(fill, 0);
        for (self.origin, 0..) |o, h| {
            out[start[o] + fill[o]] = @intCast(h);
            fill[o] += 1;
        }
        for (0..n) |v| {
            const leaving = out[start[v]..start[v + 1]];
            std.mem.sort(u32, leaving, self, lessAround);
            for (leaving, 0..) |h, k| {
                const before = leaving[(k + leaving.len - 1) % leaving.len];
                self.next[h ^ 1] = before;
            }
        }
    }

    /// Whether half-edge `a` leaves its origin at a smaller angle than `b`, which leaves
    /// the same vertex: by half-plane first (the upper half-plane with the positive x axis
    /// before the lower with the negative), then by the exact turn.
    fn lessAround(self: *const Graph, a: u32, b: u32) bool {
        const o = self.points[self.origin[a]];
        const pa = self.points[self.target[a]];
        const pb = self.points[self.target[b]];
        const ua = upperHalf(vec.sub2(pa, o));
        const ub = upperHalf(vec.sub2(pb, o));
        if (ua != ub) return ua;
        const turn = predicates.orient2d(o, pa, pb);
        if (turn != 0) return turn > 0;
        return a < b;
    }

    fn upperHalf(d: Vec2) bool {
        return d[1] > 0 or (d[1] == 0 and d[0] > 0);
    }

    /// Each bounded face of the graph, a monotone piece, triangulated.
    fn triangulatePieces(self: *const Graph, allocator: std.mem.Allocator, triangles: *std.ArrayList([3]u32), diag: *Diagnostics) Error!void {
        const visited = try allocator.alloc(bool, self.origin.len);
        defer allocator.free(visited);
        @memset(visited, false);
        var ring: std.ArrayList(u32) = .empty;
        defer ring.deinit(allocator);
        var merged: std.ArrayList(Chained) = .empty;
        defer merged.deinit(allocator);
        var stack: std.ArrayList(Chained) = .empty;
        defer stack.deinit(allocator);
        for (0..self.origin.len) |h| {
            if (visited[h] or self.outside[h]) continue;
            ring.clearRetainingCapacity();
            var at: u32 = @intCast(h);
            while (!visited[at]) {
                visited[at] = true;
                try ring.append(allocator, self.origin[at]);
                at = self.next[at];
            }
            if (at != h) return notSimple(diag, h, 0);
            try self.triangulateMonotone(allocator, ring.items, &merged, &stack, triangles, diag);
        }
    }

    const Side = enum(u8) { left, right };
    const Chained = struct { point: u32, side: Side };

    /// A y-monotone piece by the stack walk (BKOS §3.3): its two chains merged top down,
    /// each vertex fanned to the stack of the reflex chain above it.
    fn triangulateMonotone(self: *const Graph, allocator: std.mem.Allocator, ring: []const u32, merged: *std.ArrayList(Chained), stack: *std.ArrayList(Chained), triangles: *std.ArrayList([3]u32), diag: *Diagnostics) Error!void {
        const m = ring.len;
        if (m < 3) return notSimple(diag, ring[0], 0);
        var top: usize = 0;
        var bottom: usize = 0;
        for (1..m) |i| {
            if (above(self.points[ring[i]], self.points[ring[top]])) top = i;
            if (above(self.points[ring[bottom]], self.points[ring[i]])) bottom = i;
        }
        // Counter-clockwise from the top, the ring runs down the left chain first
        merged.clearRetainingCapacity();
        try merged.append(allocator, .{ .point = ring[top], .side = .left });
        var l = (top + 1) % m;
        var r = (top + m - 1) % m;
        while (l != bottom or r != bottom) {
            const take_left = r == bottom or (l != bottom and above(self.points[ring[l]], self.points[ring[r]]));
            if (take_left) {
                try merged.append(allocator, .{ .point = ring[l], .side = .left });
                l = (l + 1) % m;
            } else {
                try merged.append(allocator, .{ .point = ring[r], .side = .right });
                r = (r + m - 1) % m;
            }
        }
        try merged.append(allocator, .{ .point = ring[bottom], .side = .left });

        const u = merged.items;
        stack.clearRetainingCapacity();
        try stack.append(allocator, u[0]);
        try stack.append(allocator, u[1]);
        for (2..m - 1) |j| {
            const v = u[j];
            if (v.side != stack.items[stack.items.len - 1].side) {
                while (stack.items.len > 1) {
                    const a = stack.pop().?;
                    const b = stack.items[stack.items.len - 1];
                    try self.emit(allocator, triangles, v.point, a.point, b.point, diag);
                }
                stack.clearRetainingCapacity();
                try stack.append(allocator, u[j - 1]);
                try stack.append(allocator, v);
            } else {
                var last = stack.pop().?;
                while (stack.items.len > 0 and self.insideChain(v, last.point, stack.items[stack.items.len - 1].point)) {
                    try self.emit(allocator, triangles, v.point, last.point, stack.items[stack.items.len - 1].point, diag);
                    last = stack.pop().?;
                }
                try stack.append(allocator, last);
                try stack.append(allocator, v);
            }
        }
        const last = u[m - 1];
        for (0..stack.items.len - 1) |k| try self.emit(allocator, triangles, last.point, stack.items[k].point, stack.items[k + 1].point, diag);
    }

    /// Whether the diagonal from `v` to `top`, two vertices of one chain with `last`
    /// between them, lies inside the piece: the three make a convex corner toward the
    /// interior, which is to the right of the left chain and to the left of the right.
    fn insideChain(self: *const Graph, v: Chained, last: u32, top: u32) bool {
        const turn = predicates.orient2d(self.points[top], self.points[last], self.points[v.point]);
        return if (v.side == .left) turn > 0 else turn < 0;
    }

    /// The triangle `a b c` counter-clockwise; one of no area is not a simple polygon's.
    fn emit(self: *const Graph, allocator: std.mem.Allocator, triangles: *std.ArrayList([3]u32), a: u32, b: u32, c: u32, diag: *Diagnostics) Error!void {
        const turn = predicates.orient2d(self.points[a], self.points[b], self.points[c]);
        if (turn == 0) return notSimple(diag, a, 0);
        try triangles.append(allocator, if (turn > 0) .{ a, b, c } else .{ a, c, b });
    }
};

/// Lawson's flips (BKOS §9.3): an edge of two triangles is illegal when the fourth point
/// lies strictly inside the circumcircle of the other three; flipping it strictly
/// increases the sorted angle vector, so the walk ends in the constrained Delaunay
/// triangulation. The polygon's own edges are never flipped.
fn delaunay(allocator: std.mem.Allocator, polygon: Polygon, triangles: [][3]u32) Error!void {
    const points = polygon.points;
    var constrained: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer constrained.deinit(allocator);
    try constrained.ensureTotalCapacity(allocator, @intCast(points.len));
    for (0..polygon.rings()) |r| {
        const first = polygon.starts[r];
        const last = polygon.starts[r + 1] - 1;
        for (first..last + 1) |i| constrained.putAssumeCapacity(edgeKey(@intCast(i), if (i == last) first else @intCast(i + 1)), {});
    }
    // The neighbour across each side, as a packed (triangle, side)
    const adjacent = try allocator.alloc([SIDES]u32, triangles.len);
    defer allocator.free(adjacent);
    @memset(adjacent, .{ NONE, NONE, NONE });
    var seen: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer seen.deinit(allocator);
    try seen.ensureTotalCapacity(allocator, @intCast(3 * triangles.len));
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(allocator);
    for (triangles, 0..) |t, ti| {
        for (0..SIDES) |i| {
            const key = edgeKey(t[i], t[(i + 1) % SIDES]);
            const here = pack(@intCast(ti), @intCast(i));
            if (seen.fetchRemove(key)) |other| {
                adjacent[ti][i] = other.value;
                adjacent[unpackTriangle(other.value)][unpackSide(other.value)] = here;
                if (!constrained.contains(key)) try pending.append(allocator, here);
            } else {
                seen.putAssumeCapacity(key, here);
            }
        }
    }
    while (pending.pop()) |here| {
        const t = unpackTriangle(here);
        const i = unpackSide(here);
        const across = adjacent[t][i];
        if (across == NONE) continue;
        const n = unpackTriangle(across);
        const j = unpackSide(across);
        const p = triangles[t][i];
        const q = triangles[t][(i + 1) % SIDES];
        const r = triangles[t][(i + 2) % SIDES];
        const d = triangles[n][(j + 2) % SIDES];
        if (constrained.contains(edgeKey(p, q))) continue;
        if (predicates.incircle(points[p], points[q], points[r], points[d]) <= 0) continue;
        // The quadrilateral p d q r is convex: the diagonal p q becomes d r
        const a = adjacent[t][(i + 1) % SIDES]; // across q r
        const b = adjacent[t][(i + 2) % SIDES]; // across r p
        const c = adjacent[n][(j + 1) % SIDES]; // across p d
        const e = adjacent[n][(j + 2) % SIDES]; // across d q
        triangles[t] = .{ p, d, r };
        triangles[n] = .{ d, q, r };
        adjacent[t] = .{ c, pack(n, 2), b };
        adjacent[n] = .{ e, a, pack(t, 1) };
        if (a != NONE) adjacent[unpackTriangle(a)][unpackSide(a)] = pack(n, 1);
        if (b != NONE) adjacent[unpackTriangle(b)][unpackSide(b)] = pack(t, 2);
        if (c != NONE) adjacent[unpackTriangle(c)][unpackSide(c)] = pack(t, 0);
        if (e != NONE) adjacent[unpackTriangle(e)][unpackSide(e)] = pack(n, 0);
        try pending.append(allocator, pack(t, 0));
        try pending.append(allocator, pack(t, 2));
        try pending.append(allocator, pack(n, 0));
        try pending.append(allocator, pack(n, 1));
    }
}

fn pack(triangle: u32, side: u32) u32 {
    return triangle * SIDES + side;
}

fn unpackTriangle(packed_side: u32) u32 {
    return packed_side / SIDES;
}

fn unpackSide(packed_side: u32) u32 {
    return packed_side % SIDES;
}
