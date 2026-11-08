//! A constrained Delaunay triangulation of a polygon with holes (docs/architecture.md
//! §7.7, D13; KNOWLEDGE §8): the polygon is cut into y-monotone pieces by a plane sweep
//! with helpers (BKOS §3.2, holes native), each piece is triangulated by the two-chain
//! stack walk (BKOS §3.3), and Lawson flips (BKOS Lemma 9.4) turn the result into the
//! constrained Delaunay triangulation, the polygon's own edges never flipped. Every turn
//! and every circle test is an exact predicate and every tie is broken by the
//! lexicographic order (y, then x), so the output is deterministic for any input in any
//! position, collinear and level vertices included. The polygon may be weakly simple: a
//! ring may pass through a point twice and rings may touch at points (a face pinched at
//! a vertex, a hole touching the outer loop, what the overlay's boundary walk makes), as
//! long as no edges cross. Before the sweep, the rings are rewoven at every such point
//! by the tightest turn (the edge arriving at the point continues into the first edge
//! leaving it clockwise), so each passage through a point is a wedge of the region there
//! and the sweep meets no crossing; the triangles are then counted against Euler's
//! formula and their area against the polygon's. Indices are the caller's point indices;
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
/// How far the triangles' area may differ from the polygon's, relative to it: rounding
/// in the sums of many small triangles.
const AREA_SLACK: f64 = 1e-9;

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
/// `allocator`. The rings must not cross; a polygon whose rings do, a ring of fewer than
/// three points, or one that repeats a point in a row is `error.InvalidInput` with a
/// finding that says which.
pub fn triangulate(allocator: std.mem.Allocator, polygon: Polygon, diag: *Diagnostics) Error![][3]u32 {
    try validate(polygon, diag);
    var woven = try reweave(allocator, polygon, diag);
    defer woven.deinit(allocator);
    const rings: Polygon = .{ .points = woven.points, .starts = woven.starts };
    var partition = try Partition.init(allocator, rings);
    defer partition.deinit(allocator);
    try partition.run(diag);
    try attachDiagonals(allocator, rings, partition.diagonals.items);
    var graph = try Graph.init(allocator, rings, partition.diagonals.items, false);
    defer graph.deinit(allocator);
    var triangles: std.ArrayList([3]u32) = .empty;
    errdefer triangles.deinit(allocator);
    const skipped = try graph.triangulatePieces(allocator, &triangles, diag);
    // A simple polygon of n points and h holes has n + 2h − 2 triangles (BKOS Thm 3.9);
    // one that passes a point twice fewer or more by two a time, so its check is the
    // area's, which every polygon gets: rings that cross leave it uncovered or covered
    // twice
    if (woven.simple) {
        const expected = polygon.points.len + 2 * (polygon.rings() - 1) - 2;
        if (triangles.items.len + skipped != expected) return notSimple(diag, triangles.items.len + skipped, expected);
    }
    const covered = trianglesArea(rings.points, triangles.items);
    const area = polygonArea(polygon);
    if (@abs(covered - area) > AREA_SLACK * @max(area, 1)) return notSimple(diag, @intFromFloat(@round(covered * 1e6)), @intFromFloat(@round(area * 1e6)));
    try delaunay(allocator, rings, triangles.items);
    for (triangles.items) |*t| for (t) |*corner| {
        corner.* = woven.source[corner.*];
    };
    return triangles.toOwnedSlice(allocator);
}

/// Each diagonal's ends moved to the passage through their point whose wedge of the
/// region faces the diagonal. The sweep tells two passages through one point apart only
/// by their order, so a diagonal may reach the passage whose wedge lies on the other
/// side; the graph needs the one the diagonal runs into, or its cycles cross over.
fn attachDiagonals(allocator: std.mem.Allocator, rings: Polygon, diagonals: [][2]u32) Error!void {
    const n = rings.points.len;
    // The next passage through the same point, a chain per point; NONE at the end
    const next_same = try allocator.alloc(u32, n);
    defer allocator.free(next_same);
    @memset(next_same, NONE);
    const next = try allocator.alloc(u32, n);
    defer allocator.free(next);
    const prev = try allocator.alloc(u32, n);
    defer allocator.free(prev);
    var first_at: std.AutoHashMapUnmanaged([2]u64, u32) = .empty;
    defer first_at.deinit(allocator);
    try first_at.ensureTotalCapacity(allocator, @intCast(n));
    var any_shared = false;
    for (0..rings.rings()) |r| {
        const first = rings.starts[r];
        const last = rings.starts[r + 1] - 1;
        for (first..last + 1) |i| {
            next[i] = if (i == last) first else @intCast(i + 1);
            prev[i] = if (i == first) last else @intCast(i - 1);
            const p = rings.points[i];
            const key: [2]u64 = .{ @bitCast(p[0] + 0.0), @bitCast(p[1] + 0.0) };
            const entry = first_at.getOrPutAssumeCapacity(key);
            if (entry.found_existing) {
                next_same[i] = next_same[entry.value_ptr.*];
                next_same[entry.value_ptr.*] = @intCast(i);
                any_shared = true;
            } else entry.value_ptr.* = @intCast(i);
        }
    }
    if (!any_shared) return;
    for (diagonals) |*d| {
        for (0..2) |end| {
            const v = d[end];
            const other = rings.points[d[1 - end]];
            const p = rings.points[v];
            const key: [2]u64 = .{ @bitCast(p[0] + 0.0), @bitCast(p[1] + 0.0) };
            var candidate = first_at.get(key).?;
            while (candidate != NONE) : (candidate = next_same[candidate]) {
                if (wedgeHolds(rings.points, prev[candidate], candidate, next[candidate], other)) {
                    d[end] = candidate;
                    break;
                }
            }
        }
    }
}

/// Whether the direction from `v` to `target` lies in the region's wedge at `v`, which
/// opens from the edge to `w` counter-clockwise round to the edge from `u`.
fn wedgeHolds(points: []const Vec2, u: u32, v: u32, w: u32, target: Vec2) bool {
    const o = vec.sub2(points[w], points[v]);
    const i = vec.sub2(points[u], points[v]);
    const d = vec.sub2(target, points[v]);
    const span = vec.cross2(o, i);
    if (span > 0) return vec.cross2(o, d) > 0 and vec.cross2(d, i) > 0;
    if (span < 0) return !(vec.cross2(i, d) > 0 and vec.cross2(d, o) > 0);
    // A straight passage: the region is on its left
    return vec.cross2(o, d) > 0;
}

/// The rings rewoven at the points they pass more than once: the points in the order
/// the new rings visit them, each with the index of the caller's point it is.
const Woven = struct {
    points: []Vec2,
    starts: []u32,
    source: []u32,
    /// Whether no two points were at one place: the rings are the caller's.
    simple: bool,

    fn deinit(self: *Woven, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.starts);
        allocator.free(self.source);
        self.* = undefined;
    }
};

/// The rings rewoven by the tightest turn at every point the polygon passes more than
/// once: the graph of the rings' edges with coincident points one vertex, each arriving
/// edge continued into the first leaving one clockwise, which pairs the edges at the
/// point into the wedges of the region there (a pinched face into its lobes, a hole
/// touching the outer loop into one ring through the point twice). A simple polygon
/// comes back as it is.
fn reweave(allocator: std.mem.Allocator, polygon: Polygon, diag: *Diagnostics) Error!Woven {
    var graph = try Graph.init(allocator, polygon, &.{}, true);
    defer graph.deinit(allocator);
    const n = polygon.points.len;
    const points = try allocator.alloc(Vec2, n);
    errdefer allocator.free(points);
    const source = try allocator.alloc(u32, n);
    errdefer allocator.free(source);
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(allocator);
    const visited = try allocator.alloc(bool, graph.origin.len);
    defer allocator.free(visited);
    @memset(visited, false);
    var filled: usize = 0;
    for (0..graph.origin.len) |h| {
        if (visited[h] or graph.outside[h]) continue;
        try starts.append(allocator, @intCast(filled));
        var at: u32 = @intCast(h);
        while (!visited[at]) {
            visited[at] = true;
            if (filled == n) return notSimple(diag, h, 0);
            const o = graph.origin[at];
            points[filled] = polygon.points[o];
            source[filled] = o;
            filled += 1;
            at = graph.next[at];
        }
        if (at != h) return notSimple(diag, h, 0);
        if (filled - starts.items[starts.items.len - 1] < 3) return notSimple(diag, h, 0);
    }
    if (filled != n) return notSimple(diag, filled, n);
    try starts.append(allocator, @intCast(filled));
    return .{ .points = points, .starts = try starts.toOwnedSlice(allocator), .source = source, .simple = graph.welded == n };
}

/// The signed area of the rings: positive for the region on their left.
fn polygonArea(polygon: Polygon) f64 {
    var twice: f64 = 0;
    for (0..polygon.rings()) |r| {
        const ring = polygon.ring(r);
        for (ring, 0..) |p, i| {
            const q = ring[(i + 1) % ring.len];
            twice += p[0] * q[1] - q[0] * p[1];
        }
    }
    return twice / 2;
}

fn trianglesArea(points: []const Vec2, triangles: []const [3]u32) f64 {
    var twice: f64 = 0;
    for (triangles) |t| twice += predicates.orient2d(points[t[0]], points[t[1]], points[t[2]]);
    return twice / 2;
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
/// left end. Two points at one place are ordered by `lessAbove`.
fn above(a: Vec2, b: Vec2) bool {
    return a[1] > b[1] or (a[1] == b[1] and a[0] < b[0]);
}

/// The sweep's order of two points by index: the perturbation moves point `i` a hair to
/// the right and down per index, so of two points at one place the earlier is above.
fn lessAbove(points: []const Vec2, a: u32, b: u32) bool {
    if (above(points[a], points[b])) return true;
    if (above(points[b], points[a])) return false;
    return a < b;
}

fn samePlace(p: Vec2, q: Vec2) bool {
    return p[0] == q[0] and p[1] == q[1];
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

    /// A vertex by its neighbours (BKOS p. 50): a start or an end when both are below or
    /// above it and the corner is convex, a split or a merge when it is reflex, regular
    /// when the chain passes through.
    fn classify(self: *const Partition, v: u32) Kind {
        const u = self.prev[v];
        const w = self.next[v];
        const convex = predicates.orient2d(self.points[u], self.points[v], self.points[w]) > 0;
        if (lessAbove(self.points, v, u) and lessAbove(self.points, v, w)) return if (convex) .start else .split;
        if (lessAbove(self.points, u, v) and lessAbove(self.points, w, v)) return if (convex) .end else .merge;
        return .regular;
    }

    /// The sweep. The vertices at one point (the passages of a weakly simple polygon
    /// through it) are one event: every edge ending there leaves the status before any
    /// edge starting there joins it, so a vertex meets no edge it is the lower end of, and
    /// the edges starting at a point are ordered by their directions.
    fn run(self: *Partition, diag: *Diagnostics) Error!void {
        var i: usize = 0;
        while (i < self.order.len) {
            var j = i + 1;
            while (j < self.order.len and samePlace(self.points[self.order[j]], self.points[self.order[i]])) j += 1;
            const group = self.order[i..j];
            for (group) |v| {
                const u = self.prev[v];
                switch (self.kind[v]) {
                    .end, .merge => {
                        try self.fixUp(u, v);
                        try self.remove(u, diag);
                    },
                    .regular => if (lessAbove(self.points, u, v)) {
                        try self.fixUp(u, v);
                        try self.remove(u, diag);
                    },
                    .start, .split => {},
                }
            }
            for (group) |v| {
                const u = self.prev[v];
                const w = self.next[v];
                switch (self.kind[v]) {
                    .start => try self.insert(v),
                    .end => {},
                    .split => {
                        // The wedge opens downward between the two edges; the one further
                        // west stands for the vertex
                        const to_u = vec.sub2(self.points[u], self.points[v]);
                        const to_w = vec.sub2(self.points[w], self.points[v]);
                        const west = if (vec.cross2(to_u, to_w) > 0) to_u else to_w;
                        const j_edge = try self.leftOf(v, west, diag);
                        try self.diagonal(v, self.helper[j_edge]);
                        self.helper[j_edge] = v;
                        try self.insert(v);
                    },
                    .merge => {
                        const j_edge = try self.leftOf(v, .{ 0, -1 }, diag);
                        try self.fixUp(j_edge, v);
                        self.helper[j_edge] = v;
                    },
                    .regular => if (lessAbove(self.points, u, v)) {
                        try self.insert(v);
                    } else {
                        // The chain passes upward: the edge from the vertex down to `u`
                        // stands for it
                        const j_edge = try self.leftOf(v, vec.sub2(self.points[u], self.points[v]), diag);
                        try self.fixUp(j_edge, v);
                        self.helper[j_edge] = v;
                    },
                }
            }
            i = j;
        }
    }

    /// A merge vertex left as an edge's helper gets its diagonal from the vertex that
    /// replaces it.
    fn fixUp(self: *Partition, e: u32, v: u32) Error!void {
        const h = self.helper[e];
        if (h != NONE and self.kind[h] == .merge) try self.diagonal(v, h);
    }

    /// A diagonal; one between two passages through one point is no diagonal, the
    /// passages being wedges of the region that meet there already.
    fn diagonal(self: *Partition, a: u32, b: u32) Error!void {
        if (samePlace(self.points[a], self.points[b])) return;
        try self.diagonals.append(self.allocator, .{ a, b });
    }

    /// Whether vertex `v` is east of status edge `e`, which runs downward from vertex
    /// `e`. A vertex at the edge's upper end (another passage of the polygon through the
    /// point, or the vertex's own edge about to join) is east of it when the direction
    /// standing for the vertex, `down`, turns counter-clockwise from the edge's: of two
    /// edges running down from one point the counter-clockwise one lies east.
    fn rightOf(self: *const Partition, e: u32, v: u32, down: Vec2) bool {
        const upper = self.points[e];
        const lower = self.points[self.next[e]];
        const turn = predicates.orient2d(upper, lower, self.points[v]);
        if (turn != 0) return turn > 0;
        return vec.cross2(vec.sub2(lower, upper), down) > 0;
    }

    /// The first status index whose edge vertex `v` is not east of.
    fn position(self: *const Partition, v: u32, down: Vec2) usize {
        var lo: usize = 0;
        var hi: usize = self.status.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.rightOf(self.status.items[mid], v, down)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Edge `e` leaves its upper vertex `e` downward: it joins the status at that vertex.
    fn insert(self: *Partition, e: u32) Error!void {
        self.helper[e] = e;
        try self.status.insert(self.allocator, self.position(e, vec.sub2(self.points[self.next[e]], self.points[e])), e);
    }

    /// Edge `e` ends at its lower vertex: it leaves the status there.
    fn remove(self: *Partition, e: u32, diag: *Diagnostics) Error!void {
        const at = self.position(self.next[e], .{ 0, -1 });
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

    /// The status edge directly west of vertex `v`, `down` the direction standing for the
    /// vertex among edges starting at its point.
    fn leftOf(self: *const Partition, v: u32, down: Vec2, diag: *Diagnostics) Error!u32 {
        const at = self.position(v, down);
        if (at == 0) return notSimple(diag, v, 0);
        return self.status.items[at - 1];
    }
};

/// The rings and the diagonals as a half-edge graph (the DCEL, BKOS §2.2) whose bounded
/// faces are the monotone pieces: half-edge `2k` and `2k + 1` are twins, the rings' first
/// (points `0..n`, forward, the piece on the left, then backward, outside), then the
/// diagonals'. The half-edges leaving each vertex are sorted by angle and linked: the
/// twin of each continues into the next one clockwise. With `weld`, points at one place
/// are one vertex (`reweave`); without, each point is its own, as the rewoven rings
/// need.
const Graph = struct {
    points: []const Vec2,
    origin: []u32,
    target: []u32,
    next: []u32,
    outside: []bool,
    /// Each point's vertex: its own index, or that of the first point at the same place.
    vertex_of: []u32,
    /// How many vertices the points make: the point count when no two are at one place.
    welded: usize,

    fn init(allocator: std.mem.Allocator, polygon: Polygon, diagonals: []const [2]u32, weld: bool) Error!Graph {
        const n = polygon.points.len;
        const vertex_of = try allocator.alloc(u32, n);
        errdefer allocator.free(vertex_of);
        for (vertex_of, 0..) |*v, i| v.* = @intCast(i);
        var welded: usize = n;
        if (weld) {
            welded = 0;
            var first_at: std.AutoHashMapUnmanaged([2]u64, u32) = .empty;
            defer first_at.deinit(allocator);
            try first_at.ensureTotalCapacity(allocator, @intCast(n));
            for (polygon.points, 0..) |p, i| {
                const key: [2]u64 = .{ @bitCast(p[0] + 0.0), @bitCast(p[1] + 0.0) }; // −0 as 0
                const entry = first_at.getOrPutAssumeCapacity(key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = @intCast(i);
                    welded += 1;
                }
                vertex_of[i] = entry.value_ptr.*;
            }
        }
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
        var self: Graph = .{ .points = polygon.points, .origin = origin, .target = target, .next = next, .outside = outside, .vertex_of = vertex_of, .welded = welded };
        try self.link(allocator);
        return self;
    }

    fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        allocator.free(self.vertex_of);
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
        for (self.origin) |o| start[self.vertex_of[o] + 1] += 1;
        for (1..n + 1) |v| start[v] += start[v - 1];
        const out = try allocator.alloc(u32, self.origin.len);
        defer allocator.free(out);
        const fill = try allocator.alloc(u32, n);
        defer allocator.free(fill);
        @memset(fill, 0);
        for (self.origin, 0..) |o, h| {
            const v = self.vertex_of[o];
            out[start[v] + fill[v]] = @intCast(h);
            fill[v] += 1;
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

    /// Each bounded face of the graph, a monotone piece, triangulated; the number of
    /// triangles of no area left out.
    fn triangulatePieces(self: *const Graph, allocator: std.mem.Allocator, triangles: *std.ArrayList([3]u32), diag: *Diagnostics) Error!usize {
        const visited = try allocator.alloc(bool, self.origin.len);
        defer allocator.free(visited);
        @memset(visited, false);
        var ring: std.ArrayList(u32) = .empty;
        defer ring.deinit(allocator);
        var merged: std.ArrayList(Chained) = .empty;
        defer merged.deinit(allocator);
        var stack: std.ArrayList(Chained) = .empty;
        defer stack.deinit(allocator);
        var skipped: usize = 0;
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
            skipped += try self.triangulateMonotone(allocator, ring.items, &merged, &stack, triangles, diag);
        }
        return skipped;
    }

    const Side = enum(u8) { left, right };
    const Chained = struct { point: u32, side: Side };

    /// A y-monotone piece by the stack walk (BKOS §3.3): its two chains merged top down,
    /// each vertex fanned to the stack of the reflex chain above it. Returns how many
    /// triangles of no area were left out.
    fn triangulateMonotone(self: *const Graph, allocator: std.mem.Allocator, ring: []const u32, merged: *std.ArrayList(Chained), stack: *std.ArrayList(Chained), triangles: *std.ArrayList([3]u32), diag: *Diagnostics) Error!usize {
        const m = ring.len;
        if (m < 3) return notSimple(diag, ring[0], 0);
        var top: usize = 0;
        var bottom: usize = 0;
        for (1..m) |i| {
            if (lessAbove(self.points, ring[i], ring[top])) top = i;
            if (lessAbove(self.points, ring[bottom], ring[i])) bottom = i;
        }
        // Counter-clockwise from the top, the ring runs down the left chain first
        merged.clearRetainingCapacity();
        try merged.append(allocator, .{ .point = ring[top], .side = .left });
        var l = (top + 1) % m;
        var r = (top + m - 1) % m;
        while (l != bottom or r != bottom) {
            const take_left = r == bottom or (l != bottom and lessAbove(self.points, ring[l], ring[r]));
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
        var skipped: usize = 0;
        stack.clearRetainingCapacity();
        try stack.append(allocator, u[0]);
        try stack.append(allocator, u[1]);
        for (2..m - 1) |j| {
            const v = u[j];
            if (v.side != stack.items[stack.items.len - 1].side) {
                while (stack.items.len > 1) {
                    const a = stack.pop().?;
                    const b = stack.items[stack.items.len - 1];
                    skipped += try self.emit(allocator, triangles, v.point, a.point, b.point);
                }
                stack.clearRetainingCapacity();
                try stack.append(allocator, u[j - 1]);
                try stack.append(allocator, v);
            } else {
                var last = stack.pop().?;
                while (stack.items.len > 0 and self.insideChain(v, last.point, stack.items[stack.items.len - 1].point)) {
                    skipped += try self.emit(allocator, triangles, v.point, last.point, stack.items[stack.items.len - 1].point);
                    last = stack.pop().?;
                }
                try stack.append(allocator, last);
                try stack.append(allocator, v);
            }
        }
        const last = u[m - 1];
        for (0..stack.items.len - 1) |k| skipped += try self.emit(allocator, triangles, last.point, stack.items[k].point, stack.items[k + 1].point);
        return skipped;
    }

    /// Whether the diagonal from `v` to `top`, two vertices of one chain with `last`
    /// between them, lies inside the piece: the three make a convex corner toward the
    /// interior, which is to the right of the left chain and to the left of the right.
    fn insideChain(self: *const Graph, v: Chained, last: u32, top: u32) bool {
        const turn = predicates.orient2d(self.points[top], self.points[last], self.points[v.point]);
        return if (v.side == .left) turn > 0 else turn < 0;
    }

    /// The triangle `a b c` counter-clockwise; one of no area (the perturbation's hairs)
    /// is left out and counted.
    fn emit(self: *const Graph, allocator: std.mem.Allocator, triangles: *std.ArrayList([3]u32), a: u32, b: u32, c: u32) Error!usize {
        const turn = predicates.orient2d(self.points[a], self.points[b], self.points[c]);
        if (turn == 0) return 1;
        try triangles.append(allocator, if (turn > 0) .{ a, b, c } else .{ a, c, b });
        return 0;
    }
};

/// Lawson's flips (BKOS §9.3): an edge of two triangles is illegal when the fourth point
/// lies strictly inside the circumcircle of the other three; flipping it strictly
/// increases the sorted angle vector, so the walk ends in the constrained Delaunay
/// triangulation. The polygon's own edges are never flipped. Two passages through one
/// point are two vertices here too, so an edge between them and a triangle's edge to
/// one of them never pair up: the edge stays, as a constraint would.
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
