//! The curves in a sketch's outlines: the kernel draws a circle as chords between the
//! points it was given, a glyph's curve as the lines it was flattened into, and keeps those
//! points through its booleans, so an edge of an outline whose ends are two neighbouring
//! points of a curve the sketch defined (vm/sketch_curves.zig) is a piece of that curve: a
//! run of chords of one circle is an arc of it, exact (the circle's centre and radius), and
//! a run of all of a cubic's pieces the cubic itself. `outlinesOf` turns the kernel's
//! contours into outlines of lines, arcs and cubics for the 2D exporters to write as such.
//! An edge with a point no curve has (where a boolean cut a chord) stays a line, and so do
//! the pieces of a cubic a boolean cut short: a part of a cubic isn't the cubic. A point
//! no curve has that lies on the line between its neighbours (a slice crosses a cylinder's
//! side triangles mid-chord; a boolean leaves one where edges met) is dropped first: it is
//! no corner, and would cut a chord in two.

const std = @import("std");
const geom = @import("../../kernel/geometry_handle.zig");
const drawing = @import("drawing.zig");
const sketch_curves = @import("../../vm/sketch_curves.zig");
const Curves = sketch_curves.Curves;

/// Where a contour's point lies on a curve: which circle or cubic, and which of its points.
const On = union(enum) {
    circle: struct { circle: u32, index: u32 },
    cubic: struct { cubic: u32, index: u32 },
};

/// What an edge of a contour is a piece of; null for a line.
const Piece = union(enum) {
    /// A chord of a circle, and its way round.
    chord: struct { circle: u32, ccw: bool },
    /// A piece of a cubic between its points `index` and `index + 1`, run from the first
    /// when `forward`.
    cubic: struct { cubic: u32, index: u32, forward: bool },
};

/// The contours of a sketch as outlines of lines, arcs and cubics, each edge between two
/// neighbouring points (within `tolerance`) of a curve in `curves` a piece of it. Owned by
/// `allocator`.
pub fn outlinesOf(allocator: std.mem.Allocator, contours: geom.Contours, curves: *const Curves, tolerance: f64) ![]drawing.Outline {
    var index = try PointIndex.init(allocator, curves, tolerance);
    defer index.deinit();
    var outlines: std.ArrayList(drawing.Outline) = .empty;
    errdefer {
        for (outlines.items) |outline| allocator.free(outline.edges);
        outlines.deinit(allocator);
    }
    try outlines.ensureTotalCapacity(allocator, contours.count());
    for (0..contours.count()) |ci| {
        const points = try withoutCollinear(allocator, contours.contour(ci), &index);
        defer allocator.free(points);
        if (points.len == 0) continue;
        const pieces = try allocator.alloc(?Piece, points.len);
        defer allocator.free(pieces);
        for (points, pieces, 0..) |p, *piece, i| piece.* = index.pieceOf(p, points[(i + 1) % points.len]);
        outlines.appendAssumeCapacity(try outlineOf(allocator, points, pieces, curves));
    }
    return outlines.toOwnedSlice(allocator);
}

/// `contour` without the points that lie on the line between their neighbours (within the
/// index's tolerance of it, and between them) and are no curve's, as a closed polygon.
/// Owned by `allocator`.
fn withoutCollinear(allocator: std.mem.Allocator, contour: []const [2]f64, index: *const PointIndex) ![][2]f64 {
    var kept: std.ArrayList([2]f64) = .empty;
    errdefer kept.deinit(allocator);
    const n = contour.len;
    for (contour, 0..) |p, i| {
        if (n >= 3 and !index.has(p) and onSegment(p, contour[(i + n - 1) % n], contour[(i + 1) % n], index.tolerance)) continue;
        try kept.append(allocator, p);
    }
    return kept.toOwnedSlice(allocator);
}

/// Whether `p` lies on the segment from `a` to `b`, within `tolerance` of the line and
/// between the ends.
fn onSegment(p: [2]f64, a: [2]f64, b: [2]f64, tolerance: f64) bool {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len == 0) return false;
    const cross = @abs((p[0] - a[0]) * dy - (p[1] - a[1]) * dx) / len;
    const along = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len;
    return cross <= tolerance and along >= -tolerance and along <= len + tolerance;
}

/// `points` as an outline, the edges whose pieces lie on one circle in a row merged into
/// one arc, a cubic's pieces all in a row into the cubic (fewer stay lines); a contour that
/// is one circle becomes two half turns.
fn outlineOf(allocator: std.mem.Allocator, points: []const [2]f64, pieces: []const ?Piece, curves: *const Curves) !drawing.Outline {
    const n = points.len;
    // Start where a run starts: at an edge that doesn't carry on its predecessor's curve
    var first: usize = 0;
    while (first < n and continues(pieces[(first + n - 1) % n], pieces[first])) : (first += 1) {}
    if (first == n) {
        // Every edge carries on the one before: chords of the same circle, the same way
        // round, a full circle (a cubic's pieces end where its points do)
        const chord = pieces[0].?.chord;
        const circle = curves.circles[chord.circle];
        const edges = try allocator.alloc(drawing.Edge, 2);
        const arc = drawing.Arc{ .center = circle.center, .radius = circle.radius };
        const antipode = [2]f64{ 2 * circle.center[0] - points[0][0], 2 * circle.center[1] - points[0][1] };
        edges[0] = .{ .to = antipode, .arc = arc, .ccw = chord.ccw, .angle = std.math.pi };
        edges[1] = .{ .to = points[0], .arc = arc, .ccw = chord.ccw, .angle = std.math.pi };
        return .{ .start = points[0], .edges = edges };
    }
    var edges: std.ArrayList(drawing.Edge) = .empty;
    errdefer edges.deinit(allocator);
    var i: usize = 0;
    while (i < n) {
        const at = (first + i) % n;
        const piece = pieces[at] orelse {
            try edges.append(allocator, .{ .to = points[(at + 1) % n] });
            i += 1;
            continue;
        };
        // The run of pieces of this curve from here, each carrying on the one before
        var run: usize = 1;
        while (i + run < n and continues(pieces[(at + run - 1) % n], pieces[(at + run) % n])) : (run += 1) {}
        const end = points[(at + run) % n];
        switch (piece) {
            .chord => |chord| {
                const circle = curves.circles[chord.circle];
                try edges.append(allocator, .{
                    .to = end,
                    .arc = .{ .center = circle.center, .radius = circle.radius },
                    .ccw = chord.ccw,
                    .angle = drawing.sweep(circle.center, points[at], end, chord.ccw),
                });
            },
            .cubic => |c| {
                const cubic = curves.cubics[c.cubic];
                if (run == cubic.points.len - 1) {
                    try edges.append(allocator, .{ .to = end, .cubic = if (c.forward) cubic.control else cubic.control.reversed() });
                } else {
                    for (1..run + 1) |k| try edges.append(allocator, .{ .to = points[(at + k) % n] });
                }
            },
        }
        i += run;
    }
    return .{ .start = points[first], .edges = try edges.toOwnedSlice(allocator) };
}

/// Whether `next` carries on `prev`: a chord of the same circle, the same way round, or
/// the next piece of the same cubic, the same way along.
fn continues(prev: ?Piece, next: ?Piece) bool {
    const a = prev orelse return false;
    const b = next orelse return false;
    return switch (a) {
        .chord => |chord| b == .chord and chord.circle == b.chord.circle and chord.ccw == b.chord.ccw,
        .cubic => |cubic| b == .cubic and cubic.cubic == b.cubic.cubic and cubic.forward == b.cubic.forward and
            (if (cubic.forward) b.cubic.index == cubic.index + 1 else cubic.index > 0 and b.cubic.index == cubic.index - 1),
    };
}

/// The curves' points on a grid of `tolerance` cells, to find which of them a contour's
/// point is (the kernel keeps them to the bit, but a transform is applied by it and by us
/// in our own order of operations).
const PointIndex = struct {
    allocator: std.mem.Allocator,
    curves: *const Curves,
    tolerance: f64,
    /// Each point on a curve, chained per cell.
    entries: std.ArrayList(Entry) = .empty,
    cells: std.AutoHashMapUnmanaged(Cell, u32) = .empty,

    const Cell = struct { x: i64, y: i64 };
    const Entry = struct { on: On, next: ?u32 };

    fn init(allocator: std.mem.Allocator, curves: *const Curves, tolerance: f64) !PointIndex {
        var index = PointIndex{ .allocator = allocator, .curves = curves, .tolerance = tolerance };
        errdefer index.deinit();
        for (curves.circles, 0..) |circle, c| {
            for (circle.points, 0..) |p, i| try index.add(p, .{ .circle = .{ .circle = @intCast(c), .index = @intCast(i) } });
        }
        for (curves.cubics, 0..) |cubic, c| {
            for (cubic.points, 0..) |p, i| try index.add(p, .{ .cubic = .{ .cubic = @intCast(c), .index = @intCast(i) } });
        }
        return index;
    }

    fn deinit(self: *PointIndex) void {
        self.entries.deinit(self.allocator);
        self.cells.deinit(self.allocator);
    }

    fn add(self: *PointIndex, p: [2]f64, on: On) !void {
        const gop = try self.cells.getOrPut(self.allocator, self.cellOf(p));
        const head: ?u32 = if (gop.found_existing) gop.value_ptr.* else null;
        try self.entries.append(self.allocator, .{ .on = on, .next = head });
        gop.value_ptr.* = @intCast(self.entries.items.len - 1);
    }

    fn cellOf(self: *const PointIndex, p: [2]f64) Cell {
        return .{ .x = @intFromFloat(@floor(p[0] / self.tolerance)), .y = @intFromFloat(@floor(p[1] / self.tolerance)) };
    }

    /// The point of a curve `p` is, if it is one.
    fn pointOf(self: *const PointIndex, on: On) [2]f64 {
        return switch (on) {
            .circle => |c| self.curves.circles[c.circle].points[c.index],
            .cubic => |c| self.curves.cubics[c.cubic].points[c.index],
        };
    }

    /// Whether `p` is a point of some curve.
    fn has(self: *const PointIndex, p: [2]f64) bool {
        var it = self.near_points(p);
        return it.next() != null;
    }

    /// The piece of a curve from `p` to its neighbouring point `q`; null when there is
    /// none.
    fn pieceOf(self: *const PointIndex, p: [2]f64, q: [2]f64) ?Piece {
        var it = self.near_points(p);
        while (it.next()) |on| switch (on) {
            .circle => |c| {
                const circle = self.curves.circles[c.circle];
                // The point's neighbours on the circle: the last point neighbours the
                // first only all the way round
                const n: u32 = @intCast(circle.points.len);
                const after: ?u32 = if (c.index + 1 < n) c.index + 1 else if (circle.closed) 0 else null;
                const before: ?u32 = if (c.index > 0) c.index - 1 else if (circle.closed) n - 1 else null;
                for ([_]?u32{ after, before }) |maybe| {
                    const neighbour = maybe orelse continue;
                    if (!self.near(circle.points[neighbour], q)) continue;
                    // Which way round, by the turn about the centre
                    const cross = (p[0] - circle.center[0]) * (q[1] - circle.center[1]) - (p[1] - circle.center[1]) * (q[0] - circle.center[0]);
                    return .{ .chord = .{ .circle = c.circle, .ccw = cross > 0 } };
                }
            },
            .cubic => |c| {
                const cubic = self.curves.cubics[c.cubic];
                if (c.index + 1 < cubic.points.len and self.near(cubic.points[c.index + 1], q)) return .{ .cubic = .{ .cubic = c.cubic, .index = c.index, .forward = true } };
                if (c.index > 0 and self.near(cubic.points[c.index - 1], q)) return .{ .cubic = .{ .cubic = c.cubic, .index = c.index - 1, .forward = false } };
            },
        };
        return null;
    }

    /// The curves' points within the tolerance of `p`, in the cells around it.
    fn near_points(self: *const PointIndex, p: [2]f64) NearPoints {
        return .{ .index = self, .p = p, .cell = self.cellOf(p) };
    }

    const NearPoints = struct {
        index: *const PointIndex,
        p: [2]f64,
        cell: Cell,
        /// Which of the 9 cells around `p`'s is being walked, and where in its chain.
        around: u8 = 0,
        at: ?u32 = null,

        fn next(self: *NearPoints) ?On {
            while (self.around < 9) {
                if (self.at == null) {
                    const dx: i64 = @as(i64, self.around % 3) - 1;
                    const dy: i64 = @as(i64, self.around / 3) - 1;
                    self.at = self.index.cells.get(.{ .x = self.cell.x + dx, .y = self.cell.y + dy });
                    if (self.at == null) {
                        self.around += 1;
                        continue;
                    }
                }
                const entry = self.index.entries.items[self.at.?];
                self.at = entry.next;
                if (self.at == null) self.around += 1;
                if (self.index.near(self.index.pointOf(entry.on), self.p)) return entry.on;
            }
            return null;
        }
    };

    fn near(self: *const PointIndex, a: [2]f64, b: [2]f64) bool {
        return @abs(a[0] - b[0]) <= self.tolerance and @abs(a[1] - b[1]) <= self.tolerance;
    }
};
