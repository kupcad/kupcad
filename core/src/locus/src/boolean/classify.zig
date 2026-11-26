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
//! operand by their seams first (Hoffmann pp. 86–93: in and out are taken from the faces
//! that made a section and spread by adjacency; OCCT's builder takes a split face's state
//! by `IsInternalFace`, the solid classifier only for a face with no section): a fragment
//! with pieces of its boundary lying clearly on the other operand (along its edges, or
//! sections whose middles lie in their faces beyond reach of the faces' boundaries) is on
//! the side those pieces leave it toward (`bySeam`, the faces about each piece as the paves
//! made it), clear pieces disagreeing a contradiction (`unclassified`); a connected
//! component of fragments across pieces the other touches nowhere (contagion,
//! research/truck.md §3) is one side, its seams agreeing, and only a component with no
//! clear seam casts `query/point_in_body.zig`'s rays, one and a second that must agree. A
//! fragment no sample of which is clear of the other's boundary takes its side from a ray
//! from a corner of it the paves put on nothing of the other (`byCorner`; OCCT's
//! `ComputeState` takes a face's state from an edge not on the other solid before a point
//! inside it), else from all its pieces (within reach of a face's boundary, where they
//! may disagree); one with none is a contradiction of the paves (`unclassified`), refused.

const std = @import("std");
const vec = @import("../math/vec.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const in_face = @import("../query/in_face.zig");
const index_mod = @import("../query/index.zig");
const point_in_body = @import("../query/point_in_body.zig");
const overlap = @import("../query/overlap.zig");
const triangulate = @import("../mesh/triangulate.zig");
const planar_faces = @import("../intersect/planar_faces.zig");
const canonical = @import("../geometry/canonical.zig");
const traverse = @import("../topology/traverse.zig");
const incidence = @import("../geometry/incidence.zig");
const face_edges = @import("../query/face_edges.zig");
const pave = @import("pave.zig");
const imprint = @import("imprint.zig");
const Body = @import("../topology/body.zig").Body;
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
    /// A coincident fragment's twin, the other operand's fragment over the same pieces
    /// (`NONE` for another): the region's other copy.
    twin: u32 = NONE,
    /// Of a coincident fragment and its twin, whether it is the one the result keeps when
    /// it keeps the region (`select`): the first operand's when their faces are in one
    /// plane (D28 gives them one record, and either merges alike; the record's choice
    /// counts both copies, `Provenance.moved`), else the one whose face's plane holds the
    /// region more closely (`represents`).
    represents: bool = true,
};

pub const NONE: u32 = std.math.maxInt(u32);

/// How near nothing the part of a direction across a face is and shows no side of it: a
/// dot product of two unit vectors, to rounding (D27's ulps).
const SIDE_ROUNDING: f64 = canonical.AT_TOLERANCE_ULPS * std.math.floatEps(f64);

/// What classification did, for the result report: the rays it cast, the fragments a
/// component's ray decided without one of their own, and the components whose second ray
/// was cast to check the first's (each agreeing, or the boolean refused).
pub const Stats = struct {
    rays: u32 = 0,
    /// Fragments decided by their own seams, no ray.
    by_seam: u32 = 0,
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
    // Every record with no partner, no twin, until a fragment's class is decided
    @memset(classes, .{ .class = undefined });
    const decided = try allocator.alloc(bool, n);
    defer allocator.free(decided);
    @memset(decided, false);
    var partners: std.ArrayList(u32) = .empty;
    defer partners.deinit(allocator);
    var samples: std.ArrayList(Vec3) = .empty;
    defer samples.deinit(allocator);
    // A fragment's corners off the other operand (`byCorner`), apart from its samples, which
    // the last ray takes after them
    var corners: std.ArrayList(Vec3) = .empty;
    defer corners.deinit(allocator);

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
            try paves.coplanarWith(fragment.operand, fragment.face, &partners);
            const coplanar = std.mem.indexOfScalar(u32, partners.items, g) != null;
            classes[i] = .{ .class = if (vec.dot(n_f, n_g) > 0) .on_same else .on_opposite, .partner = g, .twin = twin_of[i], .represents = if (coplanar) fragment.operand == 0 else represents(paves, fragments, i, twin_of[i]) };
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
    const on = try operandsOn(allocator, paves);
    defer allocator.free(on);
    if (contagion) try joinComponents(allocator, fragments, on, decided, parent);

    // Each fragment's seams first: the side its pieces on the other operand leave it
    // toward, a component's agreeing (one side of the other, as contagion takes it)
    var seams = try Seams.build(allocator, paves);
    defer seams.deinit(allocator);
    const NO_CLASS: u8 = std.math.maxInt(u8);
    const seam_of = try allocator.alloc(u8, n);
    defer allocator.free(seam_of);
    @memset(seam_of, NO_CLASS);
    const class_of = try allocator.alloc(u8, n);
    defer allocator.free(class_of);
    @memset(class_of, NO_CLASS);
    const checked = try allocator.alloc(bool, n);
    defer allocator.free(checked);
    @memset(checked, false);
    for (fragments.items.items, 0..) |fragment, i| {
        if (decided[i]) continue;
        try options.checkCancel();
        const class = (try bySeam(allocator, paves, &seams, fragments, i, true, diag)) orelse continue;
        seam_of[i] = @backingInt(class);
        const root = find(parent, @intCast(i));
        if (class_of[root] == NO_CLASS) {
            class_of[root] = @backingInt(class);
            checked[root] = true;
        } else if (class_of[root] != @backingInt(class)) {
            return diag.fail(error.IntersectionFailed, .{ .code = .unclassified, .entity = .of(.face, fragment.face), .label = "a fragment whose seams put it on the other side of the other operand from a fragment it shares a piece with that the other touches nowhere" });
        }
    }

    // The rest: by their component's seams, else one ray a component and a second to check
    // it, the rest by contagion
    for (fragments.items.items, 0..) |fragment, i| {
        if (decided[i]) continue;
        try options.checkCancel();
        const root = find(parent, @intCast(i));
        if (seam_of[i] != NO_CLASS) {
            classes[i].class = @fromBackingInt(@intCast(seam_of[i]));
            stats.by_seam += 1;
            continue;
        }
        if (class_of[root] != NO_CLASS and checked[root]) {
            classes[i].class = @fromBackingInt(@intCast(class_of[root]));
            stats.by_contagion += 1;
            continue;
        }
        try samplesOf(allocator, paves, fragments, i, &samples, diag);
        // A ray from a sample clear of the other operand by the intersection tolerance, the
        // band within which the paves put points on its faces; else from a corner the paves
        // put on nothing of it; else by every seam (a fragment within the tolerance of the
        // other's boundary all over, its pieces on it agreeing, as OCCT's `IsInternalFace`
        // reads a split face by the wedge at its section edge); last a ray from a sample
        // clear by the zone (a sliver narrower than the tolerance beside a face of the
        // other, whose pieces say nothing)
        const zone = paves.operands[1 - fragment.operand].tol.zone;
        const class = (try byRay(allocator, paves, &indexes, fragment, samples.items, paves.tol.xsect, options, diag)) orelse
            (try byCorner(allocator, paves, &indexes, fragments, i, on, &corners, options, diag)) orelse
            (try bySeam(allocator, paves, &seams, fragments, i, false, diag)) orelse
            (try byRay(allocator, paves, &indexes, fragment, samples.items, zone, options, diag)) orelse
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
/// boundary, the band `band` wide about it (in a sliver one tolerance wide the clearest
/// sample is within the zone of the other's face that bounds it, and the next is not;
/// 2026-11-13); null when every sample lies on it. The first rays take the band the paves
/// put points on the other's faces within, the intersection tolerance: a hull's face at a
/// box's corner, its ridge 4e-5 over the box's bottom and the ridge's end and the edge
/// down from it on the box's side by the paves (2e-5 past it), lay within the tolerance of
/// the bottom and the side all over; its first sample past the zone lay 1.5e-5 outside the
/// side, where the paves had the face on it, and the ray kept the face over the bottom,
/// inside the box, its seams reading it inside (`edge_coedge_count`; the locus_solids
/// ReleaseSafe find cv, 2026-11-22).
fn byRay(allocator: std.mem.Allocator, paves: *const Paves, indexes: *const [2]index_mod.FaceIndex, fragment: imprint.Fragment, samples: []const Vec3, band: f64, options: diagnostics.Options, diag: *Diagnostics) Error!?Class {
    const other = 1 - fragment.operand;
    for (samples) |p| {
        switch (try point_in_body.classifyWithin(allocator, paves.operands[other], &indexes[other], p, band, options, diag)) {
            .inside => return .inside,
            .outside => return .outside,
            .boundary => continue,
        }
    }
    return null;
}

/// Inside or outside the other operand, by rays from the corners of fragment `i` the paves
/// put on nothing of it (`on`, `operandsOn`), into `out`; null when it has none. A corner
/// on nothing of the other lies beyond the tolerance and its gap of every face, edge and
/// vertex of it, and so off its boundary, and the fragment, which meets the other only
/// along its pieces on it, is on the corner's side (OCCT's `ComputeState`: a face's state
/// by an edge not on the other solid before a point inside it). Taken where every sample
/// lies on the other's boundary: a face a corner of which lay its zone off its plane (a
/// boolean's merged vertex), 0.4° off a box's face, its corner past the tolerance over it
/// and its plane within the zone of it all over the piece the box's face cut off (the 10K
/// session on c3a83ee8, locus_solids).
fn byCorner(allocator: std.mem.Allocator, paves: *const Paves, indexes: *const [2]index_mod.FaceIndex, fragments: *const Fragments, i: usize, on: []const u2, out: *std.ArrayList(Vec3), options: diagnostics.Options, diag: *Diagnostics) Error!?Class {
    const fragment = fragments.items.items[i];
    const other_bit = @as(u2, 1) << (1 - fragment.operand);
    out.clearRetainingCapacity();
    for (fragments.loopsOf(i)) |loop| for (fragments.loopVertices(loop)) |v| {
        if (on[v] & other_bit == 0) try out.append(allocator, paves.point(v));
    };
    return byRay(allocator, paves, indexes, fragment, out.items, paves.operands[1 - fragment.operand].tol.zone, options, diag);
}

/// Which operands each merged vertex lies on, as bits (`1 << operand`): its own, and those
/// it lies on a face of (the paves' incidences, a vertex on an edge or a vertex among them).
fn operandsOn(allocator: std.mem.Allocator, paves: *const Paves) Error![]u2 {
    const on = try allocator.alloc(u2, paves.points.items.len);
    @memset(on, 0);
    for (paves.incidences.items) |inc| on[inc.vertex] |= @as(u2, 1) << inc.face.operand;
    for (paves.owners.items, on) |owners, *o| o.* |= owners;
    return on;
}

/// The pieces of each operand the paves made (consecutive paves of an edge, and section
/// segments), by their merged vertices: where a fragment's boundary lies on the other
/// operand, found without a scan of its edges. A section along an edge is the edge's piece.
/// A piece of edges is every edge of the operand over it: solids of one operand touching
/// along a line have an edge each there (`pipeline.pairTouching`), and the operand's
/// material about the piece is all of theirs.
const Seams = struct {
    /// `edges`: `Seams.edges[start..][0..count]`.
    const Piece = union(enum) { edges: [2]u32, section: types.FaceIndex };
    const Key = struct { operand: u1, lo: u32, hi: u32 };
    const FaceKey = struct { operand: u1, face: u32 };
    pieces: std.AutoHashMapUnmanaged(Key, Piece) = .empty,
    /// The edges of the pieces of edges, each piece's together.
    edges: std.ArrayList(types.EdgeIndex) = .empty,
    /// Each face's edges in trees, built the first time a section on a face with many
    /// (`face_edges.INDEXED_AT_LEAST`) is placed, as the paves keep them; null for a face
    /// scanned edge by edge.
    indexed: std.AutoHashMapUnmanaged(FaceKey, ?face_edges.FaceEdges) = .empty,

    const Block = struct {
        key: Key,
        edge: u32,
        fn lessThan(_: void, a: Block, b: Block) bool {
            if (a.key.operand != b.key.operand) return a.key.operand < b.key.operand;
            if (a.key.lo != b.key.lo) return a.key.lo < b.key.lo;
            if (a.key.hi != b.key.hi) return a.key.hi < b.key.hi;
            return a.edge < b.edge;
        }
    };

    fn build(allocator: std.mem.Allocator, paves: *const Paves) Error!Seams {
        var self: Seams = .{};
        errdefer self.deinit(allocator);
        // Every pave block, then each piece's edges together
        var blocks: std.ArrayList(Block) = .empty;
        defer blocks.deinit(allocator);
        for (0..2) |k| {
            const operand: u1 = @intCast(k);
            for (paves.edge_paves[k], 0..) |list, e| {
                if (list.items.len < 2) continue;
                for (list.items[0 .. list.items.len - 1], list.items[1..]) |u, w| {
                    try blocks.append(allocator, .{ .key = .{ .operand = operand, .lo = @min(u.vertex, w.vertex), .hi = @max(u.vertex, w.vertex) }, .edge = @intCast(e) });
                }
            }
        }
        std.mem.sort(Block, blocks.items, {}, Block.lessThan);
        var start: usize = 0;
        while (start < blocks.items.len) {
            var end = start + 1;
            while (end < blocks.items.len and std.meta.eql(blocks.items[end].key, blocks.items[start].key)) end += 1;
            const first: u32 = @intCast(self.edges.items.len);
            for (blocks.items[start..end]) |block| try self.edges.append(allocator, types.EdgeIndex.of(block.edge));
            try self.pieces.put(allocator, blocks.items[start].key, .{ .edges = .{ first, @intCast(end - start) } });
            start = end;
        }
        for (0..2) |k| {
            const operand: u1 = @intCast(k);
            for (paves.sections[k], 0..) |list, g| for (list.items) |segment| {
                const entry = try self.pieces.getOrPut(allocator, .{ .operand = operand, .lo = segment[0], .hi = segment[1] });
                if (!entry.found_existing) entry.value_ptr.* = .{ .section = types.FaceIndex.of(g) };
            };
        }
        return self;
    }

    fn deinit(self: *Seams, allocator: std.mem.Allocator) void {
        self.pieces.deinit(allocator);
        self.edges.deinit(allocator);
        var it = self.indexed.valueIterator();
        while (it.next()) |entry| if (entry.*) |*index| index.deinit(allocator);
        self.indexed.deinit(allocator);
    }

    fn edgesOfPiece(self: *const Seams, range: [2]u32) []const types.EdgeIndex {
        return self.edges.items[range[0]..][0..range[1]];
    }

    /// Face `g` of operand `k`'s edges in trees when it has many, reaching as far as a
    /// placement asks (the tolerance, a gap of the zone at most, D27's band).
    fn edgesOf(self: *Seams, allocator: std.mem.Allocator, paves: *const Paves, k: u1, g: types.FaceIndex, diag: *Diagnostics) Error!?*const face_edges.FaceEdges {
        const entry = try self.indexed.getOrPut(allocator, .{ .operand = k, .face = @backingInt(g) });
        if (!entry.found_existing) {
            entry.value_ptr.* = null;
            const body = paves.operands[k];
            var count: usize = 0;
            var loops = traverse.Loops.init(body, g);
            while (loops.next() catch return corrupt(diag)) |l| {
                var it = traverse.Coedges.init(body, l);
                while (it.next() catch return corrupt(diag)) |_| count += 1;
            }
            if (count >= face_edges.INDEXED_AT_LEAST) entry.value_ptr.* = try face_edges.FaceEdges.build(allocator, body, g, paves.tol.xsect + paves.tol.zone + paves.decide.band(), diag);
        }
        return if (entry.value_ptr.*) |*index| index else null;
    }

    fn of(self: *const Seams, operand: u1, x: u32, y: u32) ?Piece {
        return self.pieces.get(.{ .operand = operand, .lo = @min(x, y), .hi = @max(x, y) });
    }
};

/// Fragment `i`'s side of the other operand by its seams: the pieces of its boundary lying
/// on the other (a piece of one of its edges or a section segment, as the paves made them),
/// each read by the faces about it, as OCCT's `BOPTools_AlgoTools::IsInternalFace` takes a
/// split face's state from the dihedral at a section edge (Leo, 2026-11-14; seams first,
/// the M0–M4 review, 2026-11-15): the direction from the piece into the fragment (square
/// to it in the fragment's plane, the loop having the fragment on its left) against the
/// other's face the piece is a section with, behind which is inside, or against the wedge
/// of material between the other's two faces along the edge the piece is a piece of. Width
/// plays no part, as it does for a ray from a sample: a strip 2.5e-5 wide under a face
/// rising from its section at 26.6° has no point farther than 1.1e-5 from it (the 10K fuzz
/// session, 2026-11-14). `clear_only`: by the pieces that show their side clearly (`Side`),
/// two of them disagreeing a contradiction of the paves, refused (`unclassified`); else by
/// every piece, as the last resort for a fragment no ray decides, null when two disagree.
/// Null when no piece decides (none lies on the other, the faces there are in one plane
/// with the fragment's, or the edge a piece is of runs across that plane: `wedgeSide`).
/// A spur of the fragment (a piece its loops run there and back, a section or an edge of
/// the other ending inside the face) decides nothing: the fragment lies on both sides of
/// it, so its two runs read the two sides of the other's material there, as OCCT's
/// `IsInternalFace` passes over an edge internal to the face it classifies, and as `sample`
/// triangulates a fragment without its spurs. A hull's edge lying in a face's plane from
/// the face's boundary to the hull's apex 2.8e-5 inside it, the hull's faces along it one
/// above the plane and one below it within the tolerance, read the fragment inside along
/// one run and outside along the other (`unclassified`; the cd fork's solids fuzz run,
/// cg, 2026-11-22).
fn bySeam(allocator: std.mem.Allocator, paves: *const Paves, seams: *Seams, fragments: *const Fragments, i: usize, clear_only: bool, diag: *Diagnostics) Error!?Class {
    const fragment = fragments.items.items[i];
    const normal = in_face.outwardNormal(paves.operands[fragment.operand], types.FaceIndex.of(fragment.face), .{ 0, 0 });
    const other: u1 = 1 - fragment.operand;
    var found: ?Class = null;
    for (fragments.loopsOf(i)) |loop| {
        const vertices = fragments.loopVertices(loop);
        for (vertices, 0..) |x, k| {
            const y = vertices[(k + 1) % vertices.len];
            const piece = seams.of(other, x, y) orelse continue;
            // A spur, run back the other way in the fragment's loops, has the fragment on
            // both sides and bounds no region of it
            if (fragments.steps(i, y, x)) continue;
            const into = vec.normalized(vec.cross(normal, vec.sub(paves.point(y), paves.point(x)))) orelse continue;
            const side = (try pieceSide(allocator, paves, seams, fragments, i, other, piece, x, y, normal, into, diag)) orelse continue;
            if (clear_only and !side.clear) continue;
            if (found) |c| {
                if (c == side.class) continue;
                // Clear seams disagreeing contradict the paves; the rest only fail to decide
                if (!clear_only) return null;
                return diag.fail(error.IntersectionFailed, .{ .code = .unclassified, .entity = .of(.face, fragment.face), .label = "a fragment whose seams on the other operand put it on both sides of it" });
            } else found = side.class;
        }
    }
    return found;
}

/// A piece's side of the other operand, and whether the piece shows it clearly: along an
/// edge of the other, or a section whose middle lies in its face beyond reach of the face's
/// boundary. Within reach of that boundary the face's neighbour bounds the material too: a
/// piece 6e-5 long at a corner of a prism's bottom, read by the bottom alone, was inside
/// where the fragment's pieces along the prism's edges had it outside (OCCT's H7 thinned to
/// 3 tolerances), while the pieces of a section triangle 3e-5 a side, all within reach of
/// a tetrahedron's tip edges, are rightly inside (the tip through a box's top).
const Side = struct { class: Class, clear: bool };

/// The side of operand `other` that direction `into` leaves `piece` (from merged vertex
/// `x` to `y`) towards, in a face of normal `normal`: by the material between the two faces
/// of `other`'s edges the piece is a piece of (`wedgeSide`, clear; inside any solid's
/// wedge where solids touch along it), else behind the face `g`
/// of `other` it is a section with (clear when its middle lies in `g` beyond reach of
/// `g`'s boundary, `in_face.placeWithin`, the paves' decision). Null for a face there in
/// one plane with the fragment's face `face`, as the paves decided it (`Paves.inOnePlane`:
/// one region with it, the twins' to decide), or when `into` runs along `g` to rounding.
/// A face parallel to the fragment's within the angular tolerance and not in one plane
/// with it shows its side as any other, by the sign of the turn however small (OCCT's
/// `IsInternalFace` reads the dihedral to its angular precision): the paves made a section
/// of the two along the line through the merged vertices on both, their planes within the
/// tolerance of each other there (`pave.hingedWithin`: farther apart they do not meet, and
/// the turn tells no side), and the fragment beside it is on the side the face turns from
/// it, wherever the planes' own line runs. Passed
/// over as parallel, a strip of a plate's top beside the line through two corners of a
/// hull's top, 0.8° off it and 1.8e-4 under it there, was left to a ray: the planes' own
/// line ran through the strip 0.0127 from the corners', its points lay either side of
/// the hull's top within 2.2e-4, and the first of them clear of it, over it, kept the
/// strip the hull's top covers (`edge_coedge_count`; the session on 6f0faa84, bl). The
/// turn is the side only where the fragment reaches it: where every corner of the fragment
/// off `g`'s plane (past the paves' rounding) lies on one side of it, the fragment lies on
/// that side whatever the turn (`cornersSide`). A face 1e-9 rad off a box's side and 2e-5
/// outside it, hinged where its edge lay within the tolerance of the side, turned toward
/// the box but met its plane 2e4 away: by the turn its fragment was inside, every corner
/// of it outside, and its seams disagreed with its operand's beyond the box
/// (`unclassified`; the ReleaseSafe session on a1444371, ci, 2026-11-22). With corners
/// either side the fragment crosses the plane, and the turn says which way it leaves the
/// piece (bl).
fn pieceSide(allocator: std.mem.Allocator, paves: *const Paves, seams: *Seams, fragments: *const Fragments, i: usize, other: u1, piece: Seams.Piece, x: u32, y: u32, normal: Vec3, into: Vec3, diag: *Diagnostics) Error!?Side {
    const face = fragments.items.items[i].face;
    const body = paves.operands[other];
    switch (piece) {
        .edges => |range| {
            // In the material of any solid whose edge it is (the operand's solids do not
            // overlap): a box's back face holding the line a hull's edge touched it along
            // read the fragment in front of it, outside, though inside the hull's wedge (the
            // nightly, 2026-11-18)
            var class: ?Class = null;
            for (seams.edgesOfPiece(range)) |e| {
                const side = (try wedgeSide(paves, fragments, i, other, e, normal, into, diag)) orelse continue;
                if (side == .inside) return .{ .class = .inside, .clear = true };
                class = side;
            }
            return .{ .class = class orelse return null, .clear = true };
        },
        .section => |g| {
            if (paves.inOnePlane(1 - other, face, @backingInt(g))) return null;
            const n_g = in_face.outwardNormal(body, g, .{ 0, 0 });
            const leave = sectionInto(paves, x, y, normal, n_g, into) orelse return null;
            const across = vec.dot(leave.into, n_g);
            if (@abs(across) <= SIDE_ROUNDING) return null;
            const middle = vec.lerp(paves.point(x), paves.point(y), 0.5);
            const gap = @max(paves.gaps.items[x], paves.gaps.items[y]);
            const edges = try seams.edgesOf(allocator, paves, other, g, diag);
            const clear = leave.clear and try in_face.placeWithin(paves.decide, body, g, middle, gap, edges, diag) == .inside and
                try in_face.placeWithin(paves.decide, body, g, departure(body, g, n_g, middle, leave.into, across, paves.tol.xsect + gap), gap, edges, diag) == .inside;
            return .{ .class = faceSide(paves, fragments, i, body, g, n_g, normal, across), .clear = clear };
        },
    }
}

/// Where fragment `i`, leaving a piece of its section with face `g` (outward normal
/// `n_g`) at `middle` along `into` (`across` = `into`·`n_g`), has gone `reach` behind or
/// in front of `g`'s plane, put back on the plane: the foot of the point the fragment's
/// side is read at. The turn is the side only where the fragment leaves the piece that
/// far while over `g`; a face the fragment runs off before it is past the tolerance of
/// `g` bounds nothing there beyond the tolerance, and the fragment's side is another's to
/// show. OCCT's `IsInternalFace` reads a split face's state at a point of the face
/// offset from the section edge past the tolerance (`BOPTools_AlgoTools3D::PointNearEdge`).
/// A hull's edge across a plate's end, the plate 3 tolerances thick, lay on the end over
/// the plate's thickness, and the hull's face along it left the end 17.5° off it toward the
/// plate's inside: 1.8e-5 behind the end at most before it ran out under the plate's bottom,
/// within the tolerance of the end all the while. The piece's middle was 3e-5 from the
/// end's top and bottom, clear of them, and the face read inside the plate though every
/// point of it lay outside; its seams disagreed with the hull's other faces'
/// (`unclassified`; the ReleaseSafe session on ff515852, df, 2026-11-22).
fn departure(body: *const Body, g: types.FaceIndex, n_g: Vec3, middle: Vec3, into: Vec3, across: f64, reach: f64) Vec3 {
    const q = vec.addScaled(middle, into, reach / @abs(across));
    const origin = planar_faces.frameOf(body, g).?.origin;
    return vec.addScaled(q, n_g, -vec.dot(vec.sub(q, origin), n_g));
}

/// The way a section piece from merged vertex `x` to `y` leaves into its fragment (of a
/// face of normal `normal`), against the other's face of normal `n_g`: square to the
/// faces' own line in the fragment's plane, the way the piece runs along that line, as
/// OCCT reads a section edge by its curve's tangent, not by the chord between its
/// vertices (`into`, which faces parallel within the angular tolerance keep: their line
/// is no direction, `faceSide` reads them by the fragment's corners). Both ends lie within
/// their reach of both planes, so a piece no longer along the line than its ends reach
/// across it runs any way the vertices' places put it: its side is not clear, as the paves
/// could not tell which way along the line it runs (a piece 5e-5 long at a tolerance of
/// 2e-5, its chord along the other face's normal, read the turn of its noise, outside,
/// where its fragment's piece along the line beside it read inside: the solids chain
/// moved whole in the nightly on ff515852, cz; a piece 5.4e-4 long at a tolerance of 2e-4,
/// 87° off the line, the same in the local session on ff515852, de). Null when the piece
/// runs across the line to rounding.
const Leave = struct { into: Vec3, clear: bool };

fn sectionInto(paves: *const Paves, x: u32, y: u32, normal: Vec3, n_g: Vec3, into: Vec3) ?Leave {
    if (paves.tol.parallel(normal, n_g)) return .{ .into = into, .clear = true };
    const line = vec.normalized(vec.cross(normal, n_g)) orelse return .{ .into = into, .clear = true };
    const along = vec.dot(vec.sub(paves.point(y), paves.point(x)), line);
    if (@abs(along) <= paves.rounding) return null;
    const way = if (along > 0) line else vec.scale(line, -1);
    const reaches = incidence.reach(paves.tol, paves.gaps.items[x]) + incidence.reach(paves.tol, paves.gaps.items[y]);
    return .{ .into = vec.normalized(vec.cross(normal, way)) orelse return null, .clear = @abs(along) > reaches };
}

/// The side of face `g` of `body` (outward normal `n_g`) fragment `i` (of a face of normal
/// `normal`) lies on beyond a piece it leaves `across` = `into`·`n_g` toward: behind it,
/// inside, by the turn, but a face parallel to the fragment's within the angular tolerance
/// shows the side its corners lie on where they lie on one side (`cornersSide`), as a
/// section's (`pieceSide`) and an edge's faces (`wedgeSide`) alike.
fn faceSide(paves: *const Paves, fragments: *const Fragments, i: usize, body: *const Body, g: types.FaceIndex, n_g: Vec3, normal: Vec3, across: f64) Class {
    const turned: Class = if (across < 0) .inside else .outside;
    if (!paves.tol.parallel(normal, n_g)) return turned;
    return cornersSide(paves, fragments, i, body, g, n_g) orelse turned;
}

/// The side of face `g` of `body` (outward normal `n_g`) every corner of fragment `i` off
/// `g`'s plane lies on: outside in front of it, inside behind it; null when its corners
/// lie on both sides, or none off it past the paves' rounding.
fn cornersSide(paves: *const Paves, fragments: *const Fragments, i: usize, body: *const Body, g: types.FaceIndex, n_g: Vec3) ?Class {
    const origin = planar_faces.frameOf(body, g).?.origin;
    var front = false;
    var behind = false;
    for (fragments.loopsOf(i)) |loop| for (fragments.loopVertices(loop)) |m| {
        const height = vec.dot(vec.sub(paves.point(m), origin), n_g);
        if (@abs(height) <= paves.rounding) continue;
        if (height > 0) front = true else behind = true;
    };
    if (front == behind) return null;
    return if (front) .outside else .inside;
}

/// The side of operand `other` that direction `into` leaves its edge `e` towards, in a face of
/// normal `normal`: in the material between the edge's two faces, behind both at a convex
/// edge and behind either at a concave one. A face of the two in one plane with the
/// fragment's bounds the material along that plane, so the other face decides alone where
/// `into` runs beyond the edge, away from it: in front of the other at a convex edge, behind
/// it at a concave one (a plate's front inside a notch 1.25 tolerances deep under its edge,
/// the notched front in its plane, every point of it within the tolerance of the notch's
/// sides, which no ray decides: the edge-case matrix, 2026-11-16). The wedge bounds the
/// fragment's region only along an edge in the fragment's plane (within the angular
/// tolerance, `canonical.Comparison.lineInPlane`, as `pipeline.pairTouching` reads the
/// result's wedges): an edge across that plane,
/// a piece of it on the face by reach alone, bounds no region of it, its faces cutting the
/// plane along their own lines, and reads no side (a hull's edge across a plate's side
/// 2.1 tolerances tall at 15.5°, within the tolerance of it over the crossing, read the
/// side's piece inside the hull outside, 2.2° off the hull's face: the 10K session on
/// 2b26eef1; Leo, 2026-11-17); at the angular tolerance to rounding, refused
/// (`at_tolerance`, D27). A face of the edge is in one plane with the fragment's face `face`
/// as the paves decided it (`Paves.inOnePlane`), as for a section (`pieceSide`), not by
/// the angle between them: a face parallel to the fragment's within the angular tolerance
/// and not in one plane with it shows its side by the sign of the turn however small,
/// and a narrow face the paves hold in the plane at any angle is in it (a hull's top
/// 0.8° off a plate's, its edge 1.8e-4 under the plate's top and the top rising from it
/// over the plate's side: the strip of the plate's top beside the edge, passed over as in
/// the top's plane, was left to a ray, which read it outside, the edge with three faces;
/// bl's configuration with the seam a piece of the hull's edge, the audit of decisions
/// made twice, 2026-11-22). Null for a curved edge, an edge across the plane, `into`
/// running onto a face in that plane (one region with it, the twins' to decide) or along
/// a face to rounding, or both faces in that plane. A face parallel to the fragment's
/// shows the side the fragment's corners lie on where they lie on one side of it, as a
/// section's does (`faceSide`; ci).
fn wedgeSide(paves: *const Paves, fragments: *const Fragments, i: usize, other: u1, e: types.EdgeIndex, normal: Vec3, into: Vec3, diag: *Diagnostics) Error!?Class {
    const face = fragments.items.items[i].face;
    const body = paves.operands[other];
    const edge = body.edge(e);
    const line = switch (body.geometry.curve(edge.curve)) {
        .line => |l| l,
        else => return null,
    };
    switch (canonical.verdict(&.{canonical.Comparison.lineInPlane(line.d, normal, paves.tol.angle)})) {
        .same => {},
        .apart => return null,
        .at_tolerance => |c| return diag.fail(error.Degenerate, .{ .code = .at_tolerance, .entity = .of(.edge, @backingInt(e)), .label = "an edge of the other operand on a fragment's face, in its plane or across it, the angle between them the angular tolerance to rounding", .measured = c.measured, .threshold = c.limit }),
    }
    const first = edge.coedge;
    const second = body.coedge(first).partner;
    if (first == .none or second == .none) return corrupt(diag);
    const f1 = body.loop(body.coedge(first).loop).face;
    const f2 = body.loop(body.coedge(second).loop).face;
    const n1 = in_face.outwardNormal(body, f1, .{ 0, 0 });
    const n2 = in_face.outwardNormal(body, f2, .{ 0, 0 });
    // Along the first face's loop, each face lying to the left of its own coedge
    const along = vec.scale(line.d, if (body.coedge(first).same_sense) 1 else -1);
    const in_plane = [2]bool{ paves.inOnePlane(1 - other, face, @backingInt(f1)), paves.inOnePlane(1 - other, face, @backingInt(f2)) };
    if (in_plane[0] and in_plane[1]) return null;
    if (in_plane[0] or in_plane[1]) {
        const face_n = if (in_plane[0]) n1 else n2;
        const other_f = if (in_plane[0]) f2 else f1;
        const other_n = if (in_plane[0]) n2 else n1;
        const onto = vec.cross(face_n, if (in_plane[0]) along else vec.scale(along, -1));
        if (vec.dot(into, onto) > 0) return null;
        return faceSide(paves, fragments, i, body, other_f, other_n, normal, vec.dot(into, other_n));
    }
    // Along a face to rounding, no side (as a section's, `pieceSide`)
    const across = [2]f64{ vec.dot(into, n1), vec.dot(into, n2) };
    if (@abs(across[0]) <= SIDE_ROUNDING or @abs(across[1]) <= SIDE_ROUNDING) return null;
    // Convex when the second face turns behind the first along the first's loop
    const convex = vec.dot(vec.cross(n1, n2), along) > 0;
    const behind_first = faceSide(paves, fragments, i, body, f1, n1, normal, across[0]) == .inside;
    const behind_second = faceSide(paves, fragments, i, body, f2, n2, normal, across[1]) == .inside;
    const inside = if (convex) behind_first and behind_second else behind_first or behind_second;
    return if (inside) .inside else .outside;
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the other operand" });
}

/// Joins in `parent` the undecided fragments of one operand that share an edge piece
/// (consecutive merged vertices of their loops, run opposite ways) whose ends neither lies
/// on the other operand (`on`, `operandsOn`).
fn joinComponents(allocator: std.mem.Allocator, fragments: *const Fragments, on: []const u2, decided: []const bool, parent: []u32) Error!void {
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

/// Whether fragment `i`, of a face not in one plane with its twin `j`'s, is the pair's copy
/// the result keeps: the one whose face's plane holds the region (their merged vertices)
/// more closely, a tie (to rounding, `canonical.sameToRounding`) by the boolean's tie rule
/// (`planar_faces.TieFace.before`, at the region's centroid). Not the first operand's, which made the result hang on the operands' order where
/// the two faces are two planes: the region joins its own face's other fragments (one
/// record), so A ∪ B kept a hull's corner the region reached and B ∪ A a flat
/// tetrahedron's face over it (the 10K fuzz session, 2026-11-15). Both orders measure
/// alike and choose alike.
fn represents(paves: *const Paves, fragments: *const Fragments, i: usize, j: usize) bool {
    const own = farthest(paves, fragments, i, i);
    const other = farthest(paves, fragments, j, i);
    const scale = regionScale(paves, fragments, i, j);
    if (!canonical.sameToRounding(own, other, scale)) return own < other;
    return tieFace(paves, fragments, i).before(tieFace(paves, fragments, j), regionCentroid(paves, fragments, i), scale, paves.tol);
}

/// Fragment `i`'s face as the tie rule sees it.
fn tieFace(paves: *const Paves, fragments: *const Fragments, i: usize) planar_faces.TieFace {
    const fragment = fragments.items.items[i];
    return .of(paves.operands[fragment.operand], fragment.operand, fragment.face);
}

/// The centroid of fragment `region`'s merged vertices.
fn regionCentroid(paves: *const Paves, fragments: *const Fragments, region: usize) Vec3 {
    var sum = vec.ZERO3;
    var n: f64 = 0;
    for (fragments.loopsOf(region)) |loop| for (fragments.loopVertices(loop)) |v| {
        sum = vec.add(sum, paves.point(v));
        n += 1;
    };
    return if (n > 0) vec.scale(sum, 1 / n) else sum;
}

/// The size of fragment `region`'s merged vertices' coordinates and of the origins of its
/// face's plane and fragment `other`'s: what their heights over the two are rounded at.
fn regionScale(paves: *const Paves, fragments: *const Fragments, region: usize, other: usize) f64 {
    var scale = canonical.magnitude(&.{ planeOfFragment(paves, fragments, region).origin, planeOfFragment(paves, fragments, other).origin });
    for (fragments.loopsOf(region)) |loop| for (fragments.loopVertices(loop)) |v| {
        scale = @max(scale, canonical.magnitude(&.{paves.point(v)}));
    };
    return scale;
}

/// The plane of fragment `i`'s face.
fn planeOfFragment(paves: *const Paves, fragments: *const Fragments, i: usize) @import("../geometry/types.zig").Frame {
    const fragment = fragments.items.items[i];
    return planar_faces.frameOf(paves.operands[fragment.operand], types.FaceIndex.of(fragment.face)).?;
}

/// The farthest of fragment `region`'s merged vertices from the plane of fragment `of`'s face.
fn farthest(paves: *const Paves, fragments: *const Fragments, of: usize, region: usize) f64 {
    const frame = planeOfFragment(paves, fragments, of);
    var worst: f64 = 0;
    for (fragments.loopsOf(region)) |loop| for (fragments.loopVertices(loop)) |v| {
        worst = @max(worst, @abs(vec.dot(vec.sub(paves.point(v), frame.origin), frame.z)));
    };
    return worst;
}

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
pub fn comparePieces(a: []const [2]u32, b: []const [2]u32) std.math.Order {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        if (x[0] != y[0]) return std.math.order(x[0], y[0]);
        if (x[1] != y[1]) return std.math.order(x[1], y[1]);
    }
    return std.math.order(a.len, b.len);
}

/// Fragment `i`'s pieces between merged vertices, each as its two vertices (the lesser
/// first), sorted, appended to `out`: its region by its edges, whichever way it runs.
pub fn piecesOf(allocator: std.mem.Allocator, fragments: *const Fragments, i: usize, out: *std.ArrayList([2]u32)) Error!void {
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
/// sampling, kept as the check that a fragment with no twin is no region of a partner). A
/// sample on a partner's boundary, or there to rounding, says nothing and the next decides
/// (`planar_faces.placed`): the samples are the fragment's triangulation's, not the
/// solids', and one at the tolerance to rounding refused in place what was made mirrored
/// (ec).
pub fn sameDomain(paves: *const Paves, body: *const Body, f: types.FaceIndex, other: usize, samples: []const Vec3, partners: []const u32, diag: *Diagnostics) Error!?Classified {
    for (samples) |p| {
        var on_a_boundary = false;
        for (partners) |g| {
            const face_g = types.FaceIndex.of(g);
            switch (try planar_faces.placed(paves.operands[other], face_g, p, 0, paves.tol, diag)) {
                .outside => continue,
                .boundary, .at_tolerance => {
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
pub fn sample(allocator: std.mem.Allocator, paves: *const Paves, fragments: *const Fragments, i: usize, out: *std.ArrayList(Vec3)) Error!void {
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
    // Its spurs and slits (a piece run both ways) bound nothing (`triangulate.splitSlits`)
    var split: std.ArrayList(u32) = .empty;
    defer split.deinit(allocator);
    for (fragments.loopsOf(i)) |loop| {
        const vertices = fragments.loopVertices(loop);
        ring.clearRetainingCapacity();
        split.clearRetainingCapacity();
        try triangulate.splitSlits(allocator, vertices, null, &ring, &split);
        for (split.items, 0..) |from, r| {
            const to = if (r + 1 < split.items.len) split.items[r + 1] else ring.items.len;
            if (to - from < 3) continue;
            try starts.append(allocator, @intCast(points.items.len));
            for (ring.items[from..to]) |k| try points.append(allocator, planar_faces.flat(frame, paves.point(vertices[k])));
        }
    }
    if (starts.items.len == 0) return;
    try starts.append(allocator, @intCast(points.items.len));
    try overlap.interiorPoints(allocator, frame, points.items, starts.items, edges.items, out);
}
