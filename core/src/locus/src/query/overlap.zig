//! Whether a body overlaps itself (docs/architecture.md §9.1, level 2): the checker's global
//! rules that need an intersector, which the checker may not import (§4: it imports no
//! operation), so they live here and run where bodies are graded (the operations' tests,
//! the fuzzer, the boolean's own results). A sheet is `sketch/overlap.zig`'s: overlaid
//! with itself it winds once about every region. A solid's rules, on planar faces (curved
//! face pairs are M5's):
//!
//! - Two faces meet only on their boundaries: what they share (`intersect/planar_faces.zig`)
//!   lies within the intersection tolerance of an edge of each, and two faces in one plane
//!   cover no region together (the overlay of the two, §7.3). One rule for the faces of a
//!   shell and for faces of two shells: faces sharing an edge meet along it, and solids
//!   touching along a line or at a point (the sweep of a bow tie, its two solids with an
//!   edge each on the line) pass, as touching at a point does in the checker; a face
//!   passing through another, or lying on it, does not. Solids (two shells) touching at a
//!   point inside a face of one, a corner on a face, pass too: a point splits no face.
//! - Each shell lies where the other shells put no material (an outer shell) or one solid's
//!   worth (a void): at a point inside one of its faces, the other shells' winding numbers
//!   (a closed shell's solid angle about the point over 4π, +1 inside an outer shell, −1
//!   inside a void, wound outward) sum to 0 for an outer shell and to 1 for a void. That is
//!   "voids inside an outer shell and not inside each other, shells apart" in one count,
//!   and right for any nesting (a solid in a void of another solid, a void in it).

const std = @import("std");
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const index_mod = @import("index.zig");
const in_face = @import("in_face.zig");
const planar_faces = @import("../intersect/planar_faces.zig");
const overlay_mod = @import("../sketch/overlay.zig");
const sketch_overlap = @import("../sketch/overlap.zig");
const triangulate = @import("../mesh/triangulate.zig");
const Body = body_mod.Body;
const Piece = planar_faces.Piece;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// How far from a whole number a shell's winding number about a point may be and the
/// point still count as off the shell: on it the number is a half, near it anything.
const WHOLE: f64 = 0.25;
const FOUR_PI: f64 = 4.0 * std.math.pi;

/// Fails with `faces_intersect` or `shell_overlaps` (`error.NotValid`) when `body` overlaps
/// itself; a sheet with `faces_overlap` (`sketch/overlap.zig`).
pub fn check(allocator: std.mem.Allocator, body: *const Body, options: diagnostics.Options, diag: *Diagnostics) Error!void {
    if (body.kind == .sheet) return sketch_overlap.check(allocator, body, diag);
    if (body.isEmpty()) return;
    const tol = options.tolerance orelse body.tol;
    var index = try index_mod.FaceIndex.build(allocator, body, diag);
    defer index.deinit(allocator);
    try facePairs(allocator, body, &index, tol, options, diag);
    try shellCounts(allocator, body, options, diag);
}

/// The first rule over every pair of faces whose boxes overlap, in order of their items.
fn facePairs(allocator: std.mem.Allocator, body: *const Body, index: *const index_mod.FaceIndex, tol: Tolerance, options: diagnostics.Options, diag: *Diagnostics) Error!void {
    const Collect = struct {
        allocator: std.mem.Allocator,
        out: std.ArrayList([2]u32) = .empty,
        failed: bool = false,
        fn visit(self: *@This(), i: u32, j: u32) bool {
            if (i >= j) return true;
            self.out.append(self.allocator, .{ i, j }) catch {
                self.failed = true;
                return false;
            };
            return true;
        }
        fn lessThan(_: void, x: [2]u32, y: [2]u32) bool {
            return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
        }
    };
    var collect: Collect = .{ .allocator = allocator };
    defer collect.out.deinit(allocator);
    index.bvh.queryPairs(&index.bvh, &collect, Collect.visit);
    if (collect.failed) return error.OutOfMemory;
    std.mem.sort([2]u32, collect.out.items, {}, Collect.lessThan);

    var pieces: std.ArrayList(Piece) = .empty;
    defer pieces.deinit(allocator);
    for (collect.out.items) |pair| {
        try options.checkCancel();
        const f = index.faces[pair[0]];
        const g = index.faces[pair[1]];
        if (planar_faces.frameOf(body, f) == null or planar_faces.frameOf(body, g) == null) continue;
        pieces.clearRetainingCapacity();
        const relation = try planar_faces.meet(allocator, body, f, body, g, tol, &pieces, diag);
        const overlaps = switch (relation) {
            .apart => false,
            .crossing => blk: {
                const apart = body.face(f).shell != body.face(g).shell;
                for (pieces.items) |piece| if (!try onBoundaries(body, f, g, piece, apart, tol, diag)) break :blk true;
                break :blk false;
            },
            .coplanar => try coplanarOverlap(allocator, body, f, g, tol, diag),
        };
        if (overlaps) return diag.fail(error.NotValid, .{ .code = .faces_intersect, .entity = .of(.face, @backingInt(f)), .measured = @floatFromInt(@backingInt(g)) });
    }
}

/// Whether every point of `piece` (its ends and middle) lies within the intersection
/// tolerance of both faces' boundaries: the faces touch there, neither passing into the
/// other. A point where faces of two shells touch needs only one's boundary: solids touching
/// at a point (a corner on a face) split no face, so no edge or vertex of the face records
/// it (a vertex loop could, once the mesher and the STEP writer take one); within one shell
/// it would be a pinch.
fn onBoundaries(body: *const Body, f: types.FaceIndex, g: types.FaceIndex, piece: Piece, apart: bool, tol: Tolerance, diag: *Diagnostics) Error!bool {
    if (piece.isPoint() and apart) return try nearBoundary(body, f, piece.a, tol, diag) or try nearBoundary(body, g, piece.a, tol, diag);
    const points = [3]Vec3{ piece.a, vec.lerp(piece.a, piece.b, 0.5), piece.b };
    const count: usize = if (piece.isPoint()) 1 else 3;
    for (points[0..count]) |p| {
        if (!try nearBoundary(body, f, p, tol, diag) or !try nearBoundary(body, g, p, tol, diag)) return false;
    }
    return true;
}

fn nearBoundary(body: *const Body, f: types.FaceIndex, p: Vec3, tol: Tolerance, diag: *Diagnostics) Error!bool {
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        const lone = body.loop(l).vertex;
        if (lone != .none and vec.distance(body.point(lone), p) <= tol.xsect) return true;
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            if (in_face.edgeDistance(body, body.coedge(c).edge, p) <= tol.xsect) return true;
        }
    }
    return false;
}

/// Whether faces `f` and `g`, in one plane, cover a region together: the overlay of the
/// two in `f`'s plane has a face both wind about.
fn coplanarOverlap(allocator: std.mem.Allocator, body: *const Body, f: types.FaceIndex, g: types.FaceIndex, tol: Tolerance, diag: *Diagnostics) Error!bool {
    const frame = planar_faces.frameOf(body, f).?;
    var o = overlay_mod.Overlay.init(allocator, tol);
    defer o.deinit();
    for ([2]types.FaceIndex{ f, g }) |face| {
        _ = o.addInput() catch |e| return planar_faces.overlayError(diag, e);
        try planar_faces.addFace(&o, body, face, frame, diag);
    }
    o.run() catch |e| return planar_faces.overlayError(diag, e);
    for (0..o.faces.items.len) |k| {
        if (o.windingOf(@intCast(k), 0) != 0 and o.windingOf(@intCast(k), 1) != 0) return true;
    }
    return false;
}

/// The second rule: each shell where the others put no material, or a void's one.
fn shellCounts(allocator: std.mem.Allocator, body: *const Body, options: diagnostics.Options, diag: *Diagnostics) Error!void {
    var shells: std.ArrayList(types.ShellIndex) = .empty;
    defer shells.deinit(allocator);
    var it = traverse.Shells.init(body);
    while (it.next() catch return corrupt(diag)) |s| {
        if (!try straightPlanar(body, s, diag)) return;
        try shells.append(allocator, s);
    }
    if (shells.items.len < 2) return;
    for (shells.items) |s| {
        try options.checkCancel();
        const expected: f64 = if (body.shell(s).kind == .void) 1 else 0;
        var last: f64 = 0;
        var faces = traverse.Faces.init(body, s);
        const material: f64 = decided: while (faces.next() catch return corrupt(diag)) |f| {
            const p = try facePoint(allocator, body, f, diag) orelse continue;
            var sum: f64 = 0;
            var clean = true;
            for (shells.items) |t| {
                if (t == s) continue;
                const w = try winding(body, t, p, diag);
                const whole = @round(w);
                if (@abs(w - whole) > WHOLE) clean = false;
                sum += if (clean) whole else w;
            }
            last = sum;
            if (clean) break :decided sum;
        } else last;
        if (material != expected) return diag.fail(error.NotValid, .{ .code = .shell_overlaps, .entity = .of(.shell, @backingInt(s)), .measured = material, .threshold = expected });
    }
}

/// Whether every face of shell `s` is planar with straight edges (the faces the winding
/// number sums exactly by fans).
fn straightPlanar(body: *const Body, s: types.ShellIndex, diag: *Diagnostics) Error!bool {
    var faces = traverse.Faces.init(body, s);
    while (faces.next() catch return corrupt(diag)) |f| {
        if (body.face(f).surface.kind != .plane) return false;
        var loops = traverse.Loops.init(body, f);
        while (loops.next() catch return corrupt(diag)) |l| {
            var coedges = traverse.Coedges.init(body, l);
            while (coedges.next() catch return corrupt(diag)) |c| {
                if (body.edge(body.coedge(c).edge).curve.kind != .line) return false;
            }
        }
    }
    return true;
}

/// Shell `s`'s winding number about `p`: the solid angle its faces subtend, signed by
/// their outward sense, over 4π (+1 inside an outer shell, −1 inside a void, 0 outside,
/// a fraction on or near it). Each face as a fan of its loops from one of its vertices:
/// the signed fans of a planar polygon with holes add up to the polygon whatever its
/// shape. Straight planar faces only (`straightPlanar`).
pub fn winding(body: *const Body, s: types.ShellIndex, p: Vec3, diag: *Diagnostics) Error!f64 {
    var total: f64 = 0;
    var faces = traverse.Faces.init(body, s);
    while (faces.next() catch return corrupt(diag)) |f| {
        const first = body.loop(body.face(f).first_loop).first;
        if (first == .none) continue;
        const apex = vec.sub(body.point(body.coedgeStart(first)), p);
        var loops = traverse.Loops.init(body, f);
        while (loops.next() catch return corrupt(diag)) |l| {
            var it = traverse.Coedges.init(body, l);
            while (it.next() catch return corrupt(diag)) |c| {
                const a = vec.sub(body.point(body.coedgeStart(c)), p);
                const b = vec.sub(body.point(body.coedgeEnd(c)), p);
                total += solidAngle(apex, a, b);
            }
        }
    }
    return total / FOUR_PI;
}

/// The signed solid angle of the triangle `a b c` (corners relative to the point) seen
/// from the point: positive when it runs counter-clockwise seen from beyond it (van
/// Oosterom and Strackee, 1983).
fn solidAngle(a: Vec3, b: Vec3, c: Vec3) f64 {
    const la = vec.length(a);
    const lb = vec.length(b);
    const lc = vec.length(c);
    const det = vec.dot(a, vec.cross(b, c));
    const den = la * lb * lc + vec.dot(a, b) * lc + vec.dot(a, c) * lb + vec.dot(b, c) * la;
    return 2.0 * trig.atan2(det, den);
}

/// A point strictly inside planar face `f` with straight edges: the centroid of the
/// largest triangle of its triangulation, or null when it has none (a curved edge, a
/// boundary the triangulator refuses).
pub fn facePoint(allocator: std.mem.Allocator, body: *const Body, f: types.FaceIndex, diag: *Diagnostics) Error!?Vec3 {
    const frame = planar_faces.frameOf(body, f) orelse return null;
    var points: std.ArrayList(Vec2) = .empty;
    defer points.deinit(allocator);
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(allocator);
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        try starts.append(allocator, @intCast(points.items.len));
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            if (body.edge(body.coedge(c).edge).curve.kind != .line) return null;
            try points.append(allocator, planar_faces.flat(frame, body.point(body.coedgeStart(c))));
        }
    }
    try starts.append(allocator, @intCast(points.items.len));
    return interiorPoint(allocator, frame, points.items, starts.items, &.{});
}

/// A point strictly inside the polygon of `rings` (`starts` as `triangulate.Polygon`'s,
/// the outer ring first, either way round, holes the other way) in `frame`'s plane, as far
/// as it can be found from the rings' edges and the segments `avoid` (what else bounds the
/// region: a slit through it): of the centroids of the triangles of its triangulation, the
/// one furthest from them; null when the triangulator refuses the rings. A centroid of
/// the largest triangle alone may lie on a slit, or on a vertex of one.
pub fn interiorPoint(allocator: std.mem.Allocator, frame: geometry.Frame, points: []Vec2, starts: []const u32, avoid: []const [2]Vec2) Error!?Vec3 {
    var candidates: std.ArrayList(Vec3) = .empty;
    defer candidates.deinit(allocator);
    try interiorPoints(allocator, frame, points, starts, avoid, &candidates);
    return if (candidates.items.len > 0) candidates.items[0] else null;
}

/// Every centroid of the triangles of the polygon's triangulation (as `interiorPoint` finds
/// them), the furthest from the rings' edges and `avoid` first, appended to `out`: a caller
/// whose first point lands where it can decide nothing (on another body's boundary) tries
/// the next. None when the triangulator refuses the rings.
pub fn interiorPoints(allocator: std.mem.Allocator, frame: geometry.Frame, points: []Vec2, starts: []const u32, avoid: []const [2]Vec2, out: *std.ArrayList(Vec3)) Error!void {
    if (starts.len < 2) return;
    // Counter-clockwise outer ring: mirrored when it runs the other way
    const mirror = ringArea(points[starts[0]..starts[1]]) < 0;
    if (mirror) for (points) |*q| {
        q[1] = -q[1];
    };
    defer if (mirror) for (points) |*q| {
        q[1] = -q[1];
    };
    var scratch = Diagnostics.init(allocator);
    defer scratch.deinit();
    const triangles = triangulate.triangulate(allocator, .{ .points = points, .starts = starts }, &scratch) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer allocator.free(triangles);
    const Candidate = struct { at: Vec2, clearance: f64 };
    var found: std.ArrayList(Candidate) = .empty;
    defer found.deinit(allocator);
    for (triangles) |t| {
        const a = points[t[0]];
        const b = points[t[1]];
        const c = points[t[2]];
        if (vec.cross2(vec.sub2(b, a), vec.sub2(c, a)) <= 0) continue;
        const centroid: Vec2 = .{ (a[0] + b[0] + c[0]) / 3.0, (a[1] + b[1] + c[1]) / 3.0 };
        // In the rings' own coordinates, where `avoid` is given
        const q: Vec2 = .{ centroid[0], if (mirror) -centroid[1] else centroid[1] };
        var clearance = std.math.inf(f64);
        for (0..starts.len - 1) |r| {
            const ring = points[starts[r]..starts[r + 1]];
            for (ring, 0..) |p, i| {
                const u: Vec2 = .{ p[0], if (mirror) -p[1] else p[1] };
                const w0 = ring[(i + 1) % ring.len];
                const w: Vec2 = .{ w0[0], if (mirror) -w0[1] else w0[1] };
                clearance = @min(clearance, segmentDistance(q, u, w));
            }
        }
        for (avoid) |segment| clearance = @min(clearance, segmentDistance(q, segment[0], segment[1]));
        try found.append(allocator, .{ .at = q, .clearance = clearance });
    }
    // The clearest first; ties in the triangulation's order
    const Order = struct {
        fn lessThan(_: void, x: Candidate, y: Candidate) bool {
            return x.clearance > y.clearance;
        }
    };
    std.mem.sort(Candidate, found.items, {}, Order.lessThan);
    for (found.items) |c| try out.append(allocator, frame.toWorld(.{ c.at[0], c.at[1], 0 }));
}

/// The distance from `p` to the segment from `a` to `b`.
fn segmentDistance(p: Vec2, a: Vec2, b: Vec2) f64 {
    const d = vec.sub2(b, a);
    const len_sq = vec.lengthSq2(d);
    const s = if (len_sq == 0) 0 else std.math.clamp(vec.dot2(vec.sub2(p, a), d) / len_sq, 0, 1);
    return vec.distance2(p, vec.addScaled2(a, d, s));
}

fn ringArea(ring: []const Vec2) f64 {
    var area: f64 = 0;
    for (ring, 0..) |p, i| area += vec.cross2(p, ring[(i + 1) % ring.len]);
    return area;
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
