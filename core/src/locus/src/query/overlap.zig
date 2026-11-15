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
//! - Shells of one solid touch nowhere (ISO 10303-42: a void apart from its outer shell and
//!   from every other void, which STEP's `brep_with_voids` cannot hold otherwise; Tu §22.3:
//!   the boundary of a solid is a 2-manifold, and a point where it touches itself is not a
//!   manifold point): faces of two shells of one solid (`Solids`) meeting anywhere, or faces
//!   of one shell touching away from where they share an edge or a vertex, are a pinch
//!   (`pinched`); faces of two solids may touch, at a point or along their edges.

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
const distance = @import("distance.zig");
const point_in_body = @import("point_in_body.zig");
const bvh_mod = @import("../spatial/bvh.zig");
const planar_faces = @import("../intersect/planar_faces.zig");
const overlay_mod = @import("../sketch/overlay.zig");
const sketch_overlap = @import("../sketch/overlap.zig");
const triangulate = @import("../mesh/triangulate.zig");
const condition = @import("../topology/condition.zig");
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

/// No solid: a shell taken away, or a void inside no outer shell.
pub const NO_SOLID: u32 = std.math.maxInt(u32);

/// Fails with `faces_intersect` or `shell_overlaps` (`error.NotValid`) when `body` overlaps
/// itself, with `pinched` (`error.Degenerate`) when a solid touches itself; a sheet with
/// `faces_overlap` (`sketch/overlap.zig`).
pub fn check(allocator: std.mem.Allocator, body: *const Body, options: diagnostics.Options, diag: *Diagnostics) Error!void {
    if (body.kind == .sheet) return sketch_overlap.check(allocator, body, diag);
    if (body.isEmpty()) return;
    const tol = options.tolerance orelse body.tol;
    var index = try index_mod.FaceIndex.build(allocator, body, diag);
    defer index.deinit(allocator);
    var solids = try Solids.init(allocator, body, options, diag);
    defer solids.deinit(allocator);
    try facePairs(allocator, body, &index, &solids, tol, options, diag);
    try shellCounts(allocator, body, options, diag);
    if (try nearest(allocator, body, &index, tol, diag)) |near| try diag.warn(.{ .code = .features_near, .entity = near.a, .measured = near.distance, .threshold = 2 * tol.xsect });
}

/// Two features of a body that do not meet, the distance between them.
pub const Near = struct { distance: f64, a: diagnostics.EntityRef, b: diagnostics.EntityRef };

/// The nearest two features of `body` that do not meet come, when nearer than twice the
/// intersection tolerance and their vertices' gaps (the minimum feature size a boolean
/// reaching both needs, Hoffmann p.118 with ε the boolean's reach, architecture §3;
/// research/consistent-tolerances.md, T3): a vertex and a face or an edge it is not on, or
/// two edges sharing no vertex (two planar faces apart are nearest at one of those). Null
/// when none is. Planar faces and straight edges (curved ones M5's).
pub fn nearest(allocator: std.mem.Allocator, body: *const Body, index: *const index_mod.FaceIndex, tol: Tolerance, diag: *Diagnostics) Error!?Near {
    if (body.kind != .solid) return null;
    const reach = 2 * tol.xsect;
    var best: ?Near = null;
    // Straight edges in a tree, each box grown by half the reach and its ends' gaps
    var edges: std.ArrayList(types.EdgeIndex) = .empty;
    defer edges.deinit(allocator);
    var boxes: std.ArrayList(geometry.Box3) = .empty;
    defer boxes.deinit(allocator);
    for (body.edges.items, 0..) |e, i| {
        if (e.flags.tombstone or e.flags.degenerate or e.coedge == .none or e.curve.kind != .line) continue;
        try edges.append(allocator, types.EdgeIndex.of(i));
        var box = geometry.Box3.ofPoint(body.point(e.start));
        box.grow(body.point(e.end));
        try boxes.append(allocator, box.inflated(reach / 2 + @max(body.vertex(e.start).gap, body.vertex(e.end).gap)));
    }
    var tree = try bvh_mod.Bvh.build(allocator, boxes.items);
    defer tree.deinit(allocator);
    const Collect = struct {
        allocator: std.mem.Allocator,
        out: std.ArrayList(u32) = .empty,
        failed: bool = false,
        fn visit(c: *@This(), item: u32) bool {
            c.out.append(c.allocator, item) catch {
                c.failed = true;
                return false;
            };
            return true;
        }
    };
    var near: Collect = .{ .allocator = allocator };
    defer near.out.deinit(allocator);
    for (body.vertices.items, 0..) |v, vi| {
        if (v.tombstone) continue;
        const vertex = types.VertexIndex.of(vi);
        const p = body.point(vertex);
        const within = reach + v.gap;
        // A vertex and an edge it does not end
        near.out.clearRetainingCapacity();
        tree.query(geometry.Box3.ofPoint(p).inflated(reach / 2 + v.gap), &near, Collect.visit);
        if (near.failed) return error.OutOfMemory;
        for (near.out.items) |item| {
            const e = body.edge(edges.items[item]);
            if (e.start == vertex or e.end == vertex) continue;
            const d = in_face.edgeDistance(body, edges.items[item], p);
            try closer(&best, d, within + @max(body.vertex(e.start).gap, body.vertex(e.end).gap), .of(.vertex, vi), .of(.edge, @backingInt(edges.items[item])));
        }
        // A vertex and a face it is not on
        near.out.clearRetainingCapacity();
        index.bvh.query(geometry.Box3.ofPoint(p).inflated(within), &near, Collect.visit);
        if (near.failed) return error.OutOfMemory;
        for (near.out.items) |item| {
            const f = index.faces[item];
            const frame = planar_faces.frameOf(body, f) orelse continue;
            if (try onFace(body, f, vertex, diag)) continue;
            const plane = planar_faces.planeOf(frame);
            const h = plane.height(p);
            const foot = vec.addScaled(p, plane.n, -h);
            const d = if (try in_face.classify(body, f, foot, in_face.uvOf(body, f, foot), 0, diag) == .inside) @abs(h) else try in_face.boundaryDistance(body, f, p, diag);
            try closer(&best, d, within, .of(.vertex, vi), .of(.face, @backingInt(f)));
        }
    }
    // Two edges sharing no vertex
    const Pairs = struct {
        allocator: std.mem.Allocator,
        out: std.ArrayList([2]u32) = .empty,
        failed: bool = false,
        fn visit(c: *@This(), i: u32, j: u32) bool {
            if (i >= j) return true;
            c.out.append(c.allocator, .{ i, j }) catch {
                c.failed = true;
                return false;
            };
            return true;
        }
    };
    var pairs: Pairs = .{ .allocator = allocator };
    defer pairs.out.deinit(allocator);
    tree.queryPairs(&tree, &pairs, Pairs.visit);
    if (pairs.failed) return error.OutOfMemory;
    std.mem.sort([2]u32, pairs.out.items, {}, lessPair);
    for (pairs.out.items) |pair| {
        const x = body.edge(edges.items[pair[0]]);
        const y = body.edge(edges.items[pair[1]]);
        if (x.start == y.start or x.start == y.end or x.end == y.start or x.end == y.end) continue;
        const d = distance.segmentSegment(body.point(x.start), body.point(x.end), body.point(y.start), body.point(y.end)).distance;
        const gaps = @max(body.vertex(x.start).gap, body.vertex(x.end).gap) + @max(body.vertex(y.start).gap, body.vertex(y.end).gap);
        try closer(&best, d, reach + gaps, .of(.edge, @backingInt(edges.items[pair[0]])), .of(.edge, @backingInt(edges.items[pair[1]])));
    }
    return best;
}

/// `best` made the pair `a`, `b` when `d` is within `within` and nearer than it was.
fn closer(best: *?Near, d: f64, within: f64, a: diagnostics.EntityRef, b: diagnostics.EntityRef) Error!void {
    if (!(d < within)) return;
    if (best.* == null or d < best.*.?.distance) best.* = .{ .distance = d, .a = a, .b = b };
}

/// Whether vertex `v` is a corner of face `f`.
fn onFace(body: *const Body, f: types.FaceIndex, v: types.VertexIndex, diag: *Diagnostics) Error!bool {
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        if (body.loop(l).vertex == v) return true;
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| if (body.coedgeStart(c) == v) return true;
    }
    return false;
}

fn lessPair(_: void, x: [2]u32, y: [2]u32) bool {
    return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
}

/// Which solid each shell of a body belongs to (ISO 10303-42: a solid is an outer shell and
/// the voids inside it; solids may touch each other, its own shells may not): an outer shell
/// its own; a void the innermost outer shell around a point strictly inside one of its
/// faces (`pointInside`: a void's vertex may lie on the shell around it, a void touching
/// it, and classifies nothing there; research/manifold-parity.md's octahedral void, every
/// vertex on the outer shell).
pub const Solids = struct {
    /// Each shell's (by index) outer shell, `NO_SOLID` for one taken away or a void inside
    /// no outer shell.
    owner: []u32,

    pub fn init(allocator: std.mem.Allocator, body: *const Body, options: diagnostics.Options, diag: *Diagnostics) Error!Solids {
        const owner = try allocator.alloc(u32, body.shells.items.len);
        errdefer allocator.free(owner);
        @memset(owner, NO_SOLID);
        var outers: std.ArrayList(types.ShellIndex) = .empty;
        defer outers.deinit(allocator);
        var voids: std.ArrayList(types.ShellIndex) = .empty;
        defer voids.deinit(allocator);
        var shells = traverse.Shells.init(body);
        while (shells.next() catch return corrupt(diag)) |s| {
            if (body.shell(s).kind == .void) {
                try voids.append(allocator, s);
            } else {
                owner[@backingInt(s)] = @backingInt(s);
                try outers.append(allocator, s);
            }
        }
        if (voids.items.len == 0) return .{ .owner = owner };
        const indexes = try allocator.alloc(index_mod.FaceIndex, outers.items.len);
        var built: usize = 0;
        defer {
            for (indexes[0..built]) |*i| i.deinit(allocator);
            allocator.free(indexes);
        }
        for (outers.items, indexes) |s, *i| {
            i.* = try index_mod.FaceIndex.buildShell(allocator, body, s, diag);
            built += 1;
        }
        for (voids.items) |v| {
            try options.checkCancel();
            const p = try shellPoint(allocator, body, v, diag) orelse continue;
            // Innermost: of the outer shells around it, the one inside the others
            var best: ?usize = null;
            for (outers.items, indexes, 0..) |o, *index, k| {
                if (try point_in_body.classify(allocator, body, index, p, options, diag) != .inside) continue;
                if (best) |b| {
                    const q = try shellPoint(allocator, body, o, diag) orelse continue;
                    if (try point_in_body.classify(allocator, body, &indexes[b], q, options, diag) != .inside) continue;
                }
                best = k;
            }
            if (best) |b| owner[@backingInt(v)] = @backingInt(outers.items[b]);
        }
        return .{ .owner = owner };
    }

    pub fn deinit(self: *Solids, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        self.* = undefined;
    }

    /// Whether shells `s` and `t` are of one solid.
    pub fn same(self: *const Solids, s: types.ShellIndex, t: types.ShellIndex) bool {
        const a = self.owner[@backingInt(s)];
        return a != NO_SOLID and a == self.owner[@backingInt(t)];
    }
};

/// Where a body touches itself inside one solid, the shell it is in.
pub const Pinch = union(enum) {
    /// A vertex whose faces about it are two fans of one solid.
    fans: types.ShellIndex,
    /// Two edges between one pair of vertices along one curve, of one solid.
    copies: types.ShellIndex,
};

/// Where `body` touches itself inside one solid (`solids`), null when nowhere: a vertex
/// whose faces about it are two fans of one solid (`condition.fans`: one shell through a
/// point or along a line twice, two voids sharing a corner), or two edges between one pair
/// of vertices along one curve (both straight, or one curve record over one range: a sewn
/// edge's copies), of one solid (a pocket meeting the face it was cut from along an edge; a
/// void's edge on its outer shell's face; a sheet's hole touching its side, swept). What
/// one solid cannot hold (ISO 10303-42: STEP's brep_with_voids holds a void apart from its
/// outer shell and every other), whatever made it; solids touching each other so are not
/// a pinch. One rule for the boolean, the sweeps and the fuzzers' oracle.
pub fn pinchOf(allocator: std.mem.Allocator, body: *const Body, solids: *const Solids, diag: *Diagnostics) Error!?Pinch {
    var fans: std.ArrayList(condition.Fan) = .empty;
    defer fans.deinit(allocator);
    condition.fans(allocator, body, &fans) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Corrupt => return corrupt(diag),
    };
    // The fans come by vertex
    var start: usize = 0;
    while (start < fans.items.len) {
        var end = start;
        while (end < fans.items.len and fans.items[end].vertex == fans.items[start].vertex) end += 1;
        for (fans.items[start..end], 0..) |x, i| for (fans.items[start + i + 1 .. end]) |y| {
            if (solids.same(x.shell, y.shell)) return .{ .fans = x.shell };
        };
        start = end;
    }
    // The edges by the vertices they join, each run compared within
    const Joined = struct { lo: u32, hi: u32, edge: u32 };
    var joined: std.ArrayList(Joined) = .empty;
    defer joined.deinit(allocator);
    for (body.edges.items, 0..) |e, i| {
        if (e.flags.tombstone or e.flags.degenerate or e.coedge == .none) continue;
        const a = @backingInt(e.start);
        const b = @backingInt(e.end);
        try joined.append(allocator, .{ .lo = @min(a, b), .hi = @max(a, b), .edge = @intCast(i) });
    }
    const ByEnds = struct {
        fn lessThan(_: void, x: Joined, y: Joined) bool {
            return x.lo < y.lo or (x.lo == y.lo and (x.hi < y.hi or (x.hi == y.hi and x.edge < y.edge)));
        }
    };
    std.mem.sort(Joined, joined.items, {}, ByEnds.lessThan);
    start = 0;
    while (start < joined.items.len) {
        var end = start + 1;
        while (end < joined.items.len and joined.items[end].lo == joined.items[start].lo and joined.items[end].hi == joined.items[start].hi) end += 1;
        for (joined.items[start..end], 0..) |x, i| for (joined.items[start + i + 1 .. end]) |y| {
            if (!alongOneCurve(body, x.edge, y.edge)) continue;
            const shell = edgeShell(body, x.edge);
            if (solids.same(shell, edgeShell(body, y.edge))) return .{ .copies = shell };
        };
        start = end;
    }
    return null;
}

/// Refuses `body` (`Degenerate`, `pinched`, the shell named) where it touches itself
/// inside one solid (`pinchOf`).
pub fn refusePinched(allocator: std.mem.Allocator, body: *const Body, solids: *const Solids, diag: *Diagnostics) Error!void {
    return switch ((try pinchOf(allocator, body, solids, diag)) orelse return) {
        .fans => |s| diag.fail(error.Degenerate, .{ .code = .pinched, .entity = .of(.shell, @backingInt(s)), .label = "a solid (its faces about a vertex in two fans)" }),
        .copies => |s| diag.fail(error.Degenerate, .{ .code = .pinched, .entity = .of(.shell, @backingInt(s)), .label = "a solid (two edges along one curve, inside it)" }),
    };
}

/// Whether edges `x` and `y`, between one pair of vertices, run along one curve: both
/// straight, or one curve record over one range (a circle's two halves between the same
/// two vertices are not).
fn alongOneCurve(body: *const Body, x: u32, y: u32) bool {
    const a = body.edge(types.EdgeIndex.of(x));
    const b = body.edge(types.EdgeIndex.of(y));
    if (a.curve.kind == .line and b.curve.kind == .line) return true;
    return a.curve.kind == b.curve.kind and a.curve.index == b.curve.index and a.t0 == b.t0 and a.t1 == b.t1;
}

/// The shell of edge `e`'s faces.
fn edgeShell(body: *const Body, e: u32) types.ShellIndex {
    return body.face(body.loop(body.coedge(body.edge(types.EdgeIndex.of(e)).coedge).loop).face).shell;
}

/// A point strictly inside one of shell `s`'s faces (`pointInside`), the first face's that
/// has one; null when none does.
fn shellPoint(allocator: std.mem.Allocator, body: *const Body, s: types.ShellIndex, diag: *Diagnostics) Error!?Vec3 {
    var faces = traverse.Faces.init(body, s);
    while (faces.next() catch return corrupt(diag)) |f| {
        if (try pointInside(allocator, body, f, diag)) |p| return p;
    }
    return null;
}

/// A point strictly inside face `f`: a planar face with straight edges its clearest
/// centroid (`facePoint`); another the middle of its parameter box, when inside it; null
/// when neither gives one.
pub fn pointInside(allocator: std.mem.Allocator, body: *const Body, f: types.FaceIndex, diag: *Diagnostics) Error!?Vec3 {
    if (try facePoint(allocator, body, f, diag)) |p| return p;
    const face = body.face(f);
    const box = face.uv_box;
    if (box.isEmpty()) return null;
    const uv: Vec2 = .{ (box.min[0] + box.max[0]) / 2, (box.min[1] + box.max[1]) / 2 };
    const p = body.geometry.surface(face.surface).eval(uv[0], uv[1]);
    return if (try in_face.classify(body, f, p, uv, 0, diag) == .inside) p else null;
}

/// The first rule over every pair of faces whose boxes overlap, in order of their items.
fn facePairs(allocator: std.mem.Allocator, body: *const Body, index: *const index_mod.FaceIndex, solids: *const Solids, tol: Tolerance, options: diagnostics.Options, diag: *Diagnostics) Error!void {
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
        const shell_f = body.face(f).shell;
        const shell_g = body.face(g).shell;
        switch (relation) {
            .apart => {},
            .crossing => {
                const apart = shell_f != shell_g;
                // Two shells of one solid meet nowhere; two solids may touch
                if (apart and solids.same(shell_f, shell_g) and pieces.items.len > 0) return pinch(diag, shell_f, g);
                for (pieces.items) |piece| {
                    if (try onBoundaries(body, f, g, piece, apart, tol, diag)) continue;
                    // One shell touching itself (on a face's boundary, inside the other)
                    if (!apart and try touching(body, f, g, piece, tol, diag)) return pinch(diag, shell_f, g);
                    return diag.fail(error.NotValid, .{ .code = .faces_intersect, .entity = .of(.face, @backingInt(f)), .measured = @floatFromInt(@backingInt(g)) });
                }
            },
            .coplanar => if (try coplanarOverlap(allocator, body, f, g, tol, diag)) return diag.fail(error.NotValid, .{ .code = .faces_intersect, .entity = .of(.face, @backingInt(f)), .measured = @floatFromInt(@backingInt(g)) }),
        }
    }
}

/// Whether every point of `piece` (its ends and middle) lies on both faces' boundaries
/// (`nearBoundary`, an end that is a vertex reaching by its own gap too): the faces touch
/// there, neither passing into the other. A point where faces of two shells touch needs
/// only one's boundary: solids touching at a point (a corner on a face) split no face, so no
/// edge or vertex of the face records it (a vertex loop could, once the mesher and the STEP
/// writer take one); within one shell it would be a pinch.
fn onBoundaries(body: *const Body, f: types.FaceIndex, g: types.FaceIndex, piece: Piece, apart: bool, tol: Tolerance, diag: *Diagnostics) Error!bool {
    if (piece.isPoint() and apart) {
        const own = try gapAt(body, f, g, piece.a, diag);
        return try nearBoundary(body, f, piece.a, own, tol, diag) or try nearBoundary(body, g, piece.a, own, tol, diag);
    }
    const points = [3]Vec3{ piece.a, vec.lerp(piece.a, piece.b, 0.5), piece.b };
    const count: usize = if (piece.isPoint()) 1 else 3;
    for (points[0..count]) |p| {
        const own = try gapAt(body, f, g, p, diag);
        if (!try nearBoundary(body, f, p, own, tol, diag) or !try nearBoundary(body, g, p, own, tol, diag)) return false;
    }
    return true;
}

/// A solid touching itself where shell `s`'s face meets face `g` (`pinched`, by design).
fn pinch(diag: *Diagnostics, s: types.ShellIndex, g: types.FaceIndex) Error {
    return diag.fail(error.Degenerate, .{ .code = .pinched, .entity = .of(.shell, @backingInt(s)), .label = "the body", .measured = @floatFromInt(@backingInt(g)) });
}

/// Whether every point of `piece` (its ends and middle) lies on face `f`'s boundary or on
/// `g`'s: the two faces touch there, neither passing through the other.
fn touching(body: *const Body, f: types.FaceIndex, g: types.FaceIndex, piece: Piece, tol: Tolerance, diag: *Diagnostics) Error!bool {
    const points = [3]Vec3{ piece.a, vec.lerp(piece.a, piece.b, 0.5), piece.b };
    const count: usize = if (piece.isPoint()) 1 else 3;
    for (points[0..count]) |p| {
        const own = try gapAt(body, f, g, p, diag);
        if (!try nearBoundary(body, f, p, own, tol, diag) and !try nearBoundary(body, g, p, own, tol, diag)) return false;
    }
    return true;
}

/// The largest gap of a vertex of face `f` or `g` at `p` exactly (a piece's end found at an
/// edge's end is that vertex's own point), 0 where no vertex is: the point's own reach, as
/// two tolerant things touch within the sum of their tolerances (OCCT's vertex and edge
/// tolerances). The solids fuzzer (2026-11-14): a merged vertex with a gap of 9.75e-5 on a
/// box's front, its edge to the box's corner lying in the box's left face's plane by that
/// gap, was 2.05e-4 from that face's edges at a tolerance of 2e-4.
fn gapAt(body: *const Body, f: types.FaceIndex, g: types.FaceIndex, p: Vec3, diag: *Diagnostics) Error!f64 {
    var gap: f64 = 0;
    for ([_]types.FaceIndex{ f, g }) |face| {
        var loops = traverse.Loops.init(body, face);
        while (loops.next() catch return corrupt(diag)) |l| {
            const lone = body.loop(l).vertex;
            if (lone != .none and samePlace(body.point(lone), p)) gap = @max(gap, body.vertex(lone).gap);
            var it = traverse.Coedges.init(body, l);
            while (it.next() catch return corrupt(diag)) |c| {
                const v = body.coedgeStart(c);
                if (samePlace(body.point(v), p)) gap = @max(gap, body.vertex(v).gap);
            }
        }
    }
    return gap;
}

fn samePlace(a: Vec3, b: Vec3) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

/// Whether `p`, reaching `own` beyond the tolerance itself (its gap, when it is a vertex),
/// lies on face `f`'s boundary: within an edge's reach of it, the intersection tolerance
/// and its ends' gaps (`planar_faces.edgeReach`, the reach by which the piece's ends were
/// found where an edge lies in the other face's plane), or within the tolerance and its gap
/// of a lone vertex. With the tolerance alone, an end found by an edge lying in the plane
/// through a merged vertex's gap was "off" the other face's boundary (the solids fuzzer,
/// 2026-11-14: a box and a plate 1.95e-4 apart at an intersection tolerance of 2e-4, a
/// vertex merged between them with a gap of 9.75e-5).
fn nearBoundary(body: *const Body, f: types.FaceIndex, p: Vec3, own: f64, tol: Tolerance, diag: *Diagnostics) Error!bool {
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        const lone = body.loop(l).vertex;
        if (lone != .none and vec.distance(body.point(lone), p) <= tol.xsect + body.vertex(lone).gap + own) return true;
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const e = body.coedge(c).edge;
            if (in_face.edgeDistance(body, e, p) <= planar_faces.edgeReach(body, body.edge(e), tol) + own) return true;
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
    var triangles = try FaceTriangles.build(allocator, body, shells.items, diag);
    defer triangles.deinit(allocator);
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
                const w = try winding(body, &triangles, t, p, diag);
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
/// number sums by their triangulations, `FaceTriangles`).
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
/// a fraction on or near it), each face's by its triangulation (`triangles`, built for
/// `s`'s faces). Straight planar faces only (`straightPlanar`).
pub fn winding(body: *const Body, triangles: *const FaceTriangles, s: types.ShellIndex, p: Vec3, diag: *Diagnostics) Error!f64 {
    var total: f64 = 0;
    var faces = traverse.Faces.init(body, s);
    while (faces.next() catch return corrupt(diag)) |f| {
        for (triangles.of[@backingInt(f)]) |corners| {
            total += solidAngle(vec.sub(body.point(corners[0]), p), vec.sub(body.point(corners[1]), p), vec.sub(body.point(corners[2]), p));
        }
    }
    return total / FOUR_PI;
}

/// Each face's own triangulation, as its vertices in its loops' sense: what the winding
/// number sums solid angles over. Not a fan from one corner, which for a face that is not
/// convex overlaps itself outside the face: the overlapping triangles' solid angles cancel
/// only by their signs, and for a point in the face's plane those are the rounding's of
/// each one's height (the 10K fuzz session, 2026-11-14: a sample in the notch of a
/// coplanar face of another shell wound 1, a whole number, and the shells were said to
/// overlap). A point in the plane outside the face lies in none of these triangles, each
/// of which subtends nothing there; on the face, the shell winds a half.
pub const FaceTriangles = struct {
    /// By face index: empty for a face of no shell built for.
    of: [][]const [3]types.VertexIndex,

    /// The triangulations of the faces of `shells` (each planar with straight edges); a
    /// face the triangulator refuses fails `NotValid` with its finding, the face named.
    pub fn build(allocator: std.mem.Allocator, body: *const Body, shells: []const types.ShellIndex, diag: *Diagnostics) Error!FaceTriangles {
        const of = try allocator.alloc([]const [3]types.VertexIndex, body.faces.items.len);
        @memset(of, &.{});
        var self: FaceTriangles = .{ .of = of };
        errdefer self.deinit(allocator);
        var rings: Rings = .{};
        defer rings.deinit(allocator);
        for (shells) |s| {
            var faces = traverse.Faces.init(body, s);
            while (faces.next() catch return corrupt(diag)) |f| of[@backingInt(f)] = try rings.triangles(allocator, body, f, diag);
        }
        return self;
    }

    pub fn deinit(self: *FaceTriangles, allocator: std.mem.Allocator) void {
        for (self.of) |corners| allocator.free(corners);
        allocator.free(self.of);
        self.* = undefined;
    }

    /// One face's triangulation (planar with straight edges), owned by `allocator`, as
    /// `build` makes each: the corners in the loops' sense, spurs left out.
    pub fn ofFace(allocator: std.mem.Allocator, body: *const Body, f: types.FaceIndex, diag: *Diagnostics) Error![]const [3]types.VertexIndex {
        var rings: Rings = .{};
        defer rings.deinit(allocator);
        return rings.triangles(allocator, body, f, diag);
    }

    /// One face's rings in its plane, kept between faces.
    const Rings = struct {
        ring: std.ArrayList(u32) = .empty,
        points: std.ArrayList(Vec2) = .empty,
        vertices: std.ArrayList(types.VertexIndex) = .empty,
        starts: std.ArrayList(u32) = .empty,

        fn deinit(self: *Rings, allocator: std.mem.Allocator) void {
            self.ring.deinit(allocator);
            self.points.deinit(allocator);
            self.vertices.deinit(allocator);
            self.starts.deinit(allocator);
        }

        fn triangles(self: *Rings, allocator: std.mem.Allocator, body: *const Body, f: types.FaceIndex, diag: *Diagnostics) Error![]const [3]types.VertexIndex {
            const frame = planar_faces.frameOf(body, f) orelse return corrupt(diag);
            self.points.clearRetainingCapacity();
            self.vertices.clearRetainingCapacity();
            self.starts.clearRetainingCapacity();
            var loops = traverse.Loops.init(body, f);
            while (loops.next() catch return corrupt(diag)) |l| {
                self.ring.clearRetainingCapacity();
                var it = traverse.Coedges.init(body, l);
                while (it.next() catch return corrupt(diag)) |c| try self.ring.append(allocator, @backingInt(body.coedgeStart(c)));
                // A spur (the loop out to a vertex and back, where another solid touches the
                // face along a line) bounds nothing, nor does a loop of one vertex
                withoutSpurs(&self.ring);
                if (self.ring.items.len == 0) continue;
                try self.starts.append(allocator, @intCast(self.points.items.len));
                for (self.ring.items) |i| {
                    const v = types.VertexIndex.of(i);
                    try self.points.append(allocator, planar_faces.flat(frame, body.point(v)));
                    try self.vertices.append(allocator, v);
                }
            }
            if (self.starts.items.len == 0) return &.{};
            try self.starts.append(allocator, @intCast(self.points.items.len));
            // The triangulator takes the outer ring counter-clockwise: mirrored when it runs
            // the other way, so the triangles run in the loops' sense either way
            const points = self.points.items;
            if (ringArea(points[self.starts.items[0]..self.starts.items[1]]) < 0) for (points) |*q| {
                q[1] = -q[1];
            };
            var scratch = Diagnostics.init(allocator);
            defer scratch.deinit();
            const made = triangulate.triangulate(allocator, .{ .points = points, .starts = self.starts.items }, &scratch) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    var finding = scratch.first().?;
                    finding.entity = .of(.face, @backingInt(f));
                    return diag.fail(error.NotValid, finding);
                },
            };
            defer allocator.free(made);
            const out = try allocator.alloc([3]types.VertexIndex, made.len);
            for (out, made) |*corners, t| corners.* = .{ self.vertices.items[t[0]], self.vertices.items[t[1]], self.vertices.items[t[2]] };
            return out;
        }
    };
};

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

/// Points strictly inside the polygon, appended to `out`: the centroids of its
/// triangulation's triangles, the furthest from the rings' edges and `avoid` first; then, in
/// that order, each triangle's incenter (the point furthest from its sides), the centroids
/// of the three triangles each centroid makes with its triangle's sides, and the points
/// halfway from each centroid to its triangle's corners: each triangle covered at its middle
/// and toward each corner. A caller whose first point lands where it can decide nothing (on
/// another body's boundary) tries the next, since a region's every interior point has its
/// class: a single triangle's centroid, on the corner of a solid touching the face there,
/// was once the only candidate (the solids fuzzer, 2026-11-13); a thin triangle's centroid
/// lies a third of the way across it, nearer one side than its incenter (the gap draws,
/// 2026-11-14: a plane's section of a flat tetrahedron 4.2e-5 across, its centroid the zone
/// from a face it crosses at 45°); and a face 3e-4 rad off another body's face, its edge
/// within the tolerance over it, lies within the zone of it but toward its far corner (the
/// same day). None when the triangulator refuses the rings.
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
    // In the rings' own coordinates, where `avoid` is given
    const Candidate = struct { corners: [3]Vec2, at: Vec2, clearance: f64 };
    var found: std.ArrayList(Candidate) = .empty;
    defer found.deinit(allocator);
    for (triangles) |t| {
        var corners: [3]Vec2 = undefined;
        for (&corners, t) |*corner, k| corner.* = points[k];
        if (vec.cross2(vec.sub2(corners[1], corners[0]), vec.sub2(corners[2], corners[0])) <= 0) continue;
        if (mirror) for (&corners) |*corner| {
            corner[1] = -corner[1];
        };
        const g = centroidOf(corners[0], corners[1], corners[2]);
        var clearance = std.math.inf(f64);
        for (0..starts.len - 1) |r| {
            const ring = points[starts[r]..starts[r + 1]];
            for (ring, 0..) |p, i| {
                const u: Vec2 = .{ p[0], if (mirror) -p[1] else p[1] };
                const w0 = ring[(i + 1) % ring.len];
                const w: Vec2 = .{ w0[0], if (mirror) -w0[1] else w0[1] };
                clearance = @min(clearance, segmentDistance(g, u, w));
            }
        }
        for (avoid) |segment| clearance = @min(clearance, segmentDistance(g, segment[0], segment[1]));
        try found.append(allocator, .{ .corners = corners, .at = g, .clearance = clearance });
    }
    // The clearest centroid first, ties in the triangulation's order; then, in that order,
    // the centroids of the three triangles each centroid makes with its triangle's sides
    // (a second chance, not worth a clearance each: a 1000-sided face's every sample
    // measured against its every edge doubled a boolean's time, 2026-11-13)
    const Order = struct {
        fn lessThan(_: void, x: Candidate, y: Candidate) bool {
            return x.clearance > y.clearance;
        }
    };
    std.mem.sort(Candidate, found.items, {}, Order.lessThan);
    for (found.items) |c| try out.append(allocator, frame.toWorld(.{ c.at[0], c.at[1], 0 }));
    for (found.items) |c| {
        const q = incenterOf(c.corners[0], c.corners[1], c.corners[2]);
        try out.append(allocator, frame.toWorld(.{ q[0], q[1], 0 }));
    }
    for (found.items) |c| {
        const k = c.corners;
        for ([_]Vec2{ centroidOf(k[0], k[1], c.at), centroidOf(k[1], k[2], c.at), centroidOf(k[2], k[0], c.at) }) |q| try out.append(allocator, frame.toWorld(.{ q[0], q[1], 0 }));
    }
    for (found.items) |c| {
        for (c.corners) |corner| {
            const q = vec.lerp2(c.at, corner, 0.5);
            try out.append(allocator, frame.toWorld(.{ q[0], q[1], 0 }));
        }
    }
}

/// The point of triangle `a b c` furthest from its sides: its corners weighted by the
/// lengths of the sides facing them.
fn incenterOf(a: Vec2, b: Vec2, c: Vec2) Vec2 {
    const la = vec.distance2(b, c);
    const lb = vec.distance2(c, a);
    const lc = vec.distance2(a, b);
    const sum = la + lb + lc;
    return .{ (la * a[0] + lb * b[0] + lc * c[0]) / sum, (la * a[1] + lb * b[1] + lc * c[1]) / sum };
}

fn centroidOf(a: Vec2, b: Vec2, c: Vec2) Vec2 {
    return .{ (a[0] + b[0] + c[0]) / 3.0, (a[1] + b[1] + c[1]) / 3.0 };
}

/// The distance from `p` to the segment from `a` to `b`.
fn segmentDistance(p: Vec2, a: Vec2, b: Vec2) f64 {
    const d = vec.sub2(b, a);
    const len_sq = vec.lengthSq2(d);
    const s = if (len_sq == 0) 0 else std.math.clamp(vec.dot2(vec.sub2(p, a), d) / len_sq, 0, 1);
    return vec.distance2(p, vec.addScaled2(a, d, s));
}

/// The cycle `ring` (vertices) with every spur taken out: wherever it runs `a b a` (out to
/// `b` and back), `b` and one `a` go, until none is left; empty when fewer than three are.
/// A spur bounds no area, and the triangulator, rightly, takes it for a ring touching
/// itself (the classifier's samples and the winding number's triangles take them out).
pub fn withoutSpurs(ring: *std.ArrayList(u32)) void {
    var changed = true;
    while (changed and ring.items.len >= 3) {
        changed = false;
        const n = ring.items.len;
        for (0..n) |k| {
            const before = ring.items[(k + n - 1) % n];
            const after = ring.items[(k + 1) % n];
            if (before != after) continue;
            // Drop the tip and the vertex after it (one of the two visits of `a`)
            const first = @min(k, (k + 1) % n);
            const second = @max(k, (k + 1) % n);
            _ = ring.orderedRemove(second);
            _ = ring.orderedRemove(first);
            changed = true;
            break;
        }
    }
    if (ring.items.len < 3) ring.clearRetainingCapacity();
}

fn ringArea(ring: []const Vec2) f64 {
    var area: f64 = 0;
    for (ring, 0..) |p, i| area += vec.cross2(p, ring[(i + 1) % ring.len]);
    return area;
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
