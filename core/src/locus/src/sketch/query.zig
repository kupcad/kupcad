//! What a sketch answers (docs/architecture.md §7.5): its outlines as closed polylines at a
//! `Resolution` (the mesh engine's polygon: lofts and sweeps), or with their arcs kept exact
//! (what SVG and DXF are made of), whether a point is in it (on its outline
//! within a tolerance counts), and whether it is one convex outline. Its area and box are
//! the measures every body has.

const std = @import("std");
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
const ray_crossing = @import("../math/ray_crossing.zig");
const curves = @import("../geometry/curves.zig");
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const overlay = @import("overlay.zig");
const edges = @import("../mesh/edges.zig");
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

/// The sketch's loops as polylines, each arc cut on the grid a full circle of its radius
/// gets at `resolution` (`mesh/edges.zig`: the mesh engine's polygon), a line kept whole.
/// Owned by `allocator`.
pub fn contours(allocator: std.mem.Allocator, sheet: *const Body, resolution: tolerance.Resolution, diag: *Diagnostics) Error!Contours {
    const out = try walk(allocator, sheet, resolution, false, diag);
    allocator.free(out.arcs);
    return .{ .points = out.points, .starts = out.starts };
}

/// An arc of an outline, exact: the edge from a point of the outline to the next runs
/// along the circle about `c` of radius `r`, counter-clockwise when `ccw`, over `angle`
/// radians (a half turn is exactly π: the edge's own range).
pub const OutlineArc = struct {
    c: Vec2,
    r: f64,
    ccw: bool,
    angle: f64,
};

/// `Contours` whose arcs are kept: `arcs[i]` is the arc the edge from point `i` to the
/// next of its contour runs along, null for a line's edge.
pub const Outlines = struct {
    points: []Vec2,
    starts: []u32,
    arcs: []?OutlineArc,

    pub fn deinit(self: *Outlines, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.starts);
        allocator.free(self.arcs);
        self.* = undefined;
    }

    pub fn count(self: Outlines) usize {
        return self.starts.len - 1;
    }

    pub fn contour(self: Outlines, i: usize) []const Vec2 {
        return self.points[self.starts[i]..self.starts[i + 1]];
    }

    pub fn arcsOf(self: Outlines, i: usize) []const ?OutlineArc {
        return self.arcs[self.starts[i]..self.starts[i + 1]];
    }
};

/// The sketch's loops with their arcs exact (what a drawing writes: SVG's arcs, DXF's
/// bulges), a line an edge of its own, any other curve's edge its polyline at
/// `resolution` as in `contours`. Owned by `allocator`.
pub fn outlines(allocator: std.mem.Allocator, sheet: *const Body, resolution: tolerance.Resolution, diag: *Diagnostics) Error!Outlines {
    return walk(allocator, sheet, resolution, true, diag);
}

/// The loops of `sheet` in order, each coedge's points the coedge's way with its last left
/// to the next coedge; an arc's edge is its two ends with the arc when `keep_arcs`, its
/// chords on the circle grid otherwise.
fn walk(allocator: std.mem.Allocator, sheet: *const Body, resolution: tolerance.Resolution, keep_arcs: bool, diag: *Diagnostics) Error!Outlines {
    // The edges' polylines are the mesh's (mesh/edges.zig): a circle's grid from angle 0,
    // so a contour is the outline the tessellation has, and the mesh engine's polygon
    var edge_points = try edges.discretize(allocator, sheet, resolution, diag);
    defer edge_points.deinit(allocator);
    var points = std.ArrayList(Vec2).empty;
    defer points.deinit(allocator);
    var arcs = std.ArrayList(?OutlineArc).empty;
    defer arcs.deinit(allocator);
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
                    const coedge = sheet.coedge(c);
                    const e = sheet.edge(coedge.edge);
                    const arc: ?OutlineArc = if (keep_arcs) switch (sheet.geometry.curve(e.curve)) {
                        .circle => |circle| .{ .c = flat(circle.c), .r = circle.r, .ccw = (circle.normal()[2] > 0) == coedge.same_sense, .angle = e.t1 - e.t0 },
                        else => null,
                    } else null;
                    if (arc != null) {
                        try points.append(allocator, flat(sheet.point(sheet.coedgeStart(c))));
                        try arcs.append(allocator, arc);
                        continue;
                    }
                    const pts = edge_points.of(coedge.edge);
                    // The edge's points the coedge's way, its last left to the next coedge
                    for (0..pts.len - 1) |step| {
                        const k = if (coedge.same_sense) step else pts.len - 1 - step;
                        try points.append(allocator, flat(pts[k]));
                        try arcs.append(allocator, null);
                    }
                }
            }
        }
    }
    try starts.append(allocator, @intCast(points.items.len));
    const owned_points = try points.toOwnedSlice(allocator);
    errdefer allocator.free(owned_points);
    const owned_starts = try starts.toOwnedSlice(allocator);
    errdefer allocator.free(owned_starts);
    return .{ .points = owned_points, .starts = owned_starts, .arcs = try arcs.toOwnedSlice(allocator) };
}

/// How far below a whole number a share of segments may fall and still round down.
const CEIL_SLACK: f64 = 1e-9;

/// Whether `p` is in the sketch: on an outline within `within` of it, or inside its
/// outlines, by the parity of the crossings of the ray from it to +x with every edge of
/// every face's loops (`math/ray_crossing.zig`, exact; a sheet's faces lie apart and its
/// holes inside them, so the parity is the winding's being non-zero). An arc was once cut
/// into pieces whose ends' heights were the circle's at the ends' angles, a rounding from
/// the vertices' own, which the lines beside it read: at a vertex's height both counted
/// the vertex, and a point 6 to the west of a rounded rectangle, level with a corner's
/// end, was in it (the audit of 2026-11-22).
pub fn contains(sheet: *const Body, p: Vec2, within: f64, diag: *Diagnostics) Error!bool {
    var inside = false;
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
                    const crosses = if (edge.arc) |arc| ray_crossing.arc(edge.a, edge.b, arc.c, arc.r, arc.ccw, p) else ray_crossing.line(edge.a, edge.b, p);
                    if (crosses) inside = !inside;
                }
            }
        }
    }
    return inside;
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
    const start = trig.atan2(edge.a[1] - arc.c[1], edge.a[0] - arc.c[0]);
    const end = trig.atan2(edge.b[1] - arc.c[1], edge.b[0] - arc.c[0]);
    const sweep = @mod(if (arc.ccw) end - start else start - end, 2 * std.math.pi);
    return if (sweep < CEIL_SLACK) 2 * std.math.pi else sweep;
}

/// The distance from `p` to an edge.
fn distanceTo(edge: Edge, p: Vec2) f64 {
    if (edge.arc) |arc| {
        // On the arc's circle at p's angle when that lies on the arc, else at the nearer end
        const angle = trig.atan2(p[1] - arc.c[1], p[0] - arc.c[0]);
        const start = trig.atan2(edge.a[1] - arc.c[1], edge.a[0] - arc.c[0]);
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

/// Whether the corner from `prev` to `next` turns left (or goes straight on, within the
/// angular tolerance), as the overlay decides a corner (`overlay.turnAt`): by the tangents
/// alone a reflex cusp (an arc ending tangent to a line, the tangents opposite) was a turn
/// of 0, left enough, and its sketch convex (2026-11-14).
fn turnsLeft(prev: Edge, next: Edge, tol: tolerance.Tolerance) bool {
    return overlay.turnAt(prev.b, prev.a, prev.arc, endTangent(prev), next.b, next.arc, startTangent(next), tol.zone) >= -tol.angle;
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
