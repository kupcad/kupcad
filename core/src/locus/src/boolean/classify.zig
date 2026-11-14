//! The boolean's third phase (docs/architecture.md §7.4 step 4, KNOWLEDGE §7; Hoffmann
//! p.76–80, OCCT's `BRepClass3d_SClassifier`): each fragment classified once against the
//! other operand, at a point strictly inside it off the other's boundary (its
//! triangulation's clearest centroid, else its incenters and points toward its corners,
//! `overlap.interiorPoints`: a fragment's every interior point has its class). A fragment
//! of a face lying in one plane with faces of the other operand is decided first by those:
//! a fragment of one of them over the same pieces between merged vertices is its twin
//! (OCCT's same-domain faces, splits with identical edge sets; architecture §7.4), the same
//! domain, `on_same` when their outward normals agree and `on_opposite` when they are
//! opposed, never by a ray; one with no twin that its samples put inside a partner face is
//! the two imprints disagreeing, refused. The others are inside or outside the other
//! operand by `query/point_in_body.zig`'s rays, one for each connected component of them
//! (contagion, research/truck.md §3) and a second that must agree. A fragment with no
//! candidate off the other operand's boundary takes its side from the faces about a piece
//! of its boundary lying on the other's (`byDihedral`, OCCT's IsInternalFace); one with
//! none is a contradiction of the paves (`unclassified`), refused.

const std = @import("std");
const vec = @import("../math/vec.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const in_face = @import("../query/in_face.zig");
const index_mod = @import("../query/index.zig");
const point_in_body = @import("../query/point_in_body.zig");
const overlap = @import("../query/overlap.zig");
const planar_faces = @import("../intersect/planar_faces.zig");
const pave = @import("pave.zig");
const imprint = @import("imprint.zig");
const Paves = pave.Paves;
const Fragments = imprint.Fragments;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

pub const Class = enum {
    inside,
    outside,
    /// Lying on a face of the other operand that faces the same way.
    on_same,
    /// Lying on a face of the other operand that faces the other way.
    on_opposite,
};

/// A fragment's class, and for one lying on a face of the other operand, that face.
pub const Classified = struct {
    class: Class,
    /// The other operand's face a coincident fragment lies on, `NONE` for another.
    partner: u32 = NONE,
};

pub const NONE: u32 = std.math.maxInt(u32);

/// What classification did, for the result report: the rays it cast, the fragments a
/// component's ray decided without one of their own, and the components whose second ray
/// was cast to check the first's (each agreeing, or the boolean refused).
pub const Stats = struct {
    rays: u32 = 0,
    by_contagion: u32 = 0,
    checks: u32 = 0,
};

/// Each fragment's class, by index; owned by `allocator`. A fragment lying in one plane
/// with a face of the other operand is decided by their normals. The rest are classified
/// by contagion (research/truck.md §3): fragments of one operand sharing an edge piece the
/// other operand touches nowhere (neither end of it on the other operand, as the paves
/// decided: every place the other's boundary meets a piece is a merged vertex on it) lie on
/// one side of the other, so a connected component of them takes its class from one ray,
/// cast from its first fragment; a second ray, from its second fragment, must agree (the
/// report counts these checks), and a component of one fragment is that fragment's ray.
/// Without `contagion` every fragment is a component of its own (each its own ray).
pub fn run(allocator: std.mem.Allocator, paves: *const Paves, fragments: *const Fragments, options: diagnostics.Options, contagion: bool, diag: *Diagnostics, stats: *Stats) Error![]Classified {
    var indexes: [2]index_mod.FaceIndex = undefined;
    indexes[0] = try index_mod.FaceIndex.build(allocator, paves.operands[0], diag);
    defer indexes[0].deinit(allocator);
    indexes[1] = try index_mod.FaceIndex.build(allocator, paves.operands[1], diag);
    defer indexes[1].deinit(allocator);
    const n = fragments.items.items.len;
    const classes = try allocator.alloc(Classified, n);
    errdefer allocator.free(classes);
    const decided = try allocator.alloc(bool, n);
    defer allocator.free(decided);
    @memset(decided, false);
    var partners: std.ArrayList(u32) = .empty;
    defer partners.deinit(allocator);
    var samples: std.ArrayList(Vec3) = .empty;
    defer samples.deinit(allocator);

    // Every fragment's pieces, sorted: a fragment of the other operand over the same pieces
    // between merged vertices is its twin, the same region within the tolerance whatever
    // planes the two faces lie in (OCCT's same-domain faces, by their edges): a strip of a
    // face in the band where another face rising at 26.6° stays within the tolerance of it
    // was imprinted alike on both, and no sample of it was clear of the other (the 10K fuzz
    // session, 2026-11-14)
    var pieces: std.ArrayList([2]u32) = .empty;
    defer pieces.deinit(allocator);
    const ranges = try allocator.alloc([2]u32, n);
    defer allocator.free(ranges);
    for (ranges, 0..) |*range, i| {
        const start: u32 = @intCast(pieces.items.len);
        try piecesOf(allocator, fragments, i, &pieces);
        range.* = .{ start, @intCast(pieces.items.len) };
    }
    const twin_of = try twins(allocator, fragments, pieces.items, ranges);
    defer allocator.free(twin_of);
    for (fragments.items.items, 0..) |fragment, i| {
        try options.checkCancel();
        const body = paves.operands[fragment.operand];
        const f = types.FaceIndex.of(fragment.face);
        if (twin_of[i] != NONE) {
            const g = fragments.items.items[twin_of[i]].face;
            const other_body = paves.operands[1 - fragment.operand];
            const n_f = in_face.outwardNormal(body, f, .{ 0, 0 });
            const n_g = in_face.outwardNormal(other_body, types.FaceIndex.of(g), .{ 0, 0 });
            classes[i] = .{ .class = if (vec.dot(n_f, n_g) > 0) .on_same else .on_opposite, .partner = g };
            decided[i] = true;
            continue;
        }
        // No twin, of a face in one plane with faces of the other: a fragment outside its
        // partners, which a ray classifies, unless its samples put it inside one, where the
        // other imprint has no region
        try paves.coplanarWith(fragment.operand, fragment.face, &partners);
        if (partners.items.len == 0) continue;
        try samplesOf(allocator, paves, fragments, i, &samples, diag);
        if (try sameDomain(paves, body, f, 1 - fragment.operand, samples.items, partners.items, diag) != null)
            return diag.fail(error.IntersectionFailed, .{ .code = .imprint_unmatched, .entity = .of(.face, fragment.face), .label = "a fragment of a face in one plane with the other operand's, inside one of them, with no fragment of it over the same pieces: the two imprints disagree" });
    }

    // The others' components, across the pieces the other operand touches nowhere
    const parent = try allocator.alloc(u32, n);
    defer allocator.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    if (contagion) try joinComponents(allocator, paves, fragments, decided, parent);

    // One ray a component, a second to check it, the rest by contagion
    const NO_CLASS: u8 = std.math.maxInt(u8);
    const class_of = try allocator.alloc(u8, n);
    defer allocator.free(class_of);
    @memset(class_of, NO_CLASS);
    const checked = try allocator.alloc(bool, n);
    defer allocator.free(checked);
    @memset(checked, false);
    for (fragments.items.items, 0..) |fragment, i| {
        if (decided[i]) continue;
        try options.checkCancel();
        const root = find(parent, @intCast(i));
        classes[i].partner = NONE;
        if (class_of[root] != NO_CLASS and checked[root]) {
            classes[i].class = @fromBackingInt(@intCast(class_of[root]));
            stats.by_contagion += 1;
            continue;
        }
        try samplesOf(allocator, paves, fragments, i, &samples, diag);
        const class = (try byRay(allocator, paves, &indexes, fragment, samples.items, options, diag)) orelse
            (try byDihedral(paves, fragments, i, diag)) orelse
            return diag.fail(error.IntersectionFailed, .{ .code = .unclassified, .entity = .of(.face, fragment.face), .label = if (fragment.operand == 0) "a face of the first operand, classified against the second" else "a face of the second operand, classified against the first" });
        stats.rays += 1;
        classes[i].class = class;
        if (class_of[root] == NO_CLASS) {
            class_of[root] = @backingInt(class);
            continue;
        }
        // The component's second ray: the consistency check
        stats.checks += 1;
        checked[root] = true;
        if (@backingInt(class) != class_of[root]) return diag.fail(error.IntersectionFailed, .{ .code = .unclassified, .entity = .of(.face, fragment.face), .label = "a fragment whose ray disagrees with the first ray of its component (fragments joined across pieces the other operand does not touch)" });
    }
    return classes;
}

/// Fragment `i`'s samples into `out`; a fragment with no area is refused.
fn samplesOf(allocator: std.mem.Allocator, paves: *const Paves, fragments: *const Fragments, i: usize, out: *std.ArrayList(Vec3), diag: *Diagnostics) Error!void {
    out.clearRetainingCapacity();
    try sample(allocator, paves, fragments, i, out);
    if (out.items.len == 0) return diag.fail(error.Degenerate, .{ .code = .unclassified, .entity = .of(.face, fragments.items.items[i].face), .label = "a piece of a face with no area" });
}

/// Inside or outside the other operand, by rays from the first of `samples` off its
/// boundary (in a sliver one tolerance wide the clearest sample is within the zone of the
/// other's face that bounds it, and the next is not; 2026-11-13); null when every sample
/// lies on it.
fn byRay(allocator: std.mem.Allocator, paves: *const Paves, indexes: *const [2]index_mod.FaceIndex, fragment: imprint.Fragment, samples: []const Vec3, options: diagnostics.Options, diag: *Diagnostics) Error!?Class {
    const other = 1 - fragment.operand;
    for (samples) |p| {
        switch (try point_in_body.classify(allocator, paves.operands[other], &indexes[other], p, options, diag)) {
            .inside => return .inside,
            .outside => return .outside,
            .boundary => continue,
        }
    }
    return null;
}

/// Fragment `i`'s side of the other operand when no sample of it is clear of the other's
/// boundary, by the faces about a piece of its boundary lying on the other's, as OCCT's
/// `BOPTools_AlgoTools::IsInternalFace` takes a split face's state from the dihedral at a
/// section edge (Leo, 2026-11-14): the direction from the piece into the fragment (square
/// to it in the fragment's plane, the loop having the fragment on its left) against the
/// other's face the piece is a section with, behind which is inside, or against the wedge
/// of material between the other's two faces along the edge the piece is a piece of.
/// Width plays no part: a strip 2.5e-5 wide under a face rising from its section at 26.6°
/// has no point farther than 1.1e-5 from it, within the zone that `point_in_body` takes
/// for on the boundary (the 10K fuzz session). Null when no piece decides (none lies on
/// the other, or the faces there are in one plane within the angular tolerance) or two
/// pieces disagree.
fn byDihedral(paves: *const Paves, fragments: *const Fragments, i: usize, diag: *Diagnostics) Error!?Class {
    const fragment = fragments.items.items[i];
    const normal = in_face.outwardNormal(paves.operands[fragment.operand], types.FaceIndex.of(fragment.face), .{ 0, 0 });
    var found: ?Class = null;
    for (fragments.loopsOf(i)) |loop| {
        const vertices = fragments.loopVertices(loop);
        for (vertices, 0..) |x, k| {
            const y = vertices[(k + 1) % vertices.len];
            const into = vec.normalized(vec.cross(normal, vec.sub(paves.point(y), paves.point(x)))) orelse continue;
            const class = (try pieceSide(paves, 1 - fragment.operand, x, y, normal, into, diag)) orelse continue;
            if (found) |c| {
                if (c != class) return null;
            } else found = class;
        }
    }
    return found;
}

/// The side of operand `other` that direction `into` leaves the piece from merged vertex
/// `x` to `y` towards, in a face of normal `normal`: by the material between the two faces
/// of `other`'s edge the piece is a piece of (behind both at a convex edge, behind either
/// at a concave one), else by the face of `other` it is a section with; null for a piece
/// on neither, or a face there in one plane with the fragment's.
fn pieceSide(paves: *const Paves, other: u1, x: u32, y: u32, normal: Vec3, into: Vec3, diag: *Diagnostics) Error!?Class {
    const body = paves.operands[other];
    const angle = paves.tol.angle;
    for (paves.edge_paves[other], 0..) |list, e| {
        if (list.items.len < 2) continue;
        for (list.items[0 .. list.items.len - 1], list.items[1..]) |u, w| {
            if (!((u.vertex == x and w.vertex == y) or (u.vertex == y and w.vertex == x))) continue;
            const edge = body.edge(types.EdgeIndex.of(e));
            const line = switch (body.geometry.curve(edge.curve)) {
                .line => |l| l,
                else => return null,
            };
            const first = edge.coedge;
            const second = body.coedge(first).partner;
            if (first == .none or second == .none) return corrupt(diag);
            const n1 = in_face.outwardNormal(body, body.loop(body.coedge(first).loop).face, .{ 0, 0 });
            const n2 = in_face.outwardNormal(body, body.loop(body.coedge(second).loop).face, .{ 0, 0 });
            if (inOnePlane(normal, n1, angle) or inOnePlane(normal, n2, angle)) return null;
            // Convex when the second face turns behind the first along the first's loop
            const along = vec.scale(line.d, if (body.coedge(first).same_sense) 1 else -1);
            const convex = vec.dot(vec.cross(n1, n2), along) > 0;
            const behind_first = vec.dot(into, n1) < 0;
            const behind_second = vec.dot(into, n2) < 0;
            const inside = if (convex) behind_first and behind_second else behind_first or behind_second;
            return if (inside) .inside else .outside;
        }
    }
    const segment: [2]u32 = .{ @min(x, y), @max(x, y) };
    for (paves.sections[other], 0..) |list, g| {
        for (list.items) |s| {
            if (s[0] != segment[0] or s[1] != segment[1]) continue;
            const n_g = in_face.outwardNormal(body, types.FaceIndex.of(g), .{ 0, 0 });
            if (inOnePlane(normal, n_g, angle)) return null;
            return if (vec.dot(into, n_g) < 0) .inside else .outside;
        }
    }
    return null;
}

/// Whether unit normals `a` and `b` are of one plane within the angular tolerance `angle`
/// (`1 − cos`), either way round.
fn inOnePlane(a: Vec3, b: Vec3, angle: f64) bool {
    return 1 - @abs(vec.dot(a, b)) <= angle;
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the other operand" });
}

/// Joins in `parent` the undecided fragments of one operand that share an edge piece
/// (consecutive merged vertices of their loops, run opposite ways) whose ends neither lies
/// on the other operand.
fn joinComponents(allocator: std.mem.Allocator, paves: *const Paves, fragments: *const Fragments, decided: []const bool, parent: []u32) Error!void {
    // Which operands each merged vertex lies on (its faces' or its own)
    const on = try allocator.alloc(u2, paves.points.items.len);
    defer allocator.free(on);
    @memset(on, 0);
    for (paves.incidences.items) |inc| on[inc.vertex] |= @as(u2, 1) << inc.face.operand;
    for (paves.owners.items, on) |owners, *o| o.* |= owners;
    const Key = struct { operand: u1, lo: u32, hi: u32 };
    var first_use: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    defer first_use.deinit(allocator);
    for (fragments.items.items, 0..) |fragment, i| {
        if (decided[i]) continue;
        const other_bit = @as(u2, 1) << (1 - fragment.operand);
        for (fragments.loopsOf(i)) |loop| {
            const vertices = fragments.loopVertices(loop);
            for (vertices, 0..) |u, k| {
                const w = vertices[(k + 1) % vertices.len];
                if (u == w or (on[u] | on[w]) & other_bit != 0) continue;
                const entry = try first_use.getOrPut(allocator, .{ .operand = fragment.operand, .lo = @min(u, w), .hi = @max(u, w) });
                if (!entry.found_existing) {
                    entry.value_ptr.* = @intCast(i);
                    continue;
                }
                const j = entry.value_ptr.*;
                if (decided[j]) continue;
                // The smaller root wins: components are named by their first fragment
                const a = find(parent, @intCast(i));
                const b = find(parent, j);
                if (a != b) parent[@max(a, b)] = @min(a, b);
            }
        }
    }
}

fn find(parent: []u32, i: u32) u32 {
    var r = i;
    while (parent[r] != r) r = parent[r];
    // Path halving keeps later finds short
    var x = i;
    while (parent[x] != r) {
        const next = parent[x];
        parent[x] = r;
        x = next;
    }
    return r;
}

/// Each fragment's class by its shell, one point per shell classified against the other
/// operand (the containment table, §7.4 step 0: operands the paves found apart, each shell
/// wholly inside or outside the other). The point is a vertex of the shell's first face; on
/// the other's boundary it contradicts the paves (`unclassified`).
pub fn byShell(allocator: std.mem.Allocator, paves: *const Paves, fragments: *const Fragments, options: diagnostics.Options, diag: *Diagnostics, stats: *Stats) Error![]Classified {
    var indexes: [2]index_mod.FaceIndex = undefined;
    indexes[0] = try index_mod.FaceIndex.build(allocator, paves.operands[0], diag);
    defer indexes[0].deinit(allocator);
    indexes[1] = try index_mod.FaceIndex.build(allocator, paves.operands[1], diag);
    defer indexes[1].deinit(allocator);
    // Each operand's shells' classes, by shell index, decided once
    var decided: [2][]?Class = .{ &.{}, &.{} };
    defer for (decided) |d| allocator.free(d);
    for (0..2) |k| {
        decided[k] = try allocator.alloc(?Class, paves.operands[k].shells.items.len);
        @memset(decided[k], null);
    }
    const classes = try allocator.alloc(Classified, fragments.items.items.len);
    errdefer allocator.free(classes);
    for (fragments.items.items, classes, 0..) |fragment, *out, i| {
        const body = paves.operands[fragment.operand];
        const other = 1 - fragment.operand;
        const shell = @backingInt(body.face(types.FaceIndex.of(fragment.face)).shell);
        if (decided[fragment.operand][shell] == null) {
            try options.checkCancel();
            const loop = fragments.loopsOf(i)[0];
            const p = paves.point(fragments.loopVertices(loop)[0]);
            stats.rays += 1;
            decided[fragment.operand][shell] = switch (try point_in_body.classify(allocator, paves.operands[other], &indexes[other], p, options, diag)) {
                .inside => .inside,
                .outside => .outside,
                .boundary => return diag.fail(error.IntersectionFailed, .{ .code = .unclassified, .entity = .of(.face, fragment.face), .label = if (fragment.operand == 0) "a shell of the first operand, which the paves found apart from the second" else "a shell of the second operand, which the paves found apart from the first" }),
            };
        }
        out.* = .{ .class = decided[fragment.operand][shell].? };
    }
    return classes;
}

/// Coincident: inside a face of the other operand lying in this face's plane (`partners`),
/// facing the same way or the other; null when outside them all. The imprint cut the
/// fragment along those faces' boundaries, so it lies on one or off them all, whole: the
/// first sample on no partner's boundary decides (one on a boundary gives way to the
/// next), never a scan of every sample against every partner (a thousand-sided cap's
/// four thousand samples off its partner took most of a boolean's time, 2026-11-13).
/// Whether two fragments' sorted pieces are the same pieces (compared by their vertices:
/// `std.mem.eql` of arrays does not compile in the fuzzer's LLVM build).
/// Each fragment's twin (`NONE` for none): the one fragment of the other operand over the
/// same pieces (`ranges` into `pieces`, each fragment's sorted), when the pieces are one
/// fragment's of each operand.
fn twins(allocator: std.mem.Allocator, fragments: *const Fragments, pieces: []const [2]u32, ranges: []const [2]u32) Error![]u32 {
    const n = ranges.len;
    const twin_of = try allocator.alloc(u32, n);
    errdefer allocator.free(twin_of);
    @memset(twin_of, NONE);
    const order = try allocator.alloc(u32, n);
    defer allocator.free(order);
    for (order, 0..) |*x, i| x.* = @intCast(i);
    const ByPieces = struct {
        pieces: []const [2]u32,
        ranges: []const [2]u32,
        fn of(ctx: @This(), i: u32) []const [2]u32 {
            return ctx.pieces[ctx.ranges[i][0]..ctx.ranges[i][1]];
        }
        fn lessThan(ctx: @This(), x: u32, y: u32) bool {
            return switch (comparePieces(ctx.of(x), ctx.of(y))) {
                .lt => true,
                .gt => false,
                .eq => x < y,
            };
        }
    };
    const ctx: ByPieces = .{ .pieces = pieces, .ranges = ranges };
    std.mem.sort(u32, order, ctx, ByPieces.lessThan);
    var start: usize = 0;
    while (start < n) {
        var end = start + 1;
        while (end < n and comparePieces(ctx.of(order[start]), ctx.of(order[end])) == .eq) end += 1;
        defer start = end;
        if (end - start != 2) continue;
        const x = order[start];
        const y = order[start + 1];
        if (fragments.items.items[x].operand == fragments.items.items[y].operand) continue;
        twin_of[x] = y;
        twin_of[y] = x;
    }
    return twin_of;
}

/// Two fragments' sorted pieces in lexicographic order.
fn comparePieces(a: []const [2]u32, b: []const [2]u32) std.math.Order {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        if (x[0] != y[0]) return std.math.order(x[0], y[0]);
        if (x[1] != y[1]) return std.math.order(x[1], y[1]);
    }
    return std.math.order(a.len, b.len);
}

/// Fragment `i`'s pieces between merged vertices, each as its two vertices (the lesser
/// first), sorted, appended to `out`: its region by its edges, whichever way it runs.
fn piecesOf(allocator: std.mem.Allocator, fragments: *const Fragments, i: usize, out: *std.ArrayList([2]u32)) Error!void {
    const start = out.items.len;
    for (fragments.loopsOf(i)) |loop| {
        const vertices = fragments.loopVertices(loop);
        for (vertices, 0..) |v, k| {
            const w = vertices[(k + 1) % vertices.len];
            try out.append(allocator, .{ @min(v, w), @max(v, w) });
        }
    }
    const Less = struct {
        fn lessThan(_: void, x: [2]u32, y: [2]u32) bool {
            return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
        }
    };
    std.mem.sort([2]u32, out.items[start..], {}, Less.lessThan);
}

/// Whether some sample of a fragment lies inside one of `partners` (the old decision by
/// sampling, kept as the check that a fragment with no twin is no region of a partner).
fn sameDomain(paves: *const Paves, body: *const @import("../topology/body.zig").Body, f: types.FaceIndex, other: usize, samples: []const Vec3, partners: []const u32, diag: *Diagnostics) Error!?Classified {
    for (samples) |p| {
        var on_a_boundary = false;
        for (partners) |g| {
            const face_g = types.FaceIndex.of(g);
            switch (try planar_faces.place(paves.operands[other], face_g, p, paves.tol, diag)) {
                .outside => continue,
                .boundary => {
                    on_a_boundary = true;
                    continue;
                },
                .inside => {},
            }
            const n_f = in_face.outwardNormal(body, f, .{ 0, 0 });
            const n_g = in_face.outwardNormal(paves.operands[other], face_g, .{ 0, 0 });
            return .{ .class = if (vec.dot(n_f, n_g) > 0) .on_same else .on_opposite, .partner = g };
        }
        if (!on_a_boundary) return null;
    }
    return null;
}

/// Points strictly inside fragment `i` (`overlap.interiorPoints`: the centroids of its
/// triangles and of their thirds), the furthest from its edges first, into `out`; none
/// when it has no area. Its loops are triangulated without their spurs: a section segment
/// ending inside the face (the other operand touching it along a line from one side) is
/// an edge the loop runs there and back, which bounds no area and which the triangulator,
/// rightly, takes for a ring touching itself; the point keeps clear of it all the same, since the
/// other operand touches the face there (a centroid on the slit's tip was found on the
/// other's boundary, 2026-11-12).
fn sample(allocator: std.mem.Allocator, paves: *const Paves, fragments: *const Fragments, i: usize, out: *std.ArrayList(Vec3)) Error!void {
    const fragment = fragments.items.items[i];
    const frame = planar_faces.frameOf(paves.operands[fragment.operand], types.FaceIndex.of(fragment.face)).?;
    var points: std.ArrayList(Vec2) = .empty;
    defer points.deinit(allocator);
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(allocator);
    var ring: std.ArrayList(u32) = .empty;
    defer ring.deinit(allocator);
    // Every edge of the fragment, its spurs among them, for the point to keep clear of
    var edges: std.ArrayList([2]Vec2) = .empty;
    defer edges.deinit(allocator);
    for (fragments.loopsOf(i)) |loop| {
        const vertices = fragments.loopVertices(loop);
        for (vertices, 0..) |v, k| try edges.append(allocator, .{ planar_faces.flat(frame, paves.point(v)), planar_faces.flat(frame, paves.point(vertices[(k + 1) % vertices.len])) });
    }
    for (fragments.loopsOf(i)) |loop| {
        ring.clearRetainingCapacity();
        try ring.appendSlice(allocator, fragments.loopVertices(loop));
        overlap.withoutSpurs(&ring);
        if (ring.items.len < 3) continue;
        try starts.append(allocator, @intCast(points.items.len));
        for (ring.items) |v| try points.append(allocator, planar_faces.flat(frame, paves.point(v)));
    }
    if (starts.items.len == 0) return;
    try starts.append(allocator, @intCast(points.items.len));
    try overlap.interiorPoints(allocator, frame, points.items, starts.items, edges.items, out);
}
