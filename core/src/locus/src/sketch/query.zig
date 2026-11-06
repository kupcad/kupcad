//! What a sketch answers (docs/architecture.md §7.5): its outlines as closed polylines at a
//! `Resolution` (what SVG and DXF are made of), whether a point is in it (on its outline
//! within a tolerance counts), and whether it is one convex outline. Its area and box are
//! the measures every body has.

const std = @import("std");
const vec = @import("../math/vec.zig");
const curves = @import("../geometry/curves.zig");
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const overlay = @import("overlay.zig");
const Body = body_mod.Body;
const Vec2 = vec.Vec2;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// The outlines of a sketch as closed polylines: contour `i` is
/// `points[starts[i]..starts[i + 1]]`, its last point joined to its first. Outer
/// outlines run counter-clockwise, holes clockwise.
pub const Contours = struct {
    points: []Vec2,
    starts: []u32,

    pub fn deinit(self: *Contours, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.starts);
        self.* = undefined;
    }

    pub fn count(self: Contours) usize {
        return self.starts.len - 1;
    }

    pub fn contour(self: Contours, i: usize) []const Vec2 {
        return self.points[self.starts[i]..self.starts[i + 1]];
    }
};

/// The sketch's loops as polylines, each arc cut into its share of the edges a full
/// circle of its radius gets at `resolution` (at least one), a line kept whole. Owned by
/// `allocator`.
pub fn contours(allocator: std.mem.Allocator, sheet: *const Body, resolution: tolerance.Resolution, diag: *Diagnostics) Error!Contours {
    var points = std.ArrayList(Vec2).empty;
    defer points.deinit(allocator);
    var starts = std.ArrayList(u32).empty;
    defer starts.deinit(allocator);
    var shells = traverse.Shells.init(sheet);
    while (shells.next() catch return corrupt(diag)) |s| {
        var faces = traverse.Faces.init(sheet, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            var loops = traverse.Loops.init(sheet, f);
            while (loops.next() catch return corrupt(diag)) |l| {
                try starts.append(allocator, @intCast(points.items.len));
                var it = traverse.Coedges.init(sheet, l);
                while (it.next() catch return corrupt(diag)) |c| {
                    const edge = try edgeOf(sheet, c, diag);
                    try points.append(allocator, edge.a);
                    const arc = edge.arc orelse continue;
                    // The arc's interior points, its ends being the vertices
                    const sweep = sweepOf(edge);
                    const per_turn = resolution.segmentsFor(arc.r);
                    const pieces: usize = @max(1, @as(usize, @intFromFloat(@ceil(sweep / (2 * std.math.pi) * @as(f64, @floatFromInt(per_turn)) - CEIL_SLACK))));
                    const start = std.math.atan2(edge.a[1] - arc.c[1], edge.a[0] - arc.c[0]);
                    const sign: f64 = if (arc.ccw) 1 else -1;
                    for (1..pieces) |k| {
                        const angle = start + sign * sweep * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(pieces));
                        try points.append(allocator, vec.addScaled2(arc.c, .{ @cos(angle), @sin(angle) }, arc.r));
                    }
                }
            }
        }
    }
    try starts.append(allocator, @intCast(points.items.len));
    const owned_points = try points.toOwnedSlice(allocator);
    errdefer allocator.free(owned_points);
    return .{ .points = owned_points, .starts = try starts.toOwnedSlice(allocator) };
}

/// How far below a whole number a share of segments may fall and still round down.
const CEIL_SLACK: f64 = 1e-9;

/// Whether `p` is in the sketch: on an outline within `within` of it, or inside by the
/// non-zero winding of the outlines about it (holes wind the other way).
pub fn contains(sheet: *const Body, p: Vec2, within: f64, diag: *Diagnostics) Error!bool {
    var winding: i32 = 0;
    var shells = traverse.Shells.init(sheet);
    while (shells.next() catch return corrupt(diag)) |s| {
        var faces = traverse.Faces.init(sheet, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            var loops = traverse.Loops.init(sheet, f);
            while (loops.next() catch return corrupt(diag)) |l| {
                var it = traverse.Coedges.init(sheet, l);
                while (it.next() catch return corrupt(diag)) |c| {
                    const edge = try edgeOf(sheet, c, diag);
                    if (distanceTo(edge, p) <= within) return true;
                    winding += windingTerm(edge, p);
                }
            }
        }
    }
    return winding != 0;
}

/// Whether the sketch is one convex outline: one face of one loop, every corner turning
/// left and every arc bulging outward (counter-clockwise), the arcs' tangents taken at
/// their ends. A sketch with holes or several outlines is not.
pub fn isConvex(sheet: *const Body, diag: *Diagnostics) Error!bool {
    const counts = sheet.counts();
    if (counts.faces != 1 or counts.loops != 1) return false;
    const face = sheet.face(sheet.shell(sheet.first_shell).first_face);
    var first: ?Edge = null;
    var previous: ?Edge = null;
    var it = traverse.Coedges.init(sheet, face.first_loop);
    while (it.next() catch return corrupt(diag)) |c| {
        const edge = try edgeOf(sheet, c, diag);
        if (edge.arc) |arc| if (!arc.ccw) return false;
        if (previous) |prev| if (!turnsLeft(prev, edge, sheet.tol)) return false;
        if (first == null) first = edge;
        previous = edge;
    }
    return turnsLeft(previous.?, first.?, sheet.tol);
}

/// An edge of a sketch as its coedge runs it: from `a` to `b`, straight or an arc.
const Edge = struct { a: Vec2, b: Vec2, arc: ?overlay.Arc };

fn edgeOf(sheet: *const Body, c: anytype, diag: *Diagnostics) Error!Edge {
    const coedge = sheet.coedge(c);
    const e = sheet.edge(coedge.edge);
    const a = flat(sheet.point(sheet.coedgeStart(c)));
    const b = flat(sheet.point(sheet.coedgeEnd(c)));
    return switch (sheet.geometry.curve(e.curve)) {
        .line => .{ .a = a, .b = b, .arc = null },
        .circle => |circle| .{ .a = a, .b = b, .arc = .{ .c = flat(circle.c), .r = circle.r, .ccw = (circle.normal()[2] > 0) == coedge.same_sense } },
        else => diag.fail(error.NotRepresentable, .{ .code = .not_implemented, .entity = .of(.edge, @backingInt(coedge.edge)), .label = "a sketch edge that is neither a line nor an arc" }),
    };
}

fn flat(p: vec.Vec3) Vec2 {
    return .{ p[0], p[1] };
}

/// An arc edge's angle, the way it turns.
fn sweepOf(edge: Edge) f64 {
    const arc = edge.arc.?;
    const start = std.math.atan2(edge.a[1] - arc.c[1], edge.a[0] - arc.c[0]);
    const end = std.math.atan2(edge.b[1] - arc.c[1], edge.b[0] - arc.c[0]);
    const sweep = @mod(if (arc.ccw) end - start else start - end, 2 * std.math.pi);
    return if (sweep < CEIL_SLACK) 2 * std.math.pi else sweep;
}

/// The distance from `p` to an edge.
fn distanceTo(edge: Edge, p: Vec2) f64 {
    if (edge.arc) |arc| {
        // On the arc's circle at p's angle when that lies on the arc, else at the nearer end
        const angle = std.math.atan2(p[1] - arc.c[1], p[0] - arc.c[0]);
        const start = std.math.atan2(edge.a[1] - arc.c[1], edge.a[0] - arc.c[0]);
        const along = @mod(if (arc.ccw) angle - start else start - angle, 2 * std.math.pi);
        if (along <= sweepOf(edge)) return @abs(vec.distance2(p, arc.c) - arc.r);
        return @min(vec.distance2(p, edge.a), vec.distance2(p, edge.b));
    }
    const d = vec.sub2(edge.b, edge.a);
    const len_sq = vec.dot2(d, d);
    if (len_sq == 0) return vec.distance2(p, edge.a);
    const t = std.math.clamp(vec.dot2(vec.sub2(p, edge.a), d) / len_sq, 0, 1);
    return vec.distance2(p, vec.addScaled2(edge.a, d, t));
}

/// The edge's crossings of the ray from `p` to +x, signed by its direction: up +1, down
/// −1 (the winding's share), by the half-open rule; an arc by its y-monotone pieces.
fn windingTerm(edge: Edge, p: Vec2) i32 {
    if (edge.arc) |arc| {
        // The count's parity and the arc's net direction: each piece crossing adds the
        // piece's direction
        return arcWinding(edge, arc, p);
    }
    const a = edge.a;
    const b = edge.b;
    if ((a[1] > p[1]) == (b[1] > p[1])) return 0;
    const x = a[0] + (p[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1]);
    if (p[0] >= x) return 0;
    return if (b[1] > a[1]) 1 else -1;
}

/// The arc cut at its topmost and bottommost points into y-monotone pieces, each a
/// crossing of the ray to +x when p's height lies in it and the piece is to the right,
/// signed by whether the piece rises.
fn arcWinding(edge: Edge, arc: overlay.Arc, p: Vec2) i32 {
    const sweep = sweepOf(edge);
    const start = std.math.atan2(edge.a[1] - arc.c[1], edge.a[0] - arc.c[0]);
    const sign: f64 = if (arc.ccw) 1 else -1;
    var cuts: [4]f64 = .{ 0, sweep, sweep, sweep };
    var n: usize = 2;
    for ([_]f64{ std.math.pi / 2.0, -std.math.pi / 2.0 }) |extreme| {
        const t = @mod(sign * (extreme - start), 2 * std.math.pi);
        if (t > CEIL_SLACK and t < sweep - CEIL_SLACK) {
            cuts[n] = t;
            n += 1;
        }
    }
    std.mem.sort(f64, cuts[0..n], {}, std.sort.asc(f64));
    var total: i32 = 0;
    for (0..n - 1) |i| {
        const t0 = cuts[i];
        const t1 = cuts[i + 1];
        if (t1 - t0 <= CEIL_SLACK) continue;
        const y0 = arc.c[1] + arc.r * @sin(start + sign * t0);
        const y1 = arc.c[1] + arc.r * @sin(start + sign * t1);
        if ((y0 > p[1]) == (y1 > p[1])) continue;
        const mid = start + sign * (t0 + t1) / 2.0;
        const dy = p[1] - arc.c[1];
        const dx = @sqrt(@max(arc.r * arc.r - dy * dy, 0));
        const x = if (@cos(mid) >= 0) arc.c[0] + dx else arc.c[0] - dx;
        if (p[0] < x) total += if (y1 > y0) 1 else -1;
    }
    return total;
}

/// Whether the corner from `prev` to `next` turns left (or goes straight on).
fn turnsLeft(prev: Edge, next: Edge, tol: tolerance.Tolerance) bool {
    const t1 = endTangent(prev);
    const t2 = startTangent(next);
    return vec.cross2(t1, t2) >= -tol.angle;
}

fn startTangent(edge: Edge) Vec2 {
    if (edge.arc) |arc| return arcTangent(edge.a, arc);
    return vec.normalized2(vec.sub2(edge.b, edge.a)) orelse .{ 1, 0 };
}

fn endTangent(edge: Edge) Vec2 {
    if (edge.arc) |arc| return arcTangent(edge.b, arc);
    return vec.normalized2(vec.sub2(edge.b, edge.a)) orelse .{ 1, 0 };
}

fn arcTangent(p: Vec2, arc: overlay.Arc) Vec2 {
    const radial = vec.normalized2(vec.sub2(p, arc.c)) orelse return .{ 1, 0 };
    return if (arc.ccw) vec.perp2(radial) else vec.scale2(vec.perp2(radial), -1);
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the sketch" });
}
