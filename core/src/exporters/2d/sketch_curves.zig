//! The curves a sketch's graph defines, with the points they were drawn with: the circles
//! (every `circle`, each corner of a `rounded_square` and each arc of a `closed_path` below
//! the sketch's node) and the cubic curves (a text's glyphs', the `polygons_even_odd` node
//! keeps, and a `closed_path`'s, an imported drawing's), carried through the sketch's
//! transforms: a cubic through any, a circle as long as those keep a circle a circle (a
//! similarity: a uniform scale, a turn, a mirror, a move); neither through an offset, which draws its own shape. A sketch that is a Solid's
//! projection or slice (`project`, `slice`) has the Solid's: a cylinder's cap (a cone's
//! larger one), and the sketches of its extrusions, through the Solid's moves that keep the
//! XY plane (a move, a turn about z, a scale even in x and y, a mirror across a vertical
//! plane). The 2D exporters match the kernel's outlines against them to write the curves
//! the chords came from (exporters/2d/curves.zig).

const std = @import("std");
const dag = @import("../../vm/dag.zig");
const bezier = @import("../../core/bezier.zig");
const affine2 = @import("../../core/affine2.zig");

/// The most curves collected for one sketch: a shared subgraph is visited once per path
/// to it, so a graph of many unions of many copies can name more than a drawing needs.
const MAX_CURVES = 10_000;

/// A circle as drawn: its centre and radius after the sketch's transforms, and the points
/// the kernel was given for it, in order around it: all the way round for a `circle`
/// (`closed`: the last point neighbours the first), a quarter of the way for a corner.
pub const Circle = struct {
    center: [2]f64,
    radius: f64,
    points: [][2]f64,
    closed: bool,
};

/// A cubic curve as drawn: its controls after the sketch's transforms, and the points the
/// kernel was given for it, from its start to its end.
pub const Cubic = struct {
    control: bezier.Cubic,
    points: [][2]f64,
};

pub const Curves = struct {
    circles: []Circle,
    cubics: []Cubic,

    pub const empty = Curves{ .circles = &.{}, .cubics = &.{} };

    pub fn deinit(self: *Curves, allocator: std.mem.Allocator) void {
        for (self.circles) |circle| allocator.free(circle.points);
        allocator.free(self.circles);
        for (self.cubics) |cubic| allocator.free(cubic.points);
        allocator.free(self.cubics);
    }
};

/// The curves below `root` (a sketch node of `b`). Owned by `allocator`.
pub fn collect(allocator: std.mem.Allocator, b: *const dag.DAGBuilder, root: dag.DAGNodeIndex) !Curves {
    var circles: std.ArrayList(Circle) = .empty;
    errdefer {
        for (circles.items) |circle| allocator.free(circle.points);
        circles.deinit(allocator);
    }
    var cubics: std.ArrayList(Cubic) = .empty;
    errdefer {
        for (cubics.items) |cubic| allocator.free(cubic.points);
        cubics.deinit(allocator);
    }
    const Visit = struct { node: dag.DAGNodeIndex, matrix: affine2.Matrix };
    var pending: std.ArrayList(Visit) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, .{ .node = root, .matrix = affine2.identity });
    while (pending.pop()) |visit| {
        if (visit.node == dag.CONCRETE_NODE_SENTINEL) continue;
        if (circles.items.len + cubics.items.len >= MAX_CURVES) break;
        const node = b.nodes.items[visit.node];
        switch (node.tag) {
            // A glyph's curves, each with the run of its contour's points it became
            .polygons_even_odd => {
                const p = b.getPolygonsPayload(node);
                for (0..p.curveCount()) |i| {
                    const curve = p.curve(@intCast(i));
                    const points = try allocator.dupe([2]f64, p.contour(curve.contour)[curve.first..][0..curve.count]);
                    errdefer allocator.free(points);
                    for (points) |*pt| pt.* = affine2.apply(visit.matrix, pt.*);
                    const control = bezier.Cubic{ .c1 = affine2.apply(visit.matrix, curve.cubic.c1), .c2 = affine2.apply(visit.matrix, curve.cubic.c2) };
                    try cubics.append(allocator, .{ .control = control, .points = points });
                }
            },
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
                const ranges = try allocator.alloc(@import("../../core/path.zig").Range, closed.segments.len);
                defer allocator.free(ranges);
                try @import("../../core/path.zig").appendPoints(allocator, &pts, closed.start, closed.segments, closed.chords, ranges);
                for (closed.segments, ranges, 0..) |segment, range, i| {
                    // A curve's points: its start (the segment before's end, or the path's start) and its own
                    const first = if (i == 0) 0 else ranges[i - 1].first + ranges[i - 1].count - 1;
                    if (segment.arc) |arc| {
                        try addCircle(allocator, &circles, visit.matrix, arc.center, arc.radius, try allocator.dupe([2]f64, pts.items[first .. range.first + range.count]), false);
                    } else if (segment.cubic) |cubic| {
                        // Any transform keeps a cubic a cubic, its controls moved with it
                        const points = try allocator.dupe([2]f64, pts.items[first .. range.first + range.count]);
                        errdefer allocator.free(points);
                        for (points) |*pt| pt.* = affine2.apply(visit.matrix, pt.*);
                        const control = bezier.Cubic{ .c1 = affine2.apply(visit.matrix, cubic.c1), .c2 = affine2.apply(visit.matrix, cubic.c2) };
                        try cubics.append(allocator, .{ .control = control, .points = points });
                    }
                }
            },
            .cs_transform => {
                const p = b.getTransformPayload(node);
                try pending.append(allocator, .{ .node = p.target, .matrix = affine2.compose(visit.matrix, b.numbers.items[p.num_idx..][0..6].*) });
            },
            .cs_set_name, .cs_set_material, .set_name, .set_material, .project_op, .slice_op => try pending.append(allocator, .{ .node = b.extra_data.items[node.data], .matrix = visit.matrix }),
            .cs_union_op, .cs_difference_op, .cs_intersection_op, .union_op, .difference_op, .intersection_op => {
                const p = b.getBinaryPayload(node);
                try pending.append(allocator, .{ .node = p.left, .matrix = visit.matrix });
                try pending.append(allocator, .{ .node = p.right, .matrix = visit.matrix });
            },
            // A hull keeps the points of its operands' outlines it reaches: where it runs
            // along a circle it joins neighbouring points (an arc), and across a gap two
            // points that aren't (a line)
            .batch_union_op, .cs_hull_op => for (b.getBatchUnionPayload(node)) |operand| try pending.append(allocator, .{ .node = operand, .matrix = visit.matrix }),
            // A cylinder seen from above is its larger cap (the points of the smaller
            // one lie inside), drawn as the kernel draws it, from the +x axis
            .cylinder => {
                const p = b.getCylinderPayload(node);
                const radius = @max(p.r1, p.r2);
                try addCircle(allocator, &circles, visit.matrix, .{ 0, 0 }, radius, try circlePoints(allocator, radius, p.segments), true);
            },
            // A straight extrusion seen from above is its sketch
            .extrude => {
                const p = b.getExtrudePayload(node);
                if (p.twist_degrees == 0 and p.scale_x == 1 and p.scale_y == 1) try pending.append(allocator, .{ .node = p.target, .matrix = visit.matrix });
            },
            // A Solid's moves that keep the XY plane are the sketch's
            .translate, .rotate, .scale, .mirror => {
                const p = b.getTranslatePayload(node);
                const flat: ?affine2.Matrix = switch (node.tag) {
                    .translate => affine2.translation(p.x, p.y),
                    .rotate => if (p.x == 0 and p.y == 0) affine2.rotation(p.z) else null,
                    .scale => affine2.scaling(p.x, p.y),
                    // Across a vertical plane: its normal lies in XY; across a horizontal
                    // one nothing moves in XY
                    .mirror => if (p.z == 0) affine2.reflection(p.x, p.y) else if (p.x == 0 and p.y == 0) affine2.identity else null,
                    else => unreachable,
                };
                if (flat) |m| try pending.append(allocator, .{ .node = p.target, .matrix = affine2.compose(visit.matrix, m) });
            },
            // An offset draws its own outline; a revolve, hull, Minkowski sum, trim or
            // concrete leaf gives a shape of its own; the rest have no circle
            else => {},
        }
    }
    const found = try circles.toOwnedSlice(allocator);
    errdefer {
        for (found) |circle| allocator.free(circle.points);
        allocator.free(found);
    }
    return .{ .circles = found, .cubics = try cubics.toOwnedSlice(allocator) };
}

/// Adds the circle of `radius` at `center` drawn with `points` (owned from here on), as
/// `matrix` places it, if the matrix keeps it a circle.
fn addCircle(allocator: std.mem.Allocator, circles: *std.ArrayList(Circle), matrix: affine2.Matrix, center: [2]f64, radius: f64, points: [][2]f64, closed: bool) !void {
    errdefer allocator.free(points);
    const scale = affine2.similarityScale(matrix) orelse {
        allocator.free(points);
        return;
    };
    for (points) |*p| p.* = affine2.apply(matrix, p.*);
    try circles.append(allocator, .{ .center = affine2.apply(matrix, center), .radius = radius * scale, .points = points, .closed = closed });
}

/// The points the kernel draws a circle of `radius` with: `segments` of them from the +x
/// axis, counter-clockwise (Manifold's CrossSection::Circle, and a cylinder's cap).
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
