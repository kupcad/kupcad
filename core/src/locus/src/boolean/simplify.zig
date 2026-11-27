//! The boolean's last phase on the result (docs/architecture.md §7.4 step 7, KNOWLEDGE §7;
//! Stroud's coplanar annihilation, OCCT's `UnifySameDomain` in little): what the splitting
//! left that the result does not need, removed by Euler operators so every step keeps the
//! structure (topology/euler.zig).
//!
//! - Two faces across an edge on the same surface record, facing the same way, of the same
//!   attribute (two materials on one plane stay two faces), become one (`kef`, the dying
//!   face's holes moved over first); never across a seam (D7), and never across an edge
//!   with a copy, where another solid touches the face along the line (merged, the line
//!   would lie inside the face: the overlap rules' find, 2026-11-12).
//! - An edge whose two coedges a merge left in one loop goes: a spur (`kevSpur`, its far
//!   vertex with it unless another shell touches the face there; a hole that was a lone
//!   slit, then a loop of one vertex, with `kvh`) or a bridge between an outer boundary and a hole (`kemr`, the loop
//!   with the larger area about the outward normal kept first, as the outer).
//! - A chain of edges through vertices with two line edges each becomes one edge
//!   (`kevJoin` at each vertex inside it; OCCT's `UnifySameDomain` merging a chain of
//!   edges through two-valent vertices): pieces of one curve record, or on a line of its
//!   edges that holds every vertex of the chain within the intersection tolerance and its
//!   gap, every edge within the angle, and stays on the chain's faces as the checker holds
//!   an edge to them, decided with D27's band. A chain no line holds splits at the vertex
//!   farthest from the chord between its ends (Douglas–Peucker), each side decided alike:
//!   geometry decides, never the vertices' numbering. The boolean gives each edge its
//!   source's line (D28), so pieces of two operands' edges meet so, and the joined edge
//!   keeps one of them.
//! - An edge no longer than the minimum feature size (`check.shortest`, measured as the
//!   checker measures it, `check.edgeLength`, D27's band beyond) collapses into its start
//!   (`kevMergeCopies`), the edges at its end moved
//!   there, their ranges taken to it and its gap grown to hold their lines (`coverLine`), when neither of its faces is left with fewer than
//!   three edges; a sliver that would be is left for the checker to refuse. Where solids
//!   touch along it, its copies collapse with it, each solid's edges moved (OCCT's small
//!   edge removal replaces the vertex in every edge that shares it). (The paves keep
//!   merged vertices further apart than the intersection tolerance, so this is for what a
//!   vertex merge moved: two vertices of one operand each moved toward the other.)
//!
//! Repeated until nothing changes, then the tombstones are compacted away.

const std = @import("std");
const vec = @import("../math/vec.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const euler = @import("../topology/euler.zig");
const in_face = @import("../query/in_face.zig");
const canonical = @import("../geometry/canonical.zig");
const incidence = @import("../geometry/incidence.zig");
const check = @import("../topology/check.zig");
const cover = @import("../topology/cover.zig");
const Body = body_mod.Body;
const Diagnostics = diagnostics.Diagnostics;
const CurveRef = @import("../geometry/types.zig").CurveRef;
const Error = diagnostics.Error;

/// Passes at most: each pass that changes something removes an edge, so the edges bound
/// them; this bounds a body whose operators refuse every change after the first.
const MAX_PASSES: usize = 64;

/// The most edges between two vertices a short edge's collapse takes at once (the edge and
/// its copies, one a solid touching along it); more, and the edge is left.
const MAX_COPIES: usize = 8;

/// What simplification did to the faces, for a caller following them (the boolean's
/// face map): each merge, and the renumbering.
pub const Log = struct {
    /// Faces merged away, as `{gone, into}` in the order merged, before compaction.
    merged: std.ArrayList([2]u32) = .empty,
    /// Each face's index after compaction, `Body.Remap.NONE` for one removed; owned.
    faces: []u32 = &.{},

    pub fn deinit(self: *Log, allocator: std.mem.Allocator) void {
        self.merged.deinit(allocator);
        allocator.free(self.faces);
        self.* = undefined;
    }
};

/// Simplifies `body` in place and compacts it, its face merges and renumbering in `log`
/// when given.
pub fn run(body: *Body, diag: *Diagnostics, log: ?*Log) Error!void {
    var absorbed: Absorbed = .{};
    defer absorbed.deinit(body.allocator);
    var pass: usize = 0;
    while (pass < MAX_PASSES) : (pass += 1) {
        var changed = false;
        changed = try mergeFaces(body, diag, log) or changed;
        changed = try removeInnerEdges(body, diag) or changed;
        changed = try joinEdges(body, &absorbed, diag) or changed;
        changed = try collapseShortEdges(body, diag) or changed;
        if (!changed) break;
    }
    var remap = body.compact() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooMany => diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "entities" }),
    };
    defer remap.deinit(body.allocator);
    if (log) |l| l.faces = try body.allocator.dupe(u32, remap.faces);
}

/// Whether faces `f` and `g` may be one face: of one attribute, on one surface record the
/// same way. The record is the pipeline's (D28, `pipeline.Provenance`): the fragments of
/// one face of an operand share that face's, and the faces the paves found in one plane
/// (`Paves.coplanar`) share their group's, so one record is one plane as the paves decided
/// it, and nothing else is one plane. Decided here again by geometry (the normals within
/// the angular tolerance, each face's corners within the intersection tolerance of the
/// other's plane; OCCT's `UnifySameDomain` asks 1e-12 rad and is no step of its boolean),
/// two faces of one operand were made one where a cut left little of them: a flat
/// tetrahedron's two upper faces, 1.2e-4 rad apart about the edge between them, cut by a
/// hull to a strip 3e-3 wide along that edge, their corners 1.6e-7 off each other's
/// planes. The face made of them met the tetrahedron's lower face along both of the edges
/// the two had met it along, two lines from the tetrahedron's corner, which two planes do
/// not share: 6e-5 apart at the strip's far end, the two faces lay on each other between
/// those edges, and the intersection and the difference were bodies whose faces intersect
/// (`faces_intersect`; the locus session on 5c1e164e, 2026-11-20, br).
/// The vertices each joined edge took the place of, by edge: where they were and how far
/// they reached. A line a later pass joins the edge on must hold them as the first did, or
/// the passes decide a chain twice, the second time without the vertices the first took
/// away: a hull's face across a box's bottom and a wall's 1.5e-5 under it left a chain of
/// vertices C, B, A along the two planes' traces, 2.6e-5 apart in the face; a line held C,
/// B, A and another B, A and the next, the fewest runs either way; one way round the first
/// pass took B away, and the second joined C away on the higher trace, which B lay off by
/// more than the tolerance, the edge now 2.6e-5 from where the faces meet and the union a
/// vertex fewer than the other way round, where the first pass took A (the ReleaseSafe
/// session on ff515852, dj, 2026-11-22). With them kept a later pass finds no run the
/// first did not have, and the chain's count is the fewest of its own vertices'.
const Absorbed = struct {
    const Point = struct { p: vec.Vec3, gap: f64 };

    of: std.AutoHashMapUnmanaged(types.EdgeIndex, std.ArrayList(Point)) = .empty,

    fn deinit(self: *Absorbed, allocator: std.mem.Allocator) void {
        var lists = self.of.valueIterator();
        while (lists.next()) |list| list.deinit(allocator);
        self.of.deinit(allocator);
    }

    fn points(self: *const Absorbed, e: types.EdgeIndex) []const Point {
        return if (self.of.getPtr(e)) |list| list.items else &.{};
    }
};

fn sameDomain(body: *const Body, f: types.FaceIndex, g: types.FaceIndex) bool {
    const a = body.face(f);
    const b = body.face(g);
    return a.attribute == b.attribute and a.surface.eql(b.surface) and a.same_sense == b.same_sense;
}

/// Merges across edges between faces that may be one, but not across an edge with a copy
/// (another edge between its vertices: two solids touching along it, assembled as one edge
/// per solid), whose line the touching solid needs as a boundary of this face.
fn mergeFaces(body: *Body, diag: *Diagnostics, log: ?*Log) Error!bool {
    var copies = try Copies.of(body);
    defer copies.deinit(body.allocator);
    var changed = false;
    for (0..body.edges.items.len) |i| {
        const e = body.edges.items[i];
        if (e.flags.tombstone or e.flags.seam or e.flags.degenerate or e.coedge == .none) continue;
        if (copies.has(e)) continue;
        const c = e.coedge;
        const p = body.coedge(c).partner;
        if (p == .none) continue;
        const f = body.loop(body.coedge(c).loop).face;
        const g = body.loop(body.coedge(p).loop).face;
        if (f == g or !sameDomain(body, f, g)) continue;
        // The dying face is the one whose outer loop the edge is on
        const dying_coedge = if (body.face(f).first_loop == body.coedge(c).loop) c else if (body.face(g).first_loop == body.coedge(p).loop) p else continue;
        const dying = body.loop(body.coedge(dying_coedge).loop).face;
        const keep = if (dying == f) g else f;
        // Its holes go to the face it joins
        var hole = body.loop(body.face(dying).first_loop).next_in_face;
        while (hole != .none) {
            const next = body.loop(hole).next_in_face;
            body.removeLoop(dying, hole);
            body.appendLoop(keep, hole);
            body.loop(hole).face = keep;
            hole = next;
        }
        // Its box joins the face's, both in their one record's frame
        body.face(keep).uv_box = body.face(keep).uv_box.merge(body.face(dying).uv_box);
        euler.kef(body, dying_coedge) catch |err| return eulerError(diag, err);
        if (log) |l| try l.merged.append(body.allocator, .{ @backingInt(dying), @backingInt(keep) });
        changed = true;
    }
    return changed;
}

/// Edges with both coedges in one loop, left by merges: spurs and bridges, each going
/// whole. A vertex goes with them only when no edge uses it any more: where another shell
/// touches the face at a point, the face needs no record of it (one shell's boundary holds
/// the point), and kept as a slit's tip it hung on the order the edges went in, the
/// operands' (the 10K session on 8db70212, 2026-11-18: a quad lying in a plate's bottom
/// with another shell's corner on it left a slit one way round and a loop of that one
/// vertex the other). An edge with a copy, where another solid touches the face along it,
/// stays (a chain of such slits from the boundary, its first edge taken for a bridge, left
/// the contact inside the face: the solids fuzzer, 2026-11-13).
fn removeInnerEdges(body: *Body, diag: *Diagnostics) Error!bool {
    var copies = try Copies.of(body);
    defer copies.deinit(body.allocator);
    var changed = false;
    for (0..body.edges.items.len) |i| {
        const e = body.edges.items[i];
        if (e.flags.tombstone or e.flags.seam or e.flags.degenerate or e.coedge == .none) continue;
        if (copies.has(e)) continue;
        const c = e.coedge;
        const p = body.coedge(c).partner;
        if (p == .none or body.coedge(c).loop != body.coedge(p).loop) continue;
        const out: ?types.CoedgeIndex = if (body.coedge(c).next == p) c else if (body.coedge(p).next == c) p else null;
        if (out) |spur| {
            const loop = body.coedge(spur).loop;
            euler.kevSpur(body, spur) catch |err| return eulerError(diag, err);
            // A hole that was a lone slit is now a point, and goes too: a loop of one vertex
            // in a face was left for the next boolean, whose containment table sewed the face
            // from its loops (the solids fuzzer, 2026-11-13). Its vertex stays when another
            // shell touches the face there
            if (body.loop(loop).first == .none and body.face(body.loop(loop).face).first_loop != loop) {
                euler.kvh(body, loop) catch |err| return eulerError(diag, err);
            }
        } else {
            const face = body.loop(body.coedge(c).loop).face;
            _ = euler.kemr(body, c) catch |err| return eulerError(diag, err);
            try outerFirst(body, face, diag);
        }
        changed = true;
    }
    return changed;
}

/// Face `f`'s loop of the largest area about its outward normal made its first.
fn outerFirst(body: *Body, f: types.FaceIndex, diag: *Diagnostics) Error!void {
    const normal = in_face.outwardNormal(body, f, .{ 0, 0 });
    var best: types.LoopIndex = .none;
    var best_area = -std.math.inf(f64);
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var area = vec.ZERO3;
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| area = vec.add(area, vec.cross(body.point(body.coedgeStart(c)), body.point(body.coedgeEnd(c))));
        const along = vec.dot(area, normal);
        if (along > best_area) {
            best_area = along;
            best = l;
        }
    }
    if (best == .none or best == body.face(f).first_loop) return;
    body.removeLoop(f, best);
    body.loop(best).next_in_face = body.face(f).first_loop;
    body.face(f).first_loop = best;
}

/// Vertices with two edges continuing one line, decided a chain at a time. A chain runs
/// through vertices with exactly two edges, both lines (counted over the whole body: a
/// vertex two solids touch at has a fan of faces for each, and one fan of two is not the
/// vertex's every edge), from one other vertex to the next (OCCT's `UnifySameDomain`
/// merges such a chain of edges whole). The decision is the chain's, never a vertex's
/// with its neighbours as they stand: joined vertex by vertex, each join gave the edge one
/// of its two lines and the next was measured against that line where it ran on, so the
/// error walked down the chain and which vertices went hung on their numbering, the
/// operands' order (the nightly solids fuzzer, run 43773180777, 2026-11-16: a hull's face
/// crossing a box's top and a plate's bottom 3e-5 apart left a chain of four vertices on
/// two lines 8.7e-5 apart, joined whole one way round and to two edges the other).
fn joinEdges(body: *Body, absorbed: *Absorbed, diag: *Diagnostics) Error!bool {
    const allocator = body.allocator;
    const uses = try edgeCounts(body);
    defer allocator.free(uses);
    // Each vertex inside a chain, its two edges
    const pairs = try allocator.alloc(?[2]types.EdgeIndex, body.vertices.items.len);
    defer allocator.free(pairs);
    for (pairs, 0..) |*pair, i| pair.* = try chainPair(body, types.VertexIndex.of(i), uses[i], diag);
    const seen = try allocator.alloc(bool, body.edges.items.len);
    defer allocator.free(seen);
    @memset(seen, false);

    var chains: std.ArrayList(Chain) = .empty;
    defer {
        for (chains.items) |*chain| chain.deinit(allocator);
        chains.deinit(allocator);
    }
    for (body.edges.items, 0..) |e, i| {
        if (seen[i] or e.flags.tombstone or e.coedge == .none or e.curve.kind != .line) continue;
        // An edge with neither end inside a chain is a chain of its own
        if (pairs[@backingInt(e.start)] == null and pairs[@backingInt(e.end)] == null) continue;
        var chain = try Chain.walk(allocator, body, pairs, types.EdgeIndex.of(i));
        errdefer chain.deinit(allocator);
        for (chain.edges.items) |ce| seen[@backingInt(ce)] = true;
        if (chain.vertices.items.len < 3) {
            chain.deinit(allocator);
            continue;
        }
        try chains.append(allocator, chain);
    }

    var changed = false;
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(allocator);
    for (chains.items) |*chain| {
        runs.clearRetainingCapacity();
        try decide(allocator, body, chain, absorbed, &runs, diag);
        for (runs.items) |run_| changed = try joinRun(body, chain, run_, absorbed, diag) or changed;
    }
    return changed;
}

/// Vertex `v`'s two edges when it lies inside a chain: live, used by two edges in all,
/// exactly two coedges leaving it, both of distinct lines' edges.
fn chainPair(body: *const Body, v: types.VertexIndex, uses: u32, diag: *Diagnostics) Error!?[2]types.EdgeIndex {
    const vertex = body.vertex(v);
    if (vertex.tombstone or vertex.coedge == .none or uses != 2) return null;
    var umbrella = traverse.Umbrella.init(body, v);
    var leaving: [3]types.CoedgeIndex = undefined;
    var count: usize = 0;
    while (umbrella.next() catch return corrupt(diag)) |c| {
        if (count == leaving.len) break;
        leaving[count] = c;
        count += 1;
    }
    if (count != 2) return null;
    const first = body.coedge(leaving[0]).edge;
    const second = body.coedge(leaving[1]).edge;
    if (first == second or body.edge(first).curve.kind != .line or body.edge(second).curve.kind != .line) return null;
    return .{ first, second };
}

/// Edges end to end through vertices inside a chain: `vertices` one more than `edges`,
/// edge `i` between vertices `i` and `i + 1`. A closed chain starts and ends at its
/// vertex least in coordinates (a corner of its hull, whatever the numbering).
const Chain = struct {
    vertices: std.ArrayList(types.VertexIndex) = .empty,
    edges: std.ArrayList(types.EdgeIndex) = .empty,

    fn deinit(self: *Chain, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.edges.deinit(allocator);
    }

    /// The chain through edge `e`.
    fn walk(allocator: std.mem.Allocator, body: *const Body, pairs: []const ?[2]types.EdgeIndex, e: types.EdgeIndex) error{OutOfMemory}!Chain {
        var chain: Chain = .{};
        errdefer chain.deinit(allocator);
        // Back from the edge's start to the chain's first vertex
        var at = body.edge(e).start;
        var through = e;
        while (pairs[@backingInt(at)]) |pair| {
            const next = if (pair[0] == through) pair[1] else pair[0];
            if (next == e) break; // closed
            through = next;
            at = otherEnd(body, next, at);
        }
        const first = at;
        // Forward from there
        try chain.vertices.append(allocator, first);
        var edge = through;
        at = first;
        while (true) {
            try chain.edges.append(allocator, edge);
            at = otherEnd(body, edge, at);
            try chain.vertices.append(allocator, at);
            if (at == first) break;
            const pair = pairs[@backingInt(at)] orelse break;
            edge = if (pair[0] == edge) pair[1] else pair[0];
        }
        if (chain.vertices.items[0] == chain.vertices.items[chain.vertices.items.len - 1]) try chain.rotateToLeast(allocator, body);
        return chain;
    }

    /// A closed chain restarted at its vertex least in coordinates.
    fn rotateToLeast(self: *Chain, allocator: std.mem.Allocator, body: *const Body) error{OutOfMemory}!void {
        const n = self.edges.items.len;
        var least: usize = 0;
        for (1..n) |i| if (lessPoint(body.point(self.vertices.items[i]), body.point(self.vertices.items[least]))) {
            least = i;
        };
        if (least == 0) return;
        const vertices = try allocator.alloc(types.VertexIndex, n + 1);
        defer allocator.free(vertices);
        const edges = try allocator.alloc(types.EdgeIndex, n);
        defer allocator.free(edges);
        for (0..n) |i| {
            vertices[i] = self.vertices.items[(least + i) % n];
            edges[i] = self.edges.items[(least + i) % n];
        }
        vertices[n] = vertices[0];
        @memcpy(self.vertices.items, vertices);
        @memcpy(self.edges.items, edges);
    }
};

/// Vertices `lo` to `hi` of a chain become one edge on `line`.
const Run = struct { lo: usize, hi: usize, line: CurveRef };

fn otherEnd(body: *const Body, e: types.EdgeIndex, v: types.VertexIndex) types.VertexIndex {
    const edge = body.edge(e);
    return if (edge.start == v) edge.end else edge.start;
}

fn lessPoint(a: vec.Vec3, b: vec.Vec3) bool {
    for (0..3) |i| if (a[i] != b[i]) return a[i] < b[i];
    return false;
}

/// The runs of `chain`: the fewest edges it can be made, each run of its edges one edge on
/// a line of theirs that holds them (`hold`), found exactly by dynamic programming over its
/// vertices (the least count of runs to each vertex, a run ending there from any vertex
/// before it that a line holds it to); of runs as few, the last run the longest, so the
/// chain's own order picks among them, never the rounding. Geometry alone decides how many
/// edges the chain keeps, never the order the vertices are numbered in nor where the chain
/// is placed. Douglas–Peucker's split at the vertex farthest from the chord decided it by
/// which of two vertices was farther, a difference the rounding of the placement could
/// not resolve: two vertices 5.135159e-6 and 5.135130e-6 from the chord, apart by 2.9e-11,
/// in place the one farther and the other three joined, moved whole 3e5 out tied to
/// rounding (a band of 4e-9 there) and no run joined (the solids fuzzer, cm, 2026-11-22;
/// cd, the exact tie, before it). A run held only to rounding (`at_tolerance`) is refused
/// when the count depends on it, counted either way; else the count without it is taken.
fn decide(allocator: std.mem.Allocator, body: *const Body, chain: *const Chain, absorbed: *const Absorbed, runs: *std.ArrayList(Run), diag: *Diagnostics) Error!void {
    const n = chain.edges.items.len;
    if (n < 2) return;
    // The least count of runs to each vertex: without the runs held to rounding, and with
    // them; the vertex each least run (without) starts at, and its line
    const least = try allocator.alloc(usize, 2 * (n + 1));
    defer allocator.free(least);
    const without = least[0 .. n + 1];
    const with = least[n + 1 ..];
    const from = try allocator.alloc(usize, n + 1);
    defer allocator.free(from);
    const line = try allocator.alloc(?CurveRef, n + 1);
    defer allocator.free(line);
    without[0] = 0;
    with[0] = 0;
    var rounding: ?struct { comparison: canonical.Comparison, edge: types.EdgeIndex } = null;
    for (1..n + 1) |j| {
        without[j] = without[j - 1] + 1;
        with[j] = with[j - 1] + 1;
        from[j] = j - 1;
        line[j] = null;
        for (0..j - 1) |i| {
            switch (try hold(body, chain, absorbed, i, j)) {
                .held => |curve| {
                    if (without[i] + 1 < without[j]) {
                        without[j] = without[i] + 1;
                        from[j] = i;
                        line[j] = curve;
                    }
                    with[j] = @min(with[j], with[i] + 1);
                },
                .apart => {},
                .at_tolerance => |c| {
                    with[j] = @min(with[j], with[i] + 1);
                    if (rounding == null) rounding = .{ .comparison = c, .edge = chain.edges.items[i] };
                },
            }
        }
    }
    if (with[n] != without[n]) {
        const r = rounding.?;
        return diag.fail(error.Degenerate, .{ .code = .at_tolerance, .entity = .of(.edge, @backingInt(r.edge)), .label = "edges meeting end to end, on one line or not, to within rounding", .measured = r.comparison.measured, .threshold = r.comparison.limit });
    }
    var j = n;
    while (j > 0) : (j = from[j]) {
        if (line[j]) |curve| try runs.append(allocator, .{ .lo = from[j], .hi = j, .line = curve });
    }
}

/// Whether a line holds vertices `lo` to `hi` of `chain` (`hold`), not yet taken: held on
/// the line, apart, or at the tolerance to rounding.
const Hold = union(enum) { held: CurveRef, apart, at_tolerance: canonical.Comparison };

/// The line, of the edges between vertices `lo` and `hi` of `chain`, that holds them all
/// within the tolerance: pieces of one curve record always; else a line every edge is
/// parallel to within the angle, every vertex within the intersection tolerance and its
/// gap of, and that over each edge stays on the edge's faces within the tolerance and the
/// edge's gap, as the checker holds an edge to its surfaces (on planes a line's height is
/// linear: its ends decide). Of several, the one lying nearest the chain's faces' planes
/// (`offFaces`: the least gap the joined edge then needs, as OCCT keeps a merged edge's
/// tolerance least), as far to rounding by the least record (the boolean's lines are its
/// sources', D28: which one changes where the edge lies within the tolerance, never which
/// vertices go). By the least record alone the choice hung on the records' order, which a
/// mirror changes: a needle's corner edge took a line 1.5e-5 off one of its faces mirrored
/// and one 1e-5 off it in place, and the solid's area differed by 4% (the solids oracle's
/// mirrored replay on 9015ab26, dw). Apart when none holds them; at the tolerance when none does and one is
/// within rounding of it (`decide` refuses it where the chain's count depends on it). The
/// faces' check: a section's line, through a vertex 1.8e-4 under the plane it lies in at a
/// tolerance of 2e-4, joined a notch's edge on that line and took the joined edge 3.6e-4
/// under the plane at its far end, the tolerance spent twice (the 10K session, 2026-11-15: a plate's top and a notch's ceiling 1.8e-4
/// under it, the plate first, `edge_off_surface`).
fn hold(body: *const Body, chain: *const Chain, absorbed: *const Absorbed, lo: usize, hi: usize) Error!Hold {
    const edges = chain.edges.items[lo..hi];
    const first = body.edge(edges[0]).curve;
    for (edges[1..]) |e| {
        if (!body.edge(e).curve.eql(first)) break;
    } else return .{ .held = first };
    var best: ?struct { curve: CurveRef, off: Off } = null;
    var at: ?canonical.Comparison = null;
    for (edges) |candidate| {
        const curve = body.edge(candidate).curve;
        if (best) |b| if (curve.eql(b.curve)) continue;
        const line = body.geometry.curve(curve).line;
        switch (try lineHolds(body, line, chain, absorbed, lo, hi)) {
            .same => {
                const off = offFaces(body, line, chain, lo, hi);
                if (best) |b| {
                    const nearer = if (canonical.sameToRounding(off.height, b.off.height, @max(off.scale, b.off.scale))) @as(u32, @bitCast(curve)) < @as(u32, @bitCast(b.curve)) else off.height < b.off.height;
                    if (!nearer) continue;
                }
                best = .{ .curve = curve, .off = off };
            },
            .apart => {},
            .at_tolerance => |c| at = at orelse c,
        }
    }
    if (best) |b| return .{ .held = b.curve };
    if (at) |c| return .{ .at_tolerance = c };
    return .apart;
}

/// How far a line lies off a chain's faces (`offFaces`), and the size of the coordinates
/// that was measured at.
const Off = struct { height: f64, scale: f64 };

/// The greatest height over the planes of the faces of `chain`'s edges `lo` to `hi` of
/// `line`'s feet at the chain's ends, `lo` and `hi` (on planes a line's height is linear:
/// its ends bound it); what `hold` chooses a line by.
fn offFaces(body: *const Body, line: @import("../geometry/curves.zig").Line, chain: *const Chain, lo: usize, hi: usize) Off {
    var off: Off = .{ .height = 0, .scale = 0 };
    for (chain.edges.items[lo..hi]) |e| {
        for (traverse.coedgesOfEdge(body, e)) |c| {
            if (c == .none) continue;
            const face = body.face(body.loop(body.coedge(c).loop).face);
            if (face.surface.kind != .plane) continue;
            const plane = body.geometry.planes.items[face.surface.index];
            for ([2]types.VertexIndex{ chain.vertices.items[lo], chain.vertices.items[hi] }) |v| {
                const end = line.eval(line.project(body.point(v)));
                off.height = @max(off.height, @abs(plane.height(end)));
                off.scale = @max(off.scale, canonical.magnitude(&.{ end, plane.frame.origin }));
            }
        }
    }
    return off;
}

/// `hold`'s measures of `line` against the edges and vertices `lo` to `hi`.
fn lineHolds(body: *const Body, line: @import("../geometry/curves.zig").Line, chain: *const Chain, absorbed: *const Absorbed, lo: usize, hi: usize) Error!canonical.Verdict {
    const tol = body.tol;
    var tally: canonical.Tally = .{};
    for (chain.vertices.items[lo .. hi + 1]) |v| {
        const p = body.point(v);
        tally.add(canonical.Comparison.distance(canonical.lineOffset(line, p), incidence.reach(tol, body.vertex(v).gap), canonical.magnitude(&.{ p, line.o })));
    }
    for (chain.edges.items[lo..hi]) |e| {
        // The vertices the edge took the place of in an earlier pass, as the chain's own
        for (absorbed.points(e)) |was| tally.add(canonical.Comparison.distance(canonical.lineOffset(line, was.p), incidence.reach(tol, was.gap), canonical.magnitude(&.{ was.p, line.o })));
        const edge = body.edge(e);
        const own = body.geometry.curve(edge.curve).line;
        tally.add(canonical.Comparison.angle(1.0 - @abs(vec.dot(line.d, own.d)), tol.angle));
        for (traverse.coedgesOfEdge(body, e)) |c| {
            if (c == .none) continue;
            const face = body.face(body.loop(body.coedge(c).loop).face);
            if (face.surface.kind != .plane) return .apart;
            const plane = body.geometry.planes.items[face.surface.index];
            for ([2]types.VertexIndex{ edge.start, edge.end }) |v| {
                const end = line.eval(line.project(body.point(v)));
                tally.add(canonical.Comparison.distance(@abs(plane.height(end)), tol.xsect + edge.gap, canonical.magnitude(&.{ end, plane.frame.origin })));
            }
        }
    }
    return tally.verdict();
}

/// Run `r` of `chain` made one edge: each edge put on the run's line, then each vertex
/// inside the run joined away (`kevJoin`), the edge left with the largest of their gaps and
/// covered again where it now ends (`coverEdge`: its line's height over its faces at the
/// run's ends, and those ends' gaps raised to the edge's; a run along a line whose height
/// over a face grows along it took its far piece's gap while its near end kept its own,
/// smaller, and the result failed the checker's `gap_order`, the audit of 2026-11-22).
fn joinRun(body: *Body, chain: *const Chain, r: Run, absorbed: *Absorbed, diag: *Diagnostics) Error!bool {
    const edges = chain.edges.items[r.lo..r.hi];
    var gap: f64 = 0;
    // Every edge's range on the run's line taken by projection, its own line's too: the
    // joins need the pieces' ranges to meet exactly, and an edge kept on its line with the
    // range it came with met its rebased neighbour's by an ulp, and the join was refused
    // (the test of the chain's runs, 2026-11-22)
    for (edges) |e| {
        gap = @max(gap, body.edge(e).gap);
        rebase(body, e, r.line);
    }
    // The vertices the run's edge takes the place of: those inside the run, and those its
    // edges took in an earlier pass (`Absorbed`)
    var taken: std.ArrayList(Absorbed.Point) = .empty;
    errdefer taken.deinit(body.allocator);
    for (edges) |e| {
        if (absorbed.of.fetchRemove(e)) |entry| {
            var list = entry.value;
            defer list.deinit(body.allocator);
            try taken.appendSlice(body.allocator, list.items);
        }
    }
    for (chain.vertices.items[r.lo + 1 .. r.hi]) |v| try taken.append(body.allocator, .{ .p = body.point(v), .gap = body.vertex(v).gap });
    var joined = false;
    for (chain.vertices.items[r.lo + 1 .. r.hi]) |v| {
        // A coedge arriving at the vertex, from the edge that runs into it along the line
        var umbrella = traverse.Umbrella.init(body, v);
        var leaving: [2]types.CoedgeIndex = undefined;
        var count: usize = 0;
        while (umbrella.next() catch return corrupt(diag)) |c| {
            if (count == leaving.len) break;
            leaving[count] = c;
            count += 1;
        }
        for (leaving[0..count]) |out| {
            euler.kevJoin(body, body.coedge(out).prev) catch |err| switch (err) {
                error.Invalid => continue,
                else => return eulerError(diag, err),
            };
            joined = true;
            break;
        }
    }
    // Every edge of the run left keeps them all: where a join was refused the run is more
    // than one edge still, each on the run's line
    for (edges) |e| if (!body.edge(e).flags.tombstone) {
        const entry = try absorbed.of.getOrPut(body.allocator, e);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.appendSlice(body.allocator, taken.items);
    };
    taken.deinit(body.allocator);
    if (joined) for (edges) |e| if (!body.edge(e).flags.tombstone) {
        body.edge(e).gap = gap;
        try cover.coverEdge(body, e, diag);
    };
    return joined;
}

/// Edge `e` on `curve` (a line), its own or another: its range the projections of its ends,
/// and run the line's way (its ends and its coedges' senses turned when the line runs from
/// its end to its start).
fn rebase(body: *Body, e: types.EdgeIndex, curve: CurveRef) void {
    const line = body.geometry.curve(curve).line;
    const edge = body.edge(e);
    const ts = line.project(body.point(edge.start));
    const te = line.project(body.point(edge.end));
    edge.curve = curve;
    if (ts <= te) {
        edge.t0 = ts;
        edge.t1 = te;
        return;
    }
    std.mem.swap(types.VertexIndex, &edge.start, &edge.end);
    edge.t0 = te;
    edge.t1 = ts;
    const first = edge.coedge;
    body.coedge(first).same_sense = !body.coedge(first).same_sense;
    const partner = body.coedge(first).partner;
    if (partner != .none) body.coedge(partner).same_sense = !body.coedge(partner).same_sense;
}

/// Each edge the checker would find too short collapsed (see the file's comment). Measured
/// as the checker measures it, the chord of its curve over its range: by the distance
/// between its vertices, an edge 2.06e-5 between ends 1.05e-5 off its line, its chord
/// 1.77e-5, was left, and the checker found it too short in the boolean's own result. D27's
/// band beyond the minimum is a margin: what rounds to it either way goes.
fn collapseShortEdges(body: *Body, diag: *Diagnostics) Error!bool {
    var changed = false;
    const shortest = check.shortest(body.tol);
    for (0..body.edges.items.len) |i| {
        const e = body.edges.items[i];
        if (e.flags.tombstone or e.flags.seam or e.flags.degenerate or e.coedge == .none) continue;
        const scale = canonical.magnitude(&.{ body.point(e.start), body.point(e.end) });
        if (!(check.edgeLength(body, e) <= shortest + canonical.Comparison.distance(0, shortest, scale).band)) continue;
        // The edge and its copies, where solids touch along it, go together: the vertex
        // gone is each solid's (`euler.kevMergeCopies`)
        var copies: [MAX_COPIES]types.EdgeIndex = undefined;
        const n = copiesOf(body, types.EdgeIndex.of(i), &copies) orelse continue;
        if (!(try collapsible(body, copies[0..n], diag))) continue;
        const out = try cheaperEnd(body, e.coedge, scale);
        const keep = body.coedgeStart(out);
        var outs: [MAX_COPIES]types.CoedgeIndex = undefined;
        for (copies[0..n], outs[0..n]) |copy, *o| {
            const first = body.edge(copy).coedge;
            o.* = if (body.coedgeStart(first) == keep) first else body.coedge(first).partner;
        }
        euler.kevMergeCopies(body, outs[0..n]) catch |err| switch (err) {
            error.Invalid => continue,
            else => return eulerError(diag, err),
        };
        // The lines at the vertex kept: their ranges reach its point, its gap their lines
        // (an edge moved over ended at the vertex gone, up to the short edge off it), and
        // each edge covered again where it now ends (`coverEdge`: its height over its faces
        // at the new end, and the kept vertex's gap raised to the edges' gaps, which moved
        // edges brought from the vertex gone; the audit of 2026-11-22)
        const at = body.point(keep);
        for (0..body.edges.items.len) |j| {
            const other = &body.edges.items[j];
            if (other.flags.tombstone or (other.start != keep and other.end != keep)) continue;
            const line = switch (body.geometry.curve(other.curve)) {
                .line => |l| l,
                else => continue,
            };
            if (other.start == keep) other.t0 = line.project(at) else other.t1 = line.project(at);
            try cover.coverLine(body, keep, line, .of(.vertex, @backingInt(keep)), "a vertex a short edge collapsed into, off the line of an edge moved to it past the intersection tolerance by", diag);
            try cover.coverEdge(body, types.EdgeIndex.of(j), diag);
        }
        changed = true;
    }
    return changed;
}

/// The live edges between edge `e`'s two vertices, `e` first, in `out`; null when more than
/// `MAX_COPIES`.
fn copiesOf(body: *const Body, e: types.EdgeIndex, out: *[MAX_COPIES]types.EdgeIndex) ?usize {
    const pair = Copies.pairOf(body.edge(e).*);
    out[0] = e;
    var n: usize = 1;
    for (body.edges.items, 0..) |other, j| {
        if (j == @backingInt(e) or other.flags.tombstone or !std.meta.eql(Copies.pairOf(other), pair)) continue;
        if (n == MAX_COPIES) return null;
        out[n] = types.EdgeIndex.of(j);
        n += 1;
    }
    return n;
}

/// Whether short edges `copies` (an edge and its copies) may collapse: each between two
/// faces, two loops, and neither loop left with fewer than three edges.
fn collapsible(body: *const Body, copies: []const types.EdgeIndex, diag: *Diagnostics) Error!bool {
    for (copies) |copy| {
        const c = body.edge(copy).coedge;
        if (c == .none) return false;
        const p = body.coedge(c).partner;
        if (p == .none or body.coedge(c).loop == body.coedge(p).loop) return false;
        if ((traverse.loopLength(body, body.coedge(c).loop) catch return corrupt(diag)) <= 3) return false;
        if ((traverse.loopLength(body, body.coedge(p).loop) catch return corrupt(diag)) <= 3) return false;
    }
    return true;
}

/// Of short edge `c`'s two ends, the coedge leaving the one to keep (`kevMerge` keeps the
/// start of the coedge it is given): the end nearer the lines that move to it, the largest
/// distance from it to a line of the other end's edges, so the gap it takes to hold them
/// (`coverLine`) is the smaller, and made against refused (`gap_too_large`) does not go by
/// which way the edge runs or which of its coedges it records, which follow the operands'
/// order (the audit of 2026-11-22: kept at its start, a corner needed a gap past the zone
/// for a line moved to it, where the other end needed one within it). Each end stays its
/// own point, as the paves merged it (D28; OCCT's `MakeVertex` would move it to the middle
/// of the two). The two as far to rounding keep the start.
fn cheaperEnd(body: *const Body, c: types.CoedgeIndex, scale: f64) Error!types.CoedgeIndex {
    const partner = body.coedge(c).partner;
    const start = body.coedgeStart(c);
    const end = body.coedgeEnd(c);
    const reach_start = farthestLine(body, start, end);
    const reach_end = farthestLine(body, end, start);
    if (canonical.sameToRounding(reach_start, reach_end, scale)) return c;
    return if (reach_end < reach_start) partner else c;
}

/// The largest distance from vertex `keep` to the line of an edge at vertex `gone`, other
/// than the edges between them (the short edge and its copies, which go): what holding the
/// edges `gone` would move to `keep` takes.
fn farthestLine(body: *const Body, keep: types.VertexIndex, gone: types.VertexIndex) f64 {
    const p = body.point(keep);
    var farthest: f64 = 0;
    for (body.edges.items) |e| {
        if (e.flags.tombstone or (e.start != gone and e.end != gone) or e.start == keep or e.end == keep) continue;
        const line = switch (body.geometry.curve(e.curve)) {
            .line => |l| l,
            else => continue,
        };
        farthest = @max(farthest, canonical.lineOffset(line, p));
    }
    return farthest;
}

/// The live edges between each pair of vertices: more than one where solids touch along a
/// line, an edge per solid (the assembly's copies).
const Copies = struct {
    const Pair = struct { lo: u32, hi: u32 };
    counts: std.AutoHashMapUnmanaged(Pair, u32) = .empty,

    fn of(body: *const Body) error{OutOfMemory}!Copies {
        var self: Copies = .{};
        errdefer self.deinit(body.allocator);
        for (body.edges.items) |e| {
            if (e.flags.tombstone) continue;
            const entry = try self.counts.getOrPut(body.allocator, pairOf(e));
            entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
        }
        return self;
    }

    fn deinit(self: *Copies, allocator: std.mem.Allocator) void {
        self.counts.deinit(allocator);
    }

    /// Whether edge `e` has a copy (counted when the table was made).
    fn has(self: *const Copies, e: types.Edge) bool {
        return (self.counts.get(pairOf(e)) orelse 0) > 1;
    }

    fn pairOf(e: types.Edge) Pair {
        return .{ .lo = @min(@backingInt(e.start), @backingInt(e.end)), .hi = @max(@backingInt(e.start), @backingInt(e.end)) };
    }
};

/// How many live edges end at each vertex; owned by the body's allocator.
fn edgeCounts(body: *const Body) error{OutOfMemory}![]u32 {
    const uses = try body.allocator.alloc(u32, body.vertices.items.len);
    @memset(uses, 0);
    for (body.edges.items) |e| {
        if (e.flags.tombstone) continue;
        uses[@backingInt(e.start)] += 1;
        uses[@backingInt(e.end)] += 1;
    }
    return uses;
}

fn eulerError(diag: *Diagnostics, err: euler.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "a boolean's result while it was simplified" }),
    };
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "a boolean's result" });
}
