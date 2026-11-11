//! Edge discretization (docs/architecture.md §7.7): every edge of a body is cut into a
//! polyline once, so the faces on both sides share the same points and a mesh built on
//! them is watertight by construction. A line is its two vertices. A circle's edge takes
//! the points of the grid a full circle of its radius gets at the `Resolution`,
//! `segmentsFor(r)` equal steps from angle 0, that lie strictly inside the edge's range,
//! between its vertices: the very polygon KupCAD's mesh engine builds for the same circle
//! (kernel parity), and two arcs of one circle meet on the grid. A degenerate edge is one
//! point. Two arcs tangent at a vertex and curving the same way bound a cusp, and there
//! the flatter arc takes the tighter one's points' tangent coordinates too (`matchCusps`),
//! so the two polylines cannot cross. A free-form edge (an ellipse, a NURBS curve) is cut
//! where its certified chords say (`chords.zig`): each span's enclosure within the bow the
//! resolution allows a circle's segment of that chord.

const std = @import("std");
const vec = @import("../math/vec.zig");
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const chords = @import("chords.zig");
const types = @import("../topology/types.zig");
const curves = @import("../geometry/curves.zig");
const body_mod = @import("../topology/body.zig");
const Vec3 = vec.Vec3;
const Body = body_mod.Body;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;
const Tolerance = tolerance.Tolerance;

/// How near a grid angle may come to an edge's end, as a share of the step, and still
/// count as a point of its own rather than the vertex.
const END_SLACK: f64 = 1e-9;
const TWO_PI: f64 = 2 * std.math.pi;
/// How often a circle's grid may be doubled: 2^8 times the resolution's count at most.
pub const MAX_DOUBLINGS: u8 = 8;

/// The polylines of a body's edges: edge `e` runs through `points[starts[e]..starts[e + 1]]`
/// from its `t0` end to its `t1` end, the vertices' own points at the ends, each point's
/// parameter on the edge's curve in `params` (the ends' `t0` and `t1`); a tombstoned edge
/// has no points, a degenerate one its one point.
pub const EdgePoints = struct {
    points: []Vec3,
    params: []f64,
    starts: []u32,

    pub fn deinit(self: *EdgePoints, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.params);
        allocator.free(self.starts);
        self.* = undefined;
    }

    pub fn paramsOf(self: EdgePoints, e: types.EdgeIndex) []const f64 {
        const i = @backingInt(e);
        return self.params[self.starts[i]..self.starts[i + 1]];
    }

    pub fn of(self: EdgePoints, e: types.EdgeIndex) []const Vec3 {
        const i = @backingInt(e);
        return self.points[self.starts[i]..self.starts[i + 1]];
    }
};

/// The edges of `body` as polylines at `resolution`; owned by `allocator`.
pub fn discretize(allocator: std.mem.Allocator, body: *const Body, resolution: tolerance.Resolution, diag: *Diagnostics) Error!EdgePoints {
    return discretizeRefined(allocator, body, resolution, null, Cap.none, null, diag);
}

/// The most interior points an edge, and all edges together, may have in a provisional
/// mesh (`tessellate.Budget`); `none` for the resolution's own counts.
pub const Cap = struct {
    per_edge: u32 = std.math.maxInt(u32),
    total: u32 = std.math.maxInt(u32),

    pub const none: Cap = .{};
};

/// As `discretize`, each edge's circle grid doubled `doublings[e]` times: the finer grid
/// keeps the coarser one's points, so an edge refined where its chords would cross a
/// neighbour still meets the edges around it where it did. Under `cap`, an edge with
/// more interior points than its share is resampled evenly at that many (the edges'
/// shares of the total in proportion to their counts), and `capped`, when given, is set
/// whenever that happened: such a polyline is a bounded picture, not the resolution's.
pub fn discretizeRefined(allocator: std.mem.Allocator, body: *const Body, resolution: tolerance.Resolution, doublings: ?[]const u8, cap: Cap, capped: ?*bool, diag: *Diagnostics) Error!EdgePoints {
    const n_edges = body.edges.items.len;
    // Each edge's points strictly between its ends, with their parameters
    const interior = try allocator.alloc(std.ArrayList(Interior), n_edges);
    defer {
        for (interior) |*list| list.deinit(allocator);
        allocator.free(interior);
    }
    @memset(interior, .empty);
    for (body.edges.items, 0..) |e, i| {
        if (e.flags.tombstone or e.flags.degenerate) continue;
        switch (body.geometry.curve(e.curve)) {
            .line => {},
            .circle => |circle| {
                const shift: u5 = if (doublings) |d| @intCast(@min(d[i], MAX_DOUBLINGS)) else 0;
                const n = @as(u64, resolution.segmentsFor(circle.r)) << shift;
                const step = TWO_PI / @as(f64, @floatFromInt(n));
                // The grid angles strictly between the ends; a few more steps than the
                // range holds are tried, since a range may start anywhere on the circle
                const first: i64 = @intFromFloat(@floor(e.t0 / step));
                const last: i64 = @intFromFloat(@ceil(e.t1 / step));
                var k = first;
                while (k <= last) : (k += 1) {
                    const angle = @as(f64, @floatFromInt(k)) * step;
                    if (angle <= e.t0 + END_SLACK * step or angle >= e.t1 - END_SLACK * step) continue;
                    try interior[i].append(allocator, .{ .t = angle, .p = circle.eval(angle) });
                }
            },
            // A free-form edge: the parameters its certified chords are cut at
            .ellipse, .nurbs => {
                var params: std.ArrayList(f64) = .empty;
                defer params.deinit(allocator);
                const curve = body.geometry.curve(e.curve);
                try chords.sampleParams(allocator, curve, e.t0, e.t1, resolution, &params, diag, .of(.edge, i));
                for (params.items) |t| try interior[i].append(allocator, .{ .t = t, .p = curve.eval(t) });
            },
        }
    }
    try applyCap(allocator, body, interior, cap, capped);
    try matchCusps(allocator, body, interior);
    var points: std.ArrayList(Vec3) = .empty;
    errdefer points.deinit(allocator);
    var params: std.ArrayList(f64) = .empty;
    errdefer params.deinit(allocator);
    const starts = try allocator.alloc(u32, n_edges + 1);
    errdefer allocator.free(starts);
    for (body.edges.items, 0..) |e, i| {
        starts[i] = @intCast(points.items.len);
        if (e.flags.tombstone) continue;
        if (e.flags.degenerate) {
            try points.append(allocator, body.point(e.start));
            try params.append(allocator, e.t0);
            continue;
        }
        try points.append(allocator, body.point(e.start));
        try params.append(allocator, e.t0);
        std.mem.sort(Interior, interior[i].items, {}, Interior.lessThan);
        for (interior[i].items) |between| {
            try points.append(allocator, between.p);
            try params.append(allocator, between.t);
        }
        try points.append(allocator, body.point(e.end));
        try params.append(allocator, e.t1);
    }
    starts[n_edges] = @intCast(points.items.len);
    const owned_points = try points.toOwnedSlice(allocator);
    errdefer allocator.free(owned_points);
    return .{ .points = owned_points, .params = try params.toOwnedSlice(allocator), .starts = starts };
}

/// Resamples evenly every edge whose interior points exceed its share of `cap`.
fn applyCap(allocator: std.mem.Allocator, body: *const Body, interior: []std.ArrayList(Interior), cap: Cap, capped: ?*bool) Error!void {
    var total: usize = 0;
    for (interior) |list| total += list.items.len;
    const share: f64 = if (total > cap.total) @as(f64, @floatFromInt(cap.total)) / @as(f64, @floatFromInt(total)) else 1;
    for (interior, body.edges.items) |*list, e| {
        var allowed: usize = cap.per_edge;
        if (share < 1) allowed = @min(allowed, @max(1, @as(usize, @intFromFloat(@floor(@as(f64, @floatFromInt(list.items.len)) * share)))));
        if (list.items.len <= allowed) continue;
        if (capped) |flag| flag.* = true;
        const curve = body.geometry.curve(e.curve);
        list.clearRetainingCapacity();
        for (1..allowed + 1) |k| {
            const t = e.t0 + (e.t1 - e.t0) * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(allowed + 1));
            try list.append(allocator, .{ .t = t, .p = curve.eval(t) });
        }
    }
}

/// A point of an edge's polyline between its ends, at the curve's parameter `t`.
const Interior = struct {
    t: f64,
    p: Vec3,

    fn lessThan(_: void, a: Interior, b: Interior) bool {
        return a.t < b.t;
    }
};

/// An end of a circle edge at a vertex, for grouping the edges about each vertex.
const End = struct {
    vertex: u32,
    edge: u32,
    at_start: bool,

    fn lessThan(_: void, a: End, b: End) bool {
        return a.vertex < b.vertex;
    }
};

/// Two arcs tangent at a vertex, curving the same way, bound a cusp: a lens that narrows
/// to nothing at the vertex. Chords of the two cross there however fine their grids: the
/// flatter arc's first chord dips under the tighter arc (a chord lies inside its disc,
/// and near the vertex the chord falls away faster than the tighter arc does), and
/// refining both keeps the picture similar. So the flatter arc takes a point at every
/// tangent coordinate (along the common tangent from the vertex) the tighter arc's
/// points have, as far as the tighter arc turns less than a quarter and the flatter one
/// reaches: both polylines then interpolate their arcs' depths below the tangent at the
/// same places, the tighter always the deeper, and interpolation keeps that order (the
/// flatter polyline's own points between them lie on its arc, shallower still). Two
/// pieces of one circle, an S-joint (curving apart), a line against an arc (a line is its
/// own chord, which no chord of the arc can cross), and circles in different planes are
/// not cusps.
fn matchCusps(allocator: std.mem.Allocator, body: *const Body, interior: []std.ArrayList(Interior)) Error!void {
    const tol = body.tol;
    var ends: std.ArrayList(End) = .empty;
    defer ends.deinit(allocator);
    for (body.edges.items, 0..) |e, i| {
        if (e.flags.tombstone or e.flags.degenerate) continue;
        if (body.geometry.curve(e.curve) != .circle) continue;
        try ends.append(allocator, .{ .vertex = @backingInt(e.start), .edge = @intCast(i), .at_start = true });
        try ends.append(allocator, .{ .vertex = @backingInt(e.end), .edge = @intCast(i), .at_start = false });
    }
    std.mem.sort(End, ends.items, {}, End.lessThan);
    var group_start: usize = 0;
    while (group_start < ends.items.len) {
        var group_end = group_start;
        while (group_end < ends.items.len and ends.items[group_end].vertex == ends.items[group_start].vertex) group_end += 1;
        const group = ends.items[group_start..group_end];
        for (group, 0..) |first, k| {
            for (group[k + 1 ..]) |second| {
                if (first.edge == second.edge) continue;
                try matchCusp(allocator, body, interior, first, second, tol);
            }
        }
        group_start = group_end;
    }
}

/// A circle edge as it leaves one of its ends: the unit tangent there pointing along the
/// edge away from that end's vertex, the unit direction from the vertex to the centre,
/// and how far along the tangent the edge's other end lies.
const Leaving = struct { along: Vec3, inward: Vec3, circle: curves.Circle, reach: f64 };

fn leaving(body: *const Body, end: End) Leaving {
    const e = body.edge(types.EdgeIndex.of(end.edge));
    const circle = body.geometry.curve(e.curve).circle;
    const t = if (end.at_start) e.t0 else e.t1;
    // d/dt of `c + r(cos t x + sin t y)`, the circle's own way round
    var along = vec.add(vec.scale(circle.x, -@sin(t)), vec.scale(circle.y, @cos(t)));
    if (!end.at_start) along = vec.scale(along, -1);
    const v = body.point(if (end.at_start) e.start else e.end);
    const far = body.point(if (end.at_start) e.end else e.start);
    return .{ .along = along, .inward = vec.scale(vec.sub(circle.c, v), 1.0 / circle.r), .circle = circle, .reach = vec.dot(vec.sub(far, v), along) };
}

fn matchCusp(allocator: std.mem.Allocator, body: *const Body, interior: []std.ArrayList(Interior), first: End, second: End, tol: Tolerance) Error!void {
    const a = leaving(body, first);
    const b = leaving(body, second);
    // One circle (two pieces at a seam): no cusp
    if (@abs(a.circle.r - b.circle.r) <= tol.zone and vec.distance(a.circle.c, b.circle.c) <= tol.zone) return;
    // Tangent at the vertex, leaving it the same way, curving to the same side, coplanar
    if (!tol.sameDirection(a.along, b.along)) return;
    if (vec.dot(a.inward, b.inward) <= 0) return;
    if (!tol.parallel(a.circle.normal(), b.circle.normal())) return;
    const inner_first = a.circle.r < b.circle.r;
    const tight_end = if (inner_first) first else second;
    const flat_end = if (inner_first) second else first;
    const tight = if (inner_first) a else b;
    const flat = if (inner_first) b else a;
    const tight_edge = body.edge(types.EdgeIndex.of(tight_end.edge));
    const flat_edge = body.edge(types.EdgeIndex.of(flat_end.edge));
    const v = body.point(if (tight_end.at_start) tight_edge.start else tight_edge.end);
    const far_vertex = body.point(if (flat_end.at_start) flat_edge.end else flat_edge.start);
    // The tighter arc's points from the vertex outward (its list runs in parameter order,
    // from the vertex when the vertex is its start, towards it otherwise)
    const tight_points = interior[tight_end.edge].items;
    const n = tight_points.len;
    var s_prev: f64 = 0;
    for (0..n) |k| {
        const q = tight_points[if (tight_end.at_start) k else n - 1 - k].p;
        const s = vec.dot(vec.sub(q, v), tight.along);
        // Past a quarter turn the arc is no graph over the tangent; past the flatter
        // arc's reach there is nothing to match
        if (s <= s_prev or s >= flat.reach - tol.zone or s >= flat.circle.r) break;
        s_prev = s;
        // The flatter circle's point at tangent coordinate `s`, below the tangent by the
        // circle's drop there
        const drop = flat.circle.r - @sqrt(flat.circle.r * flat.circle.r - s * s);
        const p = vec.add(vec.add(v, vec.scale(flat.along, s)), vec.scale(flat.inward, drop));
        if (vec.distance(p, far_vertex) <= tol.zone) break;
        var known = false;
        for (interior[flat_end.edge].items) |have| known = known or vec.distance(have.p, p) <= tol.zone;
        if (known) continue;
        var t = flat.circle.project(p);
        if (t < flat_edge.t0 - END_SLACK) t += TWO_PI;
        try interior[flat_end.edge].append(allocator, .{ .t = t, .p = p });
    }
}
