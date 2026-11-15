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
//!   vertex with it; a hole that was a lone slit, then a loop of one vertex nothing else
//!   uses, with `kvh`) or a bridge between an outer boundary and a hole (`kemr`, the loop
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
//!   (`kevMerge`), the edges at its end moved
//!   there and their ranges taken to it, when neither of its faces is left with fewer than
//!   three edges; a sliver that would be is left for the checker to refuse. (The paves keep
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
const surfaces = @import("../geometry/surfaces.zig");
const euler = @import("../topology/euler.zig");
const in_face = @import("../query/in_face.zig");
const canonical = @import("../geometry/canonical.zig");
const incidence = @import("../geometry/incidence.zig");
const check = @import("../topology/check.zig");
const Body = body_mod.Body;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// Passes at most: each pass that changes something removes an edge, so the edges bound
/// them; this bounds a body whose operators refuse every change after the first.
const MAX_PASSES: usize = 64;

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
    var pass: usize = 0;
    while (pass < MAX_PASSES) : (pass += 1) {
        var changed = false;
        changed = try mergeFaces(body, diag, log) or changed;
        changed = try removeInnerEdges(body, diag) or changed;
        changed = try joinEdges(body, diag) or changed;
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

/// Whether faces `f` and `g` may be one face: of one attribute, and on one surface record
/// the same way, or on two planes the same within the tolerance (OCCT's UnifySameDomain,
/// as `sameLine` joins edges): their outward normals within the angular tolerance and each
/// face's corners within the intersection tolerance and their gaps of the other's plane,
/// decided with D27's band. By records alone, two faces in one plane kept apart or merged
/// by which operand came first (D28 gives each its source's plane): A ∪ B had 20 faces and
/// B ∪ A 19 (the solids fuzzer's operand-swap oracle, 2026-11-14).
fn sameDomain(body: *const Body, f: types.FaceIndex, g: types.FaceIndex, diag: *Diagnostics) Error!bool {
    const a = body.face(f);
    const b = body.face(g);
    if (a.attribute != b.attribute) return false;
    if (a.surface.eql(b.surface)) return a.same_sense == b.same_sense;
    if (a.surface.kind != .plane or b.surface.kind != .plane) return false;
    const pa = body.geometry.planes.items[a.surface.index];
    const pb = body.geometry.planes.items[b.surface.index];
    const na = if (a.same_sense) pa.frame.z else vec.neg(pa.frame.z);
    const nb = if (b.same_sense) pb.frame.z else vec.neg(pb.frame.z);
    var tally: canonical.Tally = .{};
    tally.add(canonical.Comparison.angle(1.0 - vec.dot(na, nb), body.tol.angle));
    for ([_]types.FaceIndex{ f, g }, [_]surfaces.Plane{ pb, pa }) |face, other| {
        var loops = traverse.Loops.init(body, face);
        while (loops.next() catch return corrupt(diag)) |l| {
            var it = traverse.Coedges.init(body, l);
            while (it.next() catch return corrupt(diag)) |c| {
                const v = body.coedgeStart(c);
                const p = body.point(v);
                tally.add(canonical.Comparison.distance(@abs(other.height(p)), incidence.reach(body.tol, body.vertex(v).gap), canonical.magnitude(&.{ p, other.frame.origin })));
            }
        }
    }
    return switch (tally.verdict()) {
        .same => true,
        .apart => false,
        .at_tolerance => |at| diag.fail(error.Degenerate, .{ .code = .at_tolerance, .entity = .of(.face, @backingInt(g)), .label = "two faces meeting at an edge, on one plane or not, to within rounding", .measured = at.measured, .threshold = at.limit }),
    };
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
        if (f == g or !try sameDomain(body, f, g, diag)) continue;
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
        // Its box joins the face's: in the face's own plane's frame, when its record is another
        if (body.face(keep).surface.eql(body.face(dying).surface)) {
            body.face(keep).uv_box = body.face(keep).uv_box.merge(body.face(dying).uv_box);
        } else {
            const frame = body.geometry.planes.items[body.face(keep).surface.index].frame;
            var loops = traverse.Loops.init(body, dying);
            while (loops.next() catch return corrupt(diag)) |l| {
                var it = traverse.Coedges.init(body, l);
                while (it.next() catch return corrupt(diag)) |cc| {
                    const local = frame.toLocal(body.point(body.coedgeStart(cc)));
                    body.face(keep).uv_box.grow(.{ local[0], local[1] });
                }
            }
        }
        euler.kef(body, dying_coedge) catch |err| return eulerError(diag, err);
        if (log) |l| try l.merged.append(body.allocator, .{ @backingInt(dying), @backingInt(keep) });
        changed = true;
    }
    return changed;
}

/// Edges with both coedges in one loop, left by merges: spurs and bridges. A spur goes
/// with its far vertex only when nothing else uses the vertex (a slit where the other
/// operand touched the face, whose tip is a corner of a face kept, stays); an edge with a
/// copy, where another solid touches the face along it, stays (a chain of such slits from
/// the boundary, its first edge taken for a bridge, left the contact inside the face: the
/// solids fuzzer, 2026-11-13).
fn removeInnerEdges(body: *Body, diag: *Diagnostics) Error!bool {
    const uses = try edgeCounts(body);
    defer body.allocator.free(uses);
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
            const far = body.coedgeEnd(spur);
            if (uses[@backingInt(far)] != 1) continue;
            const near = body.coedgeStart(spur);
            const loop = body.coedge(spur).loop;
            uses[@backingInt(near)] -= 1;
            uses[@backingInt(far)] = 0;
            euler.kevSpur(body, spur) catch |err| return eulerError(diag, err);
            // A hole that was a lone slit is now a point; when no edge leaves it any more (the
            // body's own record: the pass's counts are stale once a bridge has gone), it goes
            // too. A loop of one vertex in a face was left for the next boolean, whose
            // containment table sewed the face from its loops (the solids fuzzer, 2026-11-13)
            if (body.loop(loop).first == .none and body.vertex(near).coedge == .none and body.face(body.loop(loop).face).first_loop != loop) {
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
fn joinEdges(body: *Body, diag: *Diagnostics) Error!bool {
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
        try decide(allocator, body, chain, 0, chain.vertices.items.len - 1, &runs, diag);
        for (runs.items) |run_| changed = try joinRun(body, chain, run_, diag) or changed;
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
const Run = struct { lo: usize, hi: usize, line: @import("../geometry/types.zig").CurveRef };

fn otherEnd(body: *const Body, e: types.EdgeIndex, v: types.VertexIndex) types.VertexIndex {
    const edge = body.edge(e);
    return if (edge.start == v) edge.end else edge.start;
}

fn lessPoint(a: vec.Vec3, b: vec.Vec3) bool {
    for (0..3) |i| if (a[i] != b[i]) return a[i] < b[i];
    return false;
}

/// The runs of vertices `lo` to `hi` of `chain`: all of them one edge when a line of
/// theirs holds them (`holdingLine`), else split at the vertex farthest from the chord
/// between the ends (Douglas–Peucker), each side decided alike. Geometry alone decides,
/// never the order the vertices are numbered in.
fn decide(allocator: std.mem.Allocator, body: *const Body, chain: *const Chain, lo: usize, hi: usize, runs: *std.ArrayList(Run), diag: *Diagnostics) Error!void {
    if (hi - lo < 2) return;
    if (try holdingLine(body, chain, lo, hi, diag)) |line| return runs.append(allocator, .{ .lo = lo, .hi = hi, .line = line });
    const vs = chain.vertices.items;
    const a = body.point(vs[lo]);
    const b = body.point(vs[hi]);
    var split = lo + 1;
    var farthest: f64 = -1;
    for (lo + 1..hi) |i| {
        const p = body.point(vs[i]);
        const d = chordDistance(a, b, p);
        if (d > farthest or (d == farthest and lessPoint(p, body.point(vs[split])))) {
            farthest = d;
            split = i;
        }
    }
    try decide(allocator, body, chain, lo, split, runs, diag);
    try decide(allocator, body, chain, split, hi, runs, diag);
}

/// How far `p` lies from the segment `a`–`b` (from `a` when the two are one point).
fn chordDistance(a: vec.Vec3, b: vec.Vec3, p: vec.Vec3) f64 {
    const d = vec.sub(b, a);
    const len_sq = vec.lengthSq(d);
    if (len_sq == 0) return vec.distance(p, a);
    const s = std.math.clamp(vec.dot(vec.sub(p, a), d) / len_sq, 0, 1);
    return vec.distance(p, vec.addScaled(a, d, s));
}

/// The line, of the edges between vertices `lo` and `hi` of `chain`, that holds them all
/// within the tolerance: pieces of one curve record always; else a line every edge is
/// parallel to within the angle, every vertex within the intersection tolerance and its
/// gap of, and that over each edge stays on the edge's faces within the tolerance and the
/// edge's gap, as the checker holds an edge to its surfaces (on planes a line's height is
/// linear: its ends decide). Of several, the least record (the boolean's lines are its
/// sources', D28: which one changes where the edge lies within the tolerance, never which
/// vertices go). Null when none holds them; refused (`at_tolerance`) when none does and
/// one is within rounding of it. The faces' check: a section's line, through a vertex
/// 1.8e-4 under the plane it lies in at a tolerance of 2e-4, joined a notch's edge on that
/// line and took the joined edge 3.6e-4 under the plane at its far end, the tolerance
/// spent twice (the 10K session, 2026-11-15: a plate's top and a notch's ceiling 1.8e-4
/// under it, the plate first, `edge_off_surface`).
fn holdingLine(body: *const Body, chain: *const Chain, lo: usize, hi: usize, diag: *Diagnostics) Error!?@import("../geometry/types.zig").CurveRef {
    const edges = chain.edges.items[lo..hi];
    const first = body.edge(edges[0]).curve;
    for (edges[1..]) |e| {
        if (!body.edge(e).curve.eql(first)) break;
    } else return first;
    var best: ?@import("../geometry/types.zig").CurveRef = null;
    var at: ?canonical.Comparison = null;
    for (edges) |candidate| {
        const curve = body.edge(candidate).curve;
        if (best) |b| if (@as(u32, @bitCast(curve)) >= @as(u32, @bitCast(b))) continue;
        switch (try lineHolds(body, body.geometry.curve(curve).line, chain, lo, hi)) {
            .same => best = curve,
            .apart => {},
            .at_tolerance => |c| at = at orelse c,
        }
    }
    if (best != null) return best;
    if (at) |c| return diag.fail(error.Degenerate, .{ .code = .at_tolerance, .entity = .of(.edge, @backingInt(edges[0])), .label = "edges meeting end to end, on one line or not, to within rounding", .measured = c.measured, .threshold = c.limit });
    return null;
}

/// `holdingLine`'s measures of `line` against the edges and vertices `lo` to `hi`.
fn lineHolds(body: *const Body, line: @import("../geometry/curves.zig").Line, chain: *const Chain, lo: usize, hi: usize) Error!canonical.Verdict {
    const tol = body.tol;
    var tally: canonical.Tally = .{};
    for (chain.vertices.items[lo .. hi + 1]) |v| {
        const p = body.point(v);
        tally.add(canonical.Comparison.distance(canonical.lineOffset(line, p), incidence.reach(tol, body.vertex(v).gap), canonical.magnitude(&.{ p, line.o })));
    }
    for (chain.edges.items[lo..hi]) |e| {
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
/// inside the run joined away (`kevJoin`), the edge left with the largest of their gaps.
fn joinRun(body: *Body, chain: *const Chain, r: Run, diag: *Diagnostics) Error!bool {
    const edges = chain.edges.items[r.lo..r.hi];
    var gap: f64 = 0;
    for (edges) |e| {
        gap = @max(gap, body.edge(e).gap);
        if (!body.edge(e).curve.eql(r.line)) rebase(body, e, r.line);
    }
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
    if (joined) for (edges) |e| if (!body.edge(e).flags.tombstone) {
        body.edge(e).gap = gap;
    };
    return joined;
}

/// Edge `e` on `curve` (a line) instead of its own: its range the projections of its ends,
/// and run the line's way (its ends and its coedges' senses turned when the line runs from
/// its end to its start).
fn rebase(body: *Body, e: types.EdgeIndex, curve: @import("../geometry/types.zig").CurveRef) void {
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
        const c = e.coedge;
        const p = body.coedge(c).partner;
        if (p == .none or body.coedge(c).loop == body.coedge(p).loop) continue;
        if ((traverse.loopLength(body, body.coedge(c).loop) catch return corrupt(diag)) <= 3) continue;
        if ((traverse.loopLength(body, body.coedge(p).loop) catch return corrupt(diag)) <= 3) continue;
        const keep = body.coedgeStart(c);
        euler.kevMerge(body, c) catch |err| switch (err) {
            error.Invalid => continue,
            else => return eulerError(diag, err),
        };
        // The lines at the vertex kept: their ranges reach its point
        const at = body.point(keep);
        for (body.edges.items) |*other| {
            if (other.flags.tombstone or (other.start != keep and other.end != keep)) continue;
            const line = switch (body.geometry.curve(other.curve)) {
                .line => |l| l,
                else => continue,
            };
            if (other.start == keep) other.t0 = line.project(at) else other.t1 = line.project(at);
        }
        changed = true;
    }
    return changed;
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
