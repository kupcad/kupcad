//! Where two planar faces meet (docs/architecture.md §7.2, §9.1): the closed set the two
//! faces share, as points and segments of the line their planes meet in, or the word that
//! they lie in one plane (whose overlap is the overlay's to find, §7.3). The faces may be
//! of one body (the checker's overlap rules, `query/overlap.zig`) or of two.
//!
//! On the line `L` the planes meet in, each face's share is bounded where its boundary
//! crosses the other face's plane, so those crossings (each edge's, by
//! `curve_surface.curvePlane`, an edge lying in the plane giving its ends) are every
//! point where "in both faces" can change along `L`. Sorted along `L`, each crossing and
//! the middle of each gap between two is classified against both faces
//! (`query/in_face.zig`); a run of crossings in both, each gap between them in both by its
//! middle, is a segment, and a crossing in both next to no such gap is a point. Tolerant classification of 3D points
//! (§6's second tier), never an angle: two faces are coplanar when every edge of one lies
//! within the zone of the other's plane, decided at the faces' own size.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const in_face = @import("../query/in_face.zig");
const curve_surface = @import("curve_surface.zig");
const overlay_mod = @import("../sketch/overlay.zig");
const Body = body_mod.Body;
const Frame = geometry.Frame;
const Plane = curve_surface.Plane;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

pub const Relation = enum {
    /// The faces share no point.
    apart,
    /// Their planes cross; what they share is in the pieces (maybe none).
    crossing,
    /// One lies in the other's plane: what they share is a region, a segment or a point of
    /// that plane, for the overlay to find.
    coplanar,
};

/// A piece of what two faces share: the segment from `a` to `b` along their planes'
/// line, or the point `a` when `b` is `a`.
pub const Piece = struct {
    a: Vec3,
    b: Vec3,

    pub fn isPoint(self: Piece) bool {
        return self.a[0] == self.b[0] and self.a[1] == self.b[1] and self.a[2] == self.b[2];
    }
};

/// The frame of planar face `f`'s plane, or null when its surface is not a plane.
pub fn frameOf(body: *const Body, f: types.FaceIndex) ?Frame {
    const surface = body.face(f).surface;
    if (surface.kind != .plane) return null;
    return body.geometry.planes.items[surface.index].frame;
}

/// The plane of a frame's `xy`.
pub fn planeOf(frame: Frame) Plane {
    return .{ .n = frame.z, .d = vec.dot(frame.z, frame.origin) };
}

/// What planar faces `fa` of `a` and `fb` of `b` share, the pieces appended to `pieces`
/// in order along the line. Both faces must be planar.
pub fn meet(allocator: std.mem.Allocator, a: *const Body, fa: types.FaceIndex, b: *const Body, fb: types.FaceIndex, tol: Tolerance, pieces: *std.ArrayList(Piece), diag: *Diagnostics) Error!Relation {
    const frame_a = frameOf(a, fa) orelse return notPlanar(diag, fa);
    const frame_b = frameOf(b, fb) orelse return notPlanar(diag, fb);
    var marks: std.ArrayList(Vec3) = .empty;
    defer marks.deinit(allocator);
    // Each face's boundary on the other's plane
    const in_b = try crossings(allocator, a, fa, planeOf(frame_b), tol, &marks, diag);
    const in_a = try crossings(allocator, b, fb, planeOf(frame_a), tol, &marks, diag);
    if (in_b or in_a) return .coplanar;
    if (marks.items.len == 0) return .apart;
    const along = vec.normalized(vec.cross(frame_a.z, frame_b.z)) orelse return .apart;

    // Along the line, a mark within the zone of the one before it being that one
    const Order = struct {
        along: Vec3,
        fn lessThan(self: @This(), p: Vec3, q: Vec3) bool {
            return vec.dot(p, self.along) < vec.dot(q, self.along);
        }
    };
    std.mem.sort(Vec3, marks.items, Order{ .along = along }, Order.lessThan);
    var kept: usize = 0;
    for (marks.items) |p| {
        if (kept > 0 and tol.samePoint(p, marks.items[kept - 1])) continue;
        marks.items[kept] = p;
        kept += 1;
    }
    const points = marks.items[0..kept];

    // A piece is a run of crossings each in both faces, every gap between them in both by
    // its middle: a gap's middle can be within the zone of a face whose end of it is twice
    // that outside, and a piece reaching that end put a point of one face's boundary on
    // the other face (the overlap rules' find in the solids fuzzer, 2026-11-13: a box's
    // corner the intersection tolerance and a rounding from a triangle's corner)
    const first = pieces.items.len;
    var open: ?Vec3 = null;
    for (points, 0..) |p, i| {
        if (!try inBoth(a, fa, b, fb, p, tol, diag)) {
            if (open) |start| try pieces.append(allocator, .{ .a = start, .b = points[i - 1] });
            open = null;
            continue;
        }
        if (open == null) open = p;
        if (i + 1 < points.len and try inBoth(a, fa, b, fb, vec.lerp(p, points[i + 1], 0.5), tol, diag)) continue;
        try pieces.append(allocator, .{ .a = open.?, .b = p });
        open = null;
    }
    return if (pieces.items.len > first) .crossing else .apart;
}

/// Appends to `marks` where face `f`'s edges meet `plane` (an edge lying in it gives its
/// ends); true when every edge lies in it, the face then lying in the plane. On the plane
/// is within the intersection tolerance and the edge's ends' gaps, as a boolean takes a
/// vertex to lie on a face (`boolean/pave.zig`'s vertex–face): an edge leaving such a
/// vertex at a shallow angle crosses the plane's exact line far from it, inside the other
/// face, where the boolean, rightly, made no edge (the solids fuzzer, 2026-11-13).
fn crossings(allocator: std.mem.Allocator, body: *const Body, f: types.FaceIndex, plane: Plane, tol: Tolerance, marks: *std.ArrayList(Vec3), diag: *Diagnostics) Error!bool {
    var every_in = true;
    var any = false;
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const edge = body.edge(body.coedge(c).edge);
            if (edge.flags.degenerate) continue;
            any = true;
            const curve = body.geometry.curve(edge.curve);
            const found = try curve_surface.curvePlane(curve, edge.t0, edge.t1, plane, edgeReach(body, edge, tol), diag);
            if (found.lies_in) {
                try marks.append(allocator, body.point(edge.start));
                try marks.append(allocator, body.point(edge.end));
                continue;
            }
            every_in = false;
            for (found.params()) |t| {
                // A crossing within the zone of an end is that vertex, exactly
                var p = curve.eval(t);
                for ([_]types.VertexIndex{ edge.start, edge.end }) |v| {
                    if (tol.samePoint(p, body.point(v))) p = body.point(v);
                }
                try marks.append(allocator, p);
            }
        }
    }
    return any and every_in;
}

/// How near an edge a plane or a point must come to be on it: the intersection tolerance
/// and the larger of its ends' gaps, as a boolean takes a vertex to lie on a face
/// (`boolean/pave.zig`'s vertex–face). One reach for an edge lying in a plane
/// (`crossings`) and a point on a face's boundary (`query/overlap.zig`).
pub fn edgeReach(body: *const Body, edge: *const types.Edge, tol: Tolerance) f64 {
    return tol.xsect + @max(body.vertex(edge.start).gap, body.vertex(edge.end).gap);
}

/// Whether `p` lies in both faces, their boundaries included.
fn inBoth(a: *const Body, fa: types.FaceIndex, b: *const Body, fb: types.FaceIndex, p: Vec3, tol: Tolerance, diag: *Diagnostics) Error!bool {
    if (try place(a, fa, p, tol, diag) == .outside) return false;
    return try place(b, fb, p, tol, diag) != .outside;
}

/// Where `p` (near face `f`'s plane) lies against the face, its boundary within the zone.
pub fn place(body: *const Body, f: types.FaceIndex, p: Vec3, tol: Tolerance, diag: *Diagnostics) Error!in_face.Place {
    return in_face.classify(body, f, p, in_face.uvOf(body, f, p), tol.zone, diag);
}

/// Face `f`'s loops (planar, lines and arcs) as edges of the overlay's current input, in
/// the coordinates of `frame`'s plane: each coedge from its start to its end, a circle's
/// as an arc running the way the coedge does.
pub fn addFace(o: *overlay_mod.Overlay, body: *const Body, f: types.FaceIndex, frame: Frame, diag: *Diagnostics) Error!void {
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const coedge = body.coedge(c);
            const e = body.edge(coedge.edge);
            if (e.flags.degenerate) continue;
            const pa = flat(frame, body.point(body.coedgeStart(c)));
            const pb = flat(frame, body.point(body.coedgeEnd(c)));
            const edge: overlay_mod.InputEdge = switch (body.geometry.curve(e.curve)) {
                .line => .{ .a = pa, .b = pb },
                .circle => |circle| .{ .a = pa, .b = pb, .arc = .{ .c = flat(frame, circle.c), .r = circle.r, .ccw = (vec.dot(circle.normal(), frame.z) > 0) == coedge.same_sense } },
                else => return diagnostics.notImplemented(diag, "a planar face's edge that is neither a line nor an arc, overlaid", 5),
            };
            o.addEdge(edge) catch |err| return overlayError(diag, err);
        }
    }
}

/// `p` in the coordinates of `frame`'s plane.
pub fn flat(frame: Frame, p: Vec3) Vec2 {
    const l = frame.toLocal(p);
    return .{ l[0], l[1] };
}

pub fn overlayError(diag: *Diagnostics, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooMany => diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "a face's edges in the overlay" }),
        error.OutOfRange => diag.fail(error.InvalidInput, .{ .code = .too_large_for_tolerance, .label = "a coordinate" }),
        else => unreachable,
    };
}

fn notPlanar(diag: *Diagnostics, f: types.FaceIndex) Error {
    return diag.fail(error.InvalidInput, .{ .code = .not_implemented, .entity = .of(.face, @backingInt(f)), .label = "a face meeting another as a plane (it is curved)" });
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "a face" });
}
