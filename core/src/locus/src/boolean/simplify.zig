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
//!   vertex with it) or a bridge between an outer boundary and a hole (`kemr`, the loop
//!   with the larger area about the outward normal kept first, as the outer).
//! - A vertex with two edges, both pieces of one line meeting end to end, goes (`kevJoin`,
//!   the edges one).
//! - An edge no longer than the minimum feature size (twice the zone, the checker's
//!   `edge_too_short`) collapses into its start (`kevMerge`), the edges at its end moved
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
const euler = @import("../topology/euler.zig");
const in_face = @import("../query/in_face.zig");
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

/// Whether faces `f` and `g` may be one face.
fn sameDomain(body: *const Body, f: types.FaceIndex, g: types.FaceIndex) bool {
    const a = body.face(f);
    const b = body.face(g);
    return a.surface.eql(b.surface) and a.same_sense == b.same_sense and a.attribute == b.attribute;
}

/// Merges across edges between faces that may be one, but not across an edge with a copy
/// (another edge between its vertices: two solids touching along it, assembled as one edge
/// per solid), whose line the touching solid needs as a boundary of this face.
fn mergeFaces(body: *Body, diag: *Diagnostics, log: ?*Log) Error!bool {
    const Pair = struct { lo: u32, hi: u32 };
    var copies: std.AutoHashMapUnmanaged(Pair, u32) = .empty;
    defer copies.deinit(body.allocator);
    for (body.edges.items) |e| {
        if (e.flags.tombstone) continue;
        const key: Pair = .{ .lo = @min(@backingInt(e.start), @backingInt(e.end)), .hi = @max(@backingInt(e.start), @backingInt(e.end)) };
        const entry = try copies.getOrPut(body.allocator, key);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
    }
    var changed = false;
    for (0..body.edges.items.len) |i| {
        const e = body.edges.items[i];
        if (e.flags.tombstone or e.flags.seam or e.flags.degenerate or e.coedge == .none) continue;
        const key: Pair = .{ .lo = @min(@backingInt(e.start), @backingInt(e.end)), .hi = @max(@backingInt(e.start), @backingInt(e.end)) };
        if (copies.get(key).? > 1) continue;
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
        body.face(keep).uv_box = body.face(keep).uv_box.merge(body.face(dying).uv_box);
        euler.kef(body, dying_coedge) catch |err| return eulerError(diag, err);
        if (log) |l| try l.merged.append(body.allocator, .{ @backingInt(dying), @backingInt(keep) });
        changed = true;
    }
    return changed;
}

/// Edges with both coedges in one loop, left by merges: spurs and bridges. A spur goes
/// with its far vertex only when nothing else uses the vertex (a slit where the other
/// operand touched the face, whose tip is a corner of a face kept, stays).
fn removeInnerEdges(body: *Body, diag: *Diagnostics) Error!bool {
    const uses = try edgeCounts(body);
    defer body.allocator.free(uses);
    var changed = false;
    for (0..body.edges.items.len) |i| {
        const e = body.edges.items[i];
        if (e.flags.tombstone or e.flags.seam or e.flags.degenerate or e.coedge == .none) continue;
        const c = e.coedge;
        const p = body.coedge(c).partner;
        if (p == .none or body.coedge(c).loop != body.coedge(p).loop) continue;
        const out: ?types.CoedgeIndex = if (body.coedge(c).next == p) c else if (body.coedge(p).next == c) p else null;
        if (out) |spur| {
            const far = body.coedgeEnd(spur);
            if (uses[@backingInt(far)] != 1) continue;
            uses[@backingInt(body.coedgeStart(spur))] -= 1;
            uses[@backingInt(far)] = 0;
            euler.kevSpur(body, spur) catch |err| return eulerError(diag, err);
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

/// Vertices with two edges continuing one line. Counted over the whole body: a vertex
/// two solids touch at has a fan of faces for each, and one fan of two is not the vertex's
/// every edge.
fn joinEdges(body: *Body, diag: *Diagnostics) Error!bool {
    const uses = try edgeCounts(body);
    defer body.allocator.free(uses);
    var changed = false;
    for (0..body.vertices.items.len) |i| {
        const v = body.vertices.items[i];
        if (v.tombstone or v.coedge == .none or uses[i] != 2) continue;
        // Exactly two coedges leave it
        var umbrella = traverse.Umbrella.init(body, types.VertexIndex.of(i));
        var leaving: [3]types.CoedgeIndex = undefined;
        var count: usize = 0;
        while (umbrella.next() catch return corrupt(diag)) |c| {
            if (count == leaving.len) break;
            leaving[count] = c;
            count += 1;
        }
        if (count != 2) continue;
        const e0 = body.edge(body.coedge(leaving[0]).edge);
        const e1 = body.edge(body.coedge(leaving[1]).edge);
        if (!e0.curve.eql(e1.curve) or e0.curve.kind != .line) continue;
        // A coedge arriving at the vertex, from the edge that runs into it along the line
        for (leaving[0..2]) |out| {
            euler.kevJoin(body, body.coedge(out).prev) catch |err| switch (err) {
                error.Invalid => continue,
                else => return eulerError(diag, err),
            };
            changed = true;
            break;
        }
    }
    return changed;
}

fn collapseShortEdges(body: *Body, diag: *Diagnostics) Error!bool {
    var changed = false;
    const shortest = 2 * body.tol.zone;
    for (0..body.edges.items.len) |i| {
        const e = body.edges.items[i];
        if (e.flags.tombstone or e.flags.seam or e.flags.degenerate or e.coedge == .none) continue;
        if (vec.distance(body.point(e.start), body.point(e.end)) > shortest) continue;
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
