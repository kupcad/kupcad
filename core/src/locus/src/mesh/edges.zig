//! Edge discretization (docs/architecture.md §7.7): every edge of a body is cut into a
//! polyline once, so the faces on both sides share the same points and a mesh built on
//! them is watertight by construction. A line is its two vertices. A circle's edge takes
//! the points of the grid a full circle of its radius gets at the `Resolution`,
//! `segmentsFor(r)` equal steps from angle 0, that lie strictly inside the edge's range,
//! between its vertices: the very polygon KupCAD's mesh engine builds for the same circle
//! (kernel parity), and two arcs of one circle meet on the grid. A degenerate edge is one
//! point. Free-form edges (ellipses, NURBS) are M3's and are refused until then.

const std = @import("std");
const vec = @import("../math/vec.zig");
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const Vec3 = vec.Vec3;
const Body = body_mod.Body;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// How near a grid angle may come to an edge's end, as a share of the step, and still
/// count as a point of its own rather than the vertex.
const END_SLACK: f64 = 1e-9;
const TWO_PI: f64 = 2 * std.math.pi;
/// How often a circle's grid may be doubled: 2^8 times the resolution's count at most.
pub const MAX_DOUBLINGS: u8 = 8;

/// The polylines of a body's edges: edge `e` runs through `points[starts[e]..starts[e + 1]]`
/// from its `t0` end to its `t1` end, the vertices' own points at the ends; a tombstoned
/// edge has no points, a degenerate one its one point.
pub const EdgePoints = struct {
    points: []Vec3,
    starts: []u32,

    pub fn deinit(self: *EdgePoints, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.starts);
        self.* = undefined;
    }

    pub fn of(self: EdgePoints, e: types.EdgeIndex) []const Vec3 {
        const i = @backingInt(e);
        return self.points[self.starts[i]..self.starts[i + 1]];
    }
};

/// The edges of `body` as polylines at `resolution`; owned by `allocator`.
pub fn discretize(allocator: std.mem.Allocator, body: *const Body, resolution: tolerance.Resolution, diag: *Diagnostics) Error!EdgePoints {
    return discretizeRefined(allocator, body, resolution, null, diag);
}

/// As `discretize`, each edge's circle grid doubled `doublings[e]` times: the finer grid
/// keeps the coarser one's points, so an edge refined where its chords would cross a
/// neighbour still meets the edges around it where it did.
pub fn discretizeRefined(allocator: std.mem.Allocator, body: *const Body, resolution: tolerance.Resolution, doublings: ?[]const u8, diag: *Diagnostics) Error!EdgePoints {
    var points: std.ArrayList(Vec3) = .empty;
    errdefer points.deinit(allocator);
    const starts = try allocator.alloc(u32, body.edges.items.len + 1);
    errdefer allocator.free(starts);
    for (body.edges.items, 0..) |e, i| {
        starts[i] = @intCast(points.items.len);
        if (e.flags.tombstone) continue;
        if (e.flags.degenerate) {
            try points.append(allocator, body.point(e.start));
            continue;
        }
        try points.append(allocator, body.point(e.start));
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
                    try points.append(allocator, circle.eval(angle));
                }
            },
            .ellipse, .nurbs => return diag.fail(error.NotImplemented, .{ .code = .not_implemented, .entity = .of(.edge, i), .label = "a free-form edge's polyline (M3)" }),
        }
        try points.append(allocator, body.point(e.end));
    }
    starts[body.edges.items.len] = @intCast(points.items.len);
    return .{ .points = try points.toOwnedSlice(allocator), .starts = starts };
}
