//! The circles a sketch's graph defines, with the points they were drawn with: every
//! `circle` and each corner of a `rounded_square` below the sketch's node, carried through
//! the sketch's transforms as long as those keep a circle a circle (a similarity: a uniform
//! scale, a turn, a mirror, a move), and not through an offset or a boolean's other side,
//! which draw their own shapes. The 2D exporters match the kernel's outlines against them
//! to write the arcs the chords came from (exporters/2d/arcs.zig).

const std = @import("std");
const dag = @import("dag.zig");
const rounded_rect = @import("../core/rounded_rect.zig");

/// The most circles collected for one sketch: a shared subgraph is visited once per path
/// to it, so a graph of many unions of many copies can name more than a drawing needs.
const MAX_CIRCLES = 10_000;
/// How far from a similarity a transform's matrix may be (relative to its scale) and still
/// keep a circle a circle.
const SIMILARITY_TOLERANCE = 1e-9;

/// A circle as drawn: its centre and radius after the sketch's transforms, and the points
/// the kernel was given for it, in order around it: all the way round for a `circle`
/// (`closed`: the last point neighbours the first), a quarter of the way for a corner.
pub const Circle = struct {
    center: [2]f64,
    radius: f64,
    points: [][2]f64,
    closed: bool,
};

pub const Circles = struct {
    items: []Circle,

    pub fn deinit(self: *Circles, allocator: std.mem.Allocator) void {
        for (self.items) |circle| allocator.free(circle.points);
        allocator.free(self.items);
    }
};

/// A 2D affine transform as the graph stores one: column-major, x' = a x + c y + tx and
/// y' = b x + d y + ty.
const Matrix = struct {
    m: [6]f64,

    const identity = Matrix{ .m = .{ 1, 0, 0, 1, 0, 0 } };

    /// This transform applied after `inner`.
    fn then(self: Matrix, inner: [6]f64) Matrix {
        const o = self.m;
        return .{ .m = .{
            o[0] * inner[0] + o[2] * inner[1],
            o[1] * inner[0] + o[3] * inner[1],
            o[0] * inner[2] + o[2] * inner[3],
            o[1] * inner[2] + o[3] * inner[3],
            o[0] * inner[4] + o[2] * inner[5] + o[4],
            o[1] * inner[4] + o[3] * inner[5] + o[5],
        } };
    }

    fn apply(self: Matrix, p: [2]f64) [2]f64 {
        const o = self.m;
        return .{ o[0] * p[0] + o[2] * p[1] + o[4], o[1] * p[0] + o[3] * p[1] + o[5] };
    }

    /// The factor a length is scaled by, when the transform keeps a circle a circle (its
    /// two columns equally long and perpendicular); null when it makes an ellipse.
    fn similarityScale(self: Matrix) ?f64 {
        const o = self.m;
        const sx = std.math.hypot(o[0], o[1]);
        const sy = std.math.hypot(o[2], o[3]);
        const scale = @max(sx, sy);
        if (scale == 0) return null;
        if (@abs(sx - sy) > SIMILARITY_TOLERANCE * scale) return null;
        if (@abs(o[0] * o[2] + o[1] * o[3]) > SIMILARITY_TOLERANCE * scale * scale) return null;
        return sx;
    }
};

/// The circles below `root` (a sketch node of `b`). Owned by `allocator`.
pub fn collect(allocator: std.mem.Allocator, b: *const dag.DAGBuilder, root: dag.DAGNodeIndex) !Circles {
    var circles: std.ArrayList(Circle) = .empty;
    errdefer {
        for (circles.items) |circle| allocator.free(circle.points);
        circles.deinit(allocator);
    }
    const Visit = struct { node: dag.DAGNodeIndex, matrix: Matrix };
    var pending: std.ArrayList(Visit) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, .{ .node = root, .matrix = Matrix.identity });
    while (pending.pop()) |visit| {
        if (visit.node == dag.CONCRETE_NODE_SENTINEL) continue;
        if (circles.items.len >= MAX_CIRCLES) break;
        const node = b.nodes.items[visit.node];
        switch (node.tag) {
            .circle => {
                const p = b.getCirclePayload(node);
                try addCircle(allocator, &circles, visit.matrix, .{ 0, 0 }, p.radius, try circlePoints(allocator, p.radius, p.segments), true);
            },
            .rounded_square => {
                const rect = b.getRoundedSquarePayload(node);
                var pts: std.ArrayList([2]f64) = .empty;
                defer pts.deinit(allocator);
                try rect.appendPoints(allocator, &pts);
                for (rect.corners()) |corner| {
                    try addCircle(allocator, &circles, visit.matrix, corner.center, corner.radius, try allocator.dupe([2]f64, pts.items[corner.first..][0..corner.count]), false);
                }
            },
            .closed_path => {
                const closed = try b.readClosedPath(allocator, node);
                defer closed.deinit(allocator);
                var pts: std.ArrayList([2]f64) = .empty;
                defer pts.deinit(allocator);
                const ranges = try allocator.alloc(@import("../core/path.zig").Range, closed.segments.len);
                defer allocator.free(ranges);
                try @import("../core/path.zig").appendPoints(allocator, &pts, closed.start, closed.segments, closed.chords, ranges);
                for (closed.segments, ranges, 0..) |segment, range, i| {
                    const arc = segment.arc orelse continue;
                    // An arc's points: its start (the segment before's end, or the path's start) and its own
                    const first = if (i == 0) 0 else ranges[i - 1].first + ranges[i - 1].count - 1;
                    try addCircle(allocator, &circles, visit.matrix, arc.center, arc.radius, try allocator.dupe([2]f64, pts.items[first .. range.first + range.count]), false);
                }
            },
            .cs_transform => {
                const p = b.getTransformPayload(node);
                try pending.append(allocator, .{ .node = p.target, .matrix = visit.matrix.then(b.numbers.items[p.num_idx..][0..6].*) });
            },
            .cs_set_name, .cs_set_material => try pending.append(allocator, .{ .node = b.extra_data.items[node.data], .matrix = visit.matrix }),
            .cs_union_op, .cs_difference_op, .cs_intersection_op => {
                const p = b.getBinaryPayload(node);
                try pending.append(allocator, .{ .node = p.left, .matrix = visit.matrix });
                try pending.append(allocator, .{ .node = p.right, .matrix = visit.matrix });
            },
            // An offset draws its own outline; a slice or projection is a solid's; the
            // rest have no circle
            else => {},
        }
    }
    return .{ .items = try circles.toOwnedSlice(allocator) };
}

/// Adds the circle of `radius` at `center` drawn with `points` (owned from here on), as
/// `matrix` places it, if the matrix keeps it a circle.
fn addCircle(allocator: std.mem.Allocator, circles: *std.ArrayList(Circle), matrix: Matrix, center: [2]f64, radius: f64, points: [][2]f64, closed: bool) !void {
    errdefer allocator.free(points);
    const scale = matrix.similarityScale() orelse {
        allocator.free(points);
        return;
    };
    for (points) |*p| p.* = matrix.apply(p.*);
    try circles.append(allocator, .{ .center = matrix.apply(center), .radius = radius * scale, .points = points, .closed = closed });
}

/// The points the kernel draws a circle of `radius` with: `segments` of them from the +x
/// axis, counter-clockwise (Manifold's CrossSection::Circle).
fn circlePoints(allocator: std.mem.Allocator, radius: f64, segments: i32) ![][2]f64 {
    const n: usize = @intCast(@max(segments, 3));
    const points = try allocator.alloc([2]f64, n);
    const step = 2.0 * std.math.pi / @as(f64, @floatFromInt(n));
    for (points, 0..) |*p, i| {
        const ang = step * @as(f64, @floatFromInt(i));
        p.* = .{ radius * @cos(ang), radius * @sin(ang) };
    }
    return points;
}
