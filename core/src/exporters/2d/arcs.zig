//! The arcs in a sketch's outlines: the kernel draws a circle as chords between the points
//! it was given, and keeps those points through its booleans, so an edge of an outline whose
//! ends are two neighbouring points of a circle the sketch defined (vm/sketch_circles.zig)
//! is a chord of that circle, and a run of them one arc. `outlinesOf` turns the kernel's
//! contours into outlines of lines and arcs, each arc exact (the circle's centre and radius),
//! for the 2D exporters to write as such. An edge with a point no circle has (where a
//! boolean cut a chord) stays a line.

const std = @import("std");
const geom = @import("../../kernel/geometry_handle.zig");
const drawing = @import("drawing.zig");
const Circle = @import("../../vm/sketch_circles.zig").Circle;

/// Where a contour's point lies on a circle: which circle, and which of its points.
const OnCircle = struct { circle: u32, index: u32 };

/// A chord's circle and way round, for an edge of a contour; null for a line.
const Chord = struct { circle: u32, ccw: bool };

/// The contours of a sketch as outlines of lines and arcs, each chord of a circle in
/// `circles` (whose points it joins, within `tolerance`) an arc of it, runs of them one arc.
/// Owned by `allocator`.
pub fn outlinesOf(allocator: std.mem.Allocator, contours: geom.Contours, circles: []const Circle, tolerance: f64) ![]drawing.Outline {
    var index = try PointIndex.init(allocator, circles, tolerance);
    defer index.deinit();
    var outlines: std.ArrayList(drawing.Outline) = .empty;
    errdefer {
        for (outlines.items) |outline| allocator.free(outline.edges);
        outlines.deinit(allocator);
    }
    try outlines.ensureTotalCapacity(allocator, contours.count());
    for (0..contours.count()) |ci| {
        const points = contours.contour(ci);
        if (points.len == 0) continue;
        const chords = try allocator.alloc(?Chord, points.len);
        defer allocator.free(chords);
        for (points, chords, 0..) |p, *chord, i| chord.* = index.chordOf(p, points[(i + 1) % points.len]);
        outlines.appendAssumeCapacity(try outlineOf(allocator, points, chords, circles));
    }
    return outlines.toOwnedSlice(allocator);
}

/// `points` as an outline, the edges whose chords lie on one circle in a row merged into
/// one arc; a contour that is one circle becomes two half turns.
fn outlineOf(allocator: std.mem.Allocator, points: []const [2]f64, chords: []const ?Chord, circles: []const Circle) !drawing.Outline {
    const n = points.len;
    // Start where a run starts: at an edge that doesn't carry on its predecessor's arc
    var first: usize = 0;
    while (first < n and continues(chords[(first + n - 1) % n], chords[first])) : (first += 1) {}
    if (first == n) {
        // Every edge is a chord of the same circle, the same way round: a full circle
        const circle = circles[chords[0].?.circle];
        const edges = try allocator.alloc(drawing.Edge, 2);
        const arc = drawing.Arc{ .center = circle.center, .radius = circle.radius };
        const antipode = [2]f64{ 2 * circle.center[0] - points[0][0], 2 * circle.center[1] - points[0][1] };
        edges[0] = .{ .to = antipode, .arc = arc, .ccw = chords[0].?.ccw, .angle = std.math.pi };
        edges[1] = .{ .to = points[0], .arc = arc, .ccw = chords[0].?.ccw, .angle = std.math.pi };
        return .{ .start = points[0], .edges = edges };
    }
    var edges: std.ArrayList(drawing.Edge) = .empty;
    errdefer edges.deinit(allocator);
    var i: usize = 0;
    while (i < n) {
        const at = (first + i) % n;
        const chord = chords[at] orelse {
            try edges.append(allocator, .{ .to = points[(at + 1) % n] });
            i += 1;
            continue;
        };
        // The run of chords on this circle from here
        var run: usize = 1;
        while (i + run < n and continues(chord, chords[(at + run) % n])) : (run += 1) {}
        const circle = circles[chord.circle];
        const end = points[(at + run) % n];
        try edges.append(allocator, .{
            .to = end,
            .arc = .{ .center = circle.center, .radius = circle.radius },
            .ccw = chord.ccw,
            .angle = drawing.sweep(circle.center, points[at], end, chord.ccw),
        });
        i += run;
    }
    return .{ .start = points[first], .edges = try edges.toOwnedSlice(allocator) };
}

/// Whether `next` carries on `prev`'s arc: a chord of the same circle, the same way round.
fn continues(prev: ?Chord, next: ?Chord) bool {
    const a = prev orelse return false;
    const b = next orelse return false;
    return a.circle == b.circle and a.ccw == b.ccw;
}

/// The circles' points on a grid of `tolerance` cells, to find which of them a contour's
/// point is (the kernel keeps them to the bit, but a transform is applied by it and by us
/// in our own order of operations).
const PointIndex = struct {
    allocator: std.mem.Allocator,
    circles: []const Circle,
    tolerance: f64,
    /// Each point on a circle, chained per cell.
    entries: std.ArrayList(Entry) = .empty,
    cells: std.AutoHashMapUnmanaged(Cell, u32) = .empty,

    const Cell = struct { x: i64, y: i64 };
    const Entry = struct { on: OnCircle, next: ?u32 };
    const NONE: u32 = std.math.maxInt(u32);

    fn init(allocator: std.mem.Allocator, circles: []const Circle, tolerance: f64) !PointIndex {
        var index = PointIndex{ .allocator = allocator, .circles = circles, .tolerance = tolerance };
        errdefer index.deinit();
        for (circles, 0..) |circle, c| {
            for (circle.points, 0..) |p, i| {
                const gop = try index.cells.getOrPut(allocator, index.cellOf(p));
                const head: ?u32 = if (gop.found_existing) gop.value_ptr.* else null;
                try index.entries.append(allocator, .{ .on = .{ .circle = @intCast(c), .index = @intCast(i) }, .next = head });
                gop.value_ptr.* = @intCast(index.entries.items.len - 1);
            }
        }
        return index;
    }

    fn deinit(self: *PointIndex) void {
        self.entries.deinit(self.allocator);
        self.cells.deinit(self.allocator);
    }

    fn cellOf(self: *const PointIndex, p: [2]f64) Cell {
        return .{ .x = @intFromFloat(@floor(p[0] / self.tolerance)), .y = @intFromFloat(@floor(p[1] / self.tolerance)) };
    }

    /// The circle whose two neighbouring points `p` and `q` are, and which way round `q`
    /// is from `p`; null when there is none.
    fn chordOf(self: *const PointIndex, p: [2]f64, q: [2]f64) ?Chord {
        const cell = self.cellOf(p);
        var dx: i64 = -1;
        while (dx <= 1) : (dx += 1) {
            var dy: i64 = -1;
            while (dy <= 1) : (dy += 1) {
                var at = self.cells.get(.{ .x = cell.x + dx, .y = cell.y + dy });
                while (at) |e| : (at = self.entries.items[e].next) {
                    const on = self.entries.items[e].on;
                    const circle = self.circles[on.circle];
                    if (!self.near(circle.points[on.index], p)) continue;
                    // The point's neighbours on the circle: the last point neighbours the
                    // first only all the way round
                    const n: u32 = @intCast(circle.points.len);
                    const after: ?u32 = if (on.index + 1 < n) on.index + 1 else if (circle.closed) 0 else null;
                    const before: ?u32 = if (on.index > 0) on.index - 1 else if (circle.closed) n - 1 else null;
                    for ([_]?u32{ after, before }) |maybe| {
                        const neighbour = maybe orelse continue;
                        if (!self.near(circle.points[neighbour], q)) continue;
                        // Which way round, by the turn about the centre
                        const cross = (p[0] - circle.center[0]) * (q[1] - circle.center[1]) - (p[1] - circle.center[1]) * (q[0] - circle.center[0]);
                        return .{ .circle = on.circle, .ccw = cross > 0 };
                    }
                }
            }
        }
        return null;
    }

    fn near(self: *const PointIndex, a: [2]f64, b: [2]f64) bool {
        return @abs(a[0] - b[0]) <= self.tolerance and @abs(a[1] - b[1]) <= self.tolerance;
    }
};
