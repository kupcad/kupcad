//! The Euler operators (docs/architecture.md §5.3; Stroud ch. 4 and App. F): each a pure
//! change of topology taking coedge indices, the geometry (a curve and its range, a point,
//! a surface) assigned by the caller through the arguments. Every operator has an inverse
//! here, and `op ∘ inverse` leaves the body as it was (euler_test.zig). The structural
//! rules hold before and after each (checked in Debug and tests, check.zig); an operator
//! given a configuration it cannot take returns `error.Invalid` and changes nothing.
//!
//! Conventions: a coedge "leaves" its start vertex; the coedges leaving a vertex are
//! visited around it by `traverse.Umbrella` (each next one is the partner of the previous
//! coedge in the loop). Tombstoned entities are left for `Body.compact`.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../geometry/types.zig");
const types = @import("types.zig");
const body_mod = @import("body.zig");
const traverse = @import("traverse.zig");
const check = @import("check.zig");
const Body = body_mod.Body;
const VertexIndex = types.VertexIndex;
const EdgeIndex = types.EdgeIndex;
const CoedgeIndex = types.CoedgeIndex;
const LoopIndex = types.LoopIndex;
const FaceIndex = types.FaceIndex;
const ShellIndex = types.ShellIndex;

pub const Error = error{
    OutOfMemory,
    TooMany,
    /// The entities given are not in the configuration the operator takes.
    Invalid,
    /// A traversal did not close: the body is corrupt.
    Corrupt,
};

/// The geometry of a new edge: its curve and the parameter range from its start to its
/// end vertex.
pub const EdgeGeometry = struct {
    curve: geometry.CurveRef,
    t0: f64,
    t1: f64,
    flags: types.EdgeFlags = .{},
};

/// In Debug and tests, the structural rules after every operator.
fn debugCheck(body: *const Body) void {
    if (!(builtin.is_test or builtin.mode == .debug)) return;
    check.assertStructural(body);
}

// ---------------------------------------------------------------------------------------
// mvfs / kvfs

pub const Mvfs = struct { shell: ShellIndex, face: FaceIndex, loop: LoopIndex, vertex: VertexIndex };

/// Make vertex, face, shell: a new shell with one face on `surface` whose one loop holds
/// the new vertex at `point` and no edge yet. The only legal first operation on a body.
pub fn mvfs(body: *Body, point: geometry.PointIndex, surface: geometry.SurfaceRef, same_sense: bool, kind: types.ShellKind) Error!Mvfs {
    try body.reserve(1);
    const shell = body.addShell(.{ .kind = kind }) catch unreachable;
    body.appendShell(shell);
    const face = body.addFace(.{ .surface = surface, .same_sense = same_sense, .shell = shell }) catch unreachable;
    body.appendFace(shell, face);
    const vertex = body.addVertex(.{ .point = point }) catch unreachable;
    const loop = body.addLoop(.{ .face = face, .vertex = vertex }) catch unreachable;
    body.appendLoop(face, loop);
    debugCheck(body);
    return .{ .shell = shell, .face = face, .loop = loop, .vertex = vertex };
}

/// Kill vertex, face, shell: the inverse of `mvfs`, for a shell of one face with one loop
/// of one vertex and no edge.
pub fn kvfs(body: *Body, shell: ShellIndex) Error!void {
    const sh = body.shell(shell);
    const face = sh.first_face;
    if (face == .none or body.face(face).next_in_shell != .none) return error.Invalid;
    const loop = body.face(face).first_loop;
    if (loop == .none or body.loop(loop).next_in_face != .none or body.loop(loop).first != .none) return error.Invalid;
    const vertex = body.loop(loop).vertex;
    if (vertex == .none) return error.Invalid;
    body.removeShell(shell);
    body.vertex(vertex).tombstone = true;
    body.loop(loop).tombstone = true;
    body.face(face).flags.tombstone = true;
    sh.tombstone = true;
    debugCheck(body);
}

// ---------------------------------------------------------------------------------------
// mev (three forms) / kev (two forms)

pub const Mev = struct { vertex: VertexIndex, edge: EdgeIndex, out: CoedgeIndex, back: CoedgeIndex };

/// Make edge, vertex, spur form: a new vertex at `point` and an edge from `from` to it,
/// its two coedges one after the other in `loop` right after `after` (a coedge of the loop
/// ending at `from`; `none` for a loop of just the vertex `from`). The edge's geometry
/// runs from `from` (`t0`) to the new vertex (`t1`).
pub fn mevSpur(body: *Body, loop: LoopIndex, after: CoedgeIndex, from: VertexIndex, point: geometry.PointIndex, geom: EdgeGeometry) Error!Mev {
    if (after == .none) {
        if (body.loop(loop).first != .none or body.loop(loop).vertex != from) return error.Invalid;
    } else {
        if (body.coedge(after).loop != loop or body.coedgeEnd(after) != from) return error.Invalid;
    }
    // Records are addressed by index after `reserve`: it may move the tables
    try body.reserve(1);
    const vertex = body.addVertex(.{ .point = point }) catch unreachable;
    const edge = body.addEdge(.{ .curve = geom.curve, .t0 = geom.t0, .t1 = geom.t1, .start = from, .end = vertex, .flags = geom.flags }) catch unreachable;
    const out = body.addCoedge(.{ .edge = edge, .same_sense = true, .loop = loop }) catch unreachable;
    const back = body.addCoedge(.{ .edge = edge, .same_sense = false, .loop = loop }) catch unreachable;
    body.edge(edge).coedge = out;
    body.coedge(out).partner = back;
    body.coedge(back).partner = out;
    body.vertex(vertex).coedge = back;
    if (body.vertex(from).coedge == .none) body.vertex(from).coedge = out;
    if (after == .none) {
        link(body, out, back);
        link(body, back, out);
        body.loop(loop).first = out;
        body.loop(loop).vertex = .none;
    } else {
        const following = body.coedge(after).next;
        link(body, after, out);
        link(body, out, back);
        link(body, back, following);
    }
    debugCheck(body);
    return .{ .vertex = vertex, .edge = edge, .out = out, .back = back };
}

/// Kill edge, vertex, spur form: the inverse of `mevSpur`. `out` is the coedge leaving the
/// surviving vertex along the spur (its partner follows it in the loop); the far vertex
/// and the edge go.
pub fn kevSpur(body: *Body, out: CoedgeIndex) Error!void {
    const o = body.coedge(out);
    const back = o.partner;
    if (back == .none or o.next != back) return error.Invalid;
    const far = body.coedgeEnd(out);
    const from = body.coedgeStart(out);
    const loop = o.loop;
    const after = o.prev;
    const following = body.coedge(back).next;
    if (after == back) {
        // The loop was just this spur: it becomes a loop of the vertex
        body.loop(loop).first = .none;
        body.loop(loop).vertex = from;
    } else {
        link(body, after, following);
        if (body.loop(loop).first == out or body.loop(loop).first == back) body.loop(loop).first = following;
    }
    if (body.vertex(from).coedge == out) body.vertex(from).coedge = if (after == back) .none else following;
    body.vertex(far).tombstone = true;
    body.edge(o.edge).flags.tombstone = true;
    o.tombstone = true;
    body.coedge(back).tombstone = true;
    debugCheck(body);
}

pub const Split = struct { vertex: VertexIndex, edge: EdgeIndex, forward: CoedgeIndex, backward: CoedgeIndex };

/// Make edge, vertex, split form: splits the edge of `coedge` at parameter `t` (strictly
/// inside its range) with a new vertex at `point`. The edge keeps `[t0, t]`; a new edge
/// takes `[t, t1]` with its own two coedges, each following its half in its loop.
pub fn mevSplitEdge(body: *Body, coedge: CoedgeIndex, t: f64, point: geometry.PointIndex) Error!Split {
    const forward = forwardCoedge(body, coedge);
    if (!(body.edge(body.coedge(forward).edge).t0 < t and t < body.edge(body.coedge(forward).edge).t1)) return error.Invalid;
    try body.reserve(1);
    const e = body.edge(body.coedge(forward).edge);
    const vertex = body.addVertex(.{ .point = point }) catch unreachable;
    const far = e.end;
    const edge2 = body.addEdge(.{ .curve = e.curve, .t0 = t, .t1 = e.t1, .start = vertex, .end = e.end, .flags = e.flags, .regularity = e.regularity, .tag = e.tag }) catch unreachable;
    e.t1 = t;
    e.end = vertex;
    const f2 = body.addCoedge(.{ .edge = edge2, .same_sense = true, .loop = body.coedge(forward).loop, .pcurve = body.coedge(forward).pcurve }) catch unreachable;
    body.edge(edge2).coedge = f2;
    const after_forward = body.coedge(forward).next;
    link(body, forward, f2);
    link(body, f2, after_forward);
    body.vertex(vertex).coedge = f2;
    const reverse = body.coedge(forward).partner;
    var b2: CoedgeIndex = .none;
    if (reverse != .none) {
        // The reverse traverses end → start: its new half (end → vertex) comes before it
        b2 = body.addCoedge(.{ .edge = edge2, .same_sense = false, .loop = body.coedge(reverse).loop, .pcurve = body.coedge(reverse).pcurve }) catch unreachable;
        const before_reverse = body.coedge(reverse).prev;
        link(body, before_reverse, b2);
        link(body, b2, reverse);
        body.coedge(f2).partner = b2;
        body.coedge(b2).partner = f2;
        // The reverse left the far vertex; now its new half does
        if (body.vertex(far).coedge == reverse) body.vertex(far).coedge = b2;
    }
    debugCheck(body);
    return .{ .vertex = vertex, .edge = edge2, .forward = f2, .backward = b2 };
}

/// Kill edge, vertex, join form: the inverse of `mevSplitEdge`. `coedge` traverses the
/// first half; the vertex at its end, of valence two with the next edge on the same curve
/// continuing the range, goes, and the edges join.
pub fn kevJoin(body: *Body, coedge: CoedgeIndex) Error!void {
    const forward = forwardCoedge(body, coedge);
    const f2 = body.coedge(forward).next;
    if (f2 == forward or !body.coedge(f2).same_sense) return error.Invalid;
    const e = body.edge(body.coedge(forward).edge);
    const e2 = body.edge(body.coedge(f2).edge);
    if (!e.curve.eql(e2.curve) or e.end != e2.start or e.t1 != e2.t0) return error.Invalid;
    const vertex = e.end;
    // Valence two: the only coedges leaving the vertex are f2 and the reverse of the first half
    const reverse = body.coedge(forward).partner;
    const b2 = body.coedge(f2).partner;
    if ((reverse == .none) != (b2 == .none)) return error.Invalid;
    if (reverse != .none and body.coedge(b2).next != reverse) return error.Invalid;
    e.t1 = e2.t1;
    e.end = e2.end;
    link(body, forward, body.coedge(f2).next);
    if (body.loop(body.coedge(forward).loop).first == f2) body.loop(body.coedge(forward).loop).first = forward;
    if (reverse != .none) {
        link(body, body.coedge(b2).prev, reverse);
        if (body.loop(body.coedge(reverse).loop).first == b2) body.loop(body.coedge(reverse).loop).first = reverse;
        body.coedge(b2).tombstone = true;
    }
    if (body.vertex(e.end).coedge == b2 and b2 != .none) body.vertex(e.end).coedge = body.coedge(forward).next;
    if (body.vertex(e.end).coedge == .none) body.vertex(e.end).coedge = body.coedge(forward).next;
    body.vertex(vertex).tombstone = true;
    e2.flags.tombstone = true;
    body.coedge(f2).tombstone = true;
    debugCheck(body);
}

/// Make edge, vertex, split-vertex form (Mäntylä's general MEV): the coedges leaving the
/// vertex `a` starts at, from `a` around to `b` (not `b` itself), move to a new vertex at
/// `point`, and a new edge joins the old vertex to the new one. `a` and `b` leave the same
/// vertex, which is manifold (every coedge around it has a partner); `a != b`.
pub fn mevSplitVertex(body: *Body, a: CoedgeIndex, b: CoedgeIndex, point: geometry.PointIndex, geom: EdgeGeometry) Error!Mev {
    if (a == b) return error.Invalid;
    const old = body.coedgeStart(a);
    if (body.coedgeStart(b) != old) return error.Invalid;
    // The fan, bounded by the umbrella walk
    var fan: [FAN_MAX]CoedgeIndex = undefined;
    var n: usize = 0;
    var it = traverse.Umbrella.initFrom(body, a);
    var found_b = false;
    while (try it.next()) |c| {
        if (c == b) {
            found_b = true;
            break;
        }
        if (n == FAN_MAX) return error.Invalid;
        fan[n] = c;
        n += 1;
        if (body.coedge(c).partner == .none) return error.Invalid;
    }
    if (!found_b or n == 0) return error.Invalid;
    try body.reserve(1);
    const vertex = body.addVertex(.{ .point = point }) catch unreachable;
    for (fan[0..n]) |c| {
        const e = body.edge(body.coedge(c).edge);
        if (body.coedge(c).same_sense) e.start = vertex else e.end = vertex;
    }
    body.vertex(vertex).coedge = a;
    const last = fan[n - 1];
    const edge = body.addEdge(.{ .curve = geom.curve, .t0 = geom.t0, .t1 = geom.t1, .start = old, .end = vertex, .flags = geom.flags }) catch unreachable;
    // c1 (old → new) before the last of the fan; c2 (new → old) after the partner of a
    const c1 = body.addCoedge(.{ .edge = edge, .same_sense = true, .loop = body.coedge(last).loop }) catch unreachable;
    const pa = body.coedge(a).partner;
    const c2 = body.addCoedge(.{ .edge = edge, .same_sense = false, .loop = body.coedge(pa).loop }) catch unreachable;
    body.edge(edge).coedge = c1;
    body.coedge(c1).partner = c2;
    body.coedge(c2).partner = c1;
    const before_last = body.coedge(last).prev;
    link(body, before_last, c1);
    link(body, c1, last);
    const after_pa = body.coedge(pa).next;
    link(body, pa, c2);
    link(body, c2, after_pa);
    if (body.vertex(old).coedge == .none or isInFan(body.vertex(old).coedge, fan[0..n])) body.vertex(old).coedge = c1;
    debugCheck(body);
    return .{ .vertex = vertex, .edge = edge, .out = c1, .back = c2 };
}

/// The most coedges a vertex's fan may hold in `mevSplitVertex`.
const FAN_MAX = 256;

fn isInFan(c: CoedgeIndex, fan: []const CoedgeIndex) bool {
    for (fan) |f| if (f == c) return true;
    return false;
}

/// Kill edge, vertex, join-vertex form: the inverse of `mevSplitVertex`. `out` is the
/// edge's coedge leaving the surviving vertex; the vertex at its end merges into it, every
/// coedge there moved over, and the edge goes.
pub fn kevMerge(body: *Body, out: CoedgeIndex) Error!void {
    const o = body.coedge(out);
    const back = o.partner;
    if (back == .none) return error.Invalid;
    const keep = body.coedgeStart(out);
    const gone = body.coedgeEnd(out);
    if (keep == gone) return error.Invalid;
    // Move every coedge leaving `gone` (but the edge's own) to `keep`
    var it = traverse.Umbrella.init(body, gone);
    var moved: usize = 0;
    while (try it.next()) |c| {
        const e = body.edge(body.coedge(c).edge);
        if (body.coedge(c).edge == o.edge) continue;
        if (body.coedge(c).same_sense) e.start = keep else e.end = keep;
        moved += 1;
    }
    // Unlink the two coedges from their loops
    const o_prev = o.prev;
    const o_next = o.next;
    const b_prev = body.coedge(back).prev;
    const b_next = body.coedge(back).next;
    if (o_next == back) {
        // A spur in one loop: handled as kevSpur would
        return error.Invalid;
    }
    link(body, o_prev, o_next);
    link(body, b_prev, b_next);
    fixLoopFirst(body, o.loop, out, o_next);
    fixLoopFirst(body, body.coedge(back).loop, back, b_next);
    if (body.vertex(keep).coedge == out) body.vertex(keep).coedge = o_next;
    body.vertex(gone).tombstone = true;
    body.edge(o.edge).flags.tombstone = true;
    o.tombstone = true;
    body.coedge(back).tombstone = true;
    debugCheck(body);
}

// ---------------------------------------------------------------------------------------
// mef / kef

pub const Mef = struct { edge: EdgeIndex, face: FaceIndex, loop: LoopIndex, in_new: CoedgeIndex, in_old: CoedgeIndex };

/// Make edge, face: `a` and `b` are two coedges of one loop; a new edge from the vertex
/// `a` starts at to the vertex `b` starts at splits the loop. The old loop keeps `a` up to
/// the coedge before `b`, closed by the new edge's reverse coedge; a new face on
/// `surface` takes `b` up to the coedge before `a`, closed by the new edge's forward
/// coedge (`in_new`). The edge's geometry runs from `a`'s start to `b`'s start.
pub fn mef(body: *Body, a: CoedgeIndex, b: CoedgeIndex, geom: EdgeGeometry, surface: geometry.SurfaceRef, same_sense: bool) Error!Mef {
    if (a == b or body.coedge(a).loop != body.coedge(b).loop) return error.Invalid;
    const old_loop = body.coedge(a).loop;
    const old_face = body.loop(old_loop).face;
    const shell = body.face(old_face).shell;
    const va = body.coedgeStart(a);
    const vb = body.coedgeStart(b);
    try body.reserve(1);
    const face = body.addFace(.{ .surface = surface, .same_sense = same_sense, .shell = shell }) catch unreachable;
    body.appendFace(shell, face);
    const loop = body.addLoop(.{ .face = face }) catch unreachable;
    body.appendLoop(face, loop);
    const edge = body.addEdge(.{ .curve = geom.curve, .t0 = geom.t0, .t1 = geom.t1, .start = va, .end = vb, .flags = geom.flags }) catch unreachable;
    const in_new = body.addCoedge(.{ .edge = edge, .same_sense = true, .loop = loop }) catch unreachable;
    const in_old = body.addCoedge(.{ .edge = edge, .same_sense = false, .loop = old_loop }) catch unreachable;
    body.edge(edge).coedge = in_new;
    body.coedge(in_new).partner = in_old;
    body.coedge(in_old).partner = in_new;
    const x = body.coedge(a).prev; // ends at va
    const y = body.coedge(b).prev; // ends at vb
    // Old loop: a … y, then vb → va
    link(body, y, in_old);
    link(body, in_old, a);
    body.loop(old_loop).first = a;
    // New loop: b … x, then va → vb
    link(body, x, in_new);
    link(body, in_new, b);
    body.loop(loop).first = b;
    var c = b;
    var steps: usize = 0;
    while (true) : (steps += 1) {
        if (steps > body.coedges.items.len) return error.Corrupt;
        body.coedge(c).loop = loop;
        c = body.coedge(c).next;
        if (c == b) break;
    }
    debugCheck(body);
    return .{ .edge = edge, .face = face, .loop = loop, .in_new = in_new, .in_old = in_old };
}

/// Kill edge, face: the inverse of `mef`. The edge of `coedge` separates two faces; the
/// face of `coedge`'s loop goes, its coedges joining the partner's loop.
pub fn kef(body: *Body, coedge: CoedgeIndex) Error!void {
    const c = body.coedge(coedge);
    const partner = c.partner;
    if (partner == .none or body.coedge(partner).loop == c.loop) return error.Invalid;
    const dying_loop = c.loop;
    const dying_face = body.loop(dying_loop).face;
    if (body.face(dying_face).first_loop != dying_loop or body.loop(dying_loop).next_in_face != .none) return error.Invalid;
    const keep_loop = body.coedge(partner).loop;
    const x = c.prev;
    const b = c.next;
    const y = body.coedge(partner).prev;
    const a = body.coedge(partner).next;
    // Splice: y → b … x → a …
    link(body, y, b);
    link(body, x, a);
    body.loop(keep_loop).first = a;
    var walk = b;
    var steps: usize = 0;
    while (walk != a) : (walk = body.coedge(walk).next) {
        if (steps > body.coedges.items.len) return error.Corrupt;
        steps += 1;
        body.coedge(walk).loop = keep_loop;
    }
    const va = body.coedgeStart(coedge);
    const vb = body.coedgeEnd(coedge);
    if (body.vertex(va).coedge == coedge) body.vertex(va).coedge = a;
    if (body.vertex(vb).coedge == partner) body.vertex(vb).coedge = b;
    body.removeFace(body.face(dying_face).shell, dying_face);
    body.face(dying_face).flags.tombstone = true;
    body.loop(dying_loop).tombstone = true;
    body.edge(c.edge).flags.tombstone = true;
    c.tombstone = true;
    body.coedge(partner).tombstone = true;
    debugCheck(body);
}

// ---------------------------------------------------------------------------------------
// kemr / mekr

/// Kill edge, make ring: the edge of `coedge` is used twice by one loop (a bridge to an
/// inner boundary); removing it leaves the loop and a new ring loop of the same face. The
/// ring is what follows `coedge`'s partner; the loop keeps what follows `coedge`.
pub fn kemr(body: *Body, coedge: CoedgeIndex) Error!LoopIndex {
    const c = body.coedge(coedge);
    const partner = c.partner;
    if (partner == .none or body.coedge(partner).loop != c.loop) return error.Invalid;
    const loop = c.loop;
    const face = body.loop(loop).face;
    const after_c = c.next;
    const before_c = c.prev;
    const after_p = body.coedge(partner).next;
    const before_p = body.coedge(partner).prev;
    if (after_c == partner or after_p == coedge) return error.Invalid; // a spur, not a bridge
    try body.reserve(1);
    const ring = body.addLoop(.{ .face = face }) catch unreachable;
    body.appendLoop(face, ring);
    link(body, before_c, after_p);
    link(body, before_p, after_c);
    body.loop(loop).first = after_c;
    body.loop(ring).first = after_p;
    var walk = after_p;
    var steps: usize = 0;
    while (true) : (steps += 1) {
        if (steps > body.coedges.items.len) return error.Corrupt;
        body.coedge(walk).loop = ring;
        walk = body.coedge(walk).next;
        if (walk == after_p) break;
    }
    const va = body.coedgeStart(coedge);
    const vb = body.coedgeEnd(coedge);
    if (body.vertex(va).coedge == coedge) body.vertex(va).coedge = after_p;
    if (body.vertex(vb).coedge == partner) body.vertex(vb).coedge = after_c;
    body.edge(c.edge).flags.tombstone = true;
    c.tombstone = true;
    body.coedge(partner).tombstone = true;
    debugCheck(body);
    return ring;
}

/// Make edge, kill ring: the inverse of `kemr`. `a` and `b` are coedges of two loops of one
/// face; a new edge from `a`'s start to `b`'s start joins the loops, `b`'s loop going.
pub fn mekr(body: *Body, a: CoedgeIndex, b: CoedgeIndex, geom: EdgeGeometry) Error!EdgeIndex {
    const la = body.coedge(a).loop;
    const lb = body.coedge(b).loop;
    if (la == lb or body.loop(la).face != body.loop(lb).face) return error.Invalid;
    const face = body.loop(la).face;
    const va = body.coedgeStart(a);
    const vb = body.coedgeStart(b);
    try body.reserve(1);
    const edge = body.addEdge(.{ .curve = geom.curve, .t0 = geom.t0, .t1 = geom.t1, .start = va, .end = vb, .flags = geom.flags }) catch unreachable;
    const c1 = body.addCoedge(.{ .edge = edge, .same_sense = true, .loop = la }) catch unreachable;
    const c2 = body.addCoedge(.{ .edge = edge, .same_sense = false, .loop = la }) catch unreachable;
    body.edge(edge).coedge = c1;
    body.coedge(c1).partner = c2;
    body.coedge(c2).partner = c1;
    const x = body.coedge(a).prev; // ends at va
    const y = body.coedge(b).prev; // ends at vb
    // a … x, va → vb, b … y, vb → va
    link(body, x, c1);
    link(body, c1, b);
    link(body, y, c2);
    link(body, c2, a);
    var walk = b;
    var steps: usize = 0;
    while (walk != c2) : (walk = body.coedge(walk).next) {
        if (steps > body.coedges.items.len) return error.Corrupt;
        steps += 1;
        body.coedge(walk).loop = la;
    }
    body.removeLoop(face, lb);
    body.loop(lb).tombstone = true;
    debugCheck(body);
    return edge;
}

// ---------------------------------------------------------------------------------------
// kfmrh / mfkrh

/// Kill face, make ring hole: face `hole` (of one loop) goes, its loop becoming a ring of
/// `keep`. In the same shell this raises the genus; in another shell it merges the shells,
/// `hole`'s shell going.
pub fn kfmrh(body: *Body, keep: FaceIndex, hole: FaceIndex) Error!void {
    if (keep == hole) return error.Invalid;
    const loop = body.face(hole).first_loop;
    if (loop == .none or body.loop(loop).next_in_face != .none) return error.Invalid;
    const hole_shell = body.face(hole).shell;
    const keep_shell = body.face(keep).shell;
    body.removeFace(hole_shell, hole);
    body.face(hole).flags.tombstone = true;
    body.loop(loop).face = keep;
    body.appendLoop(keep, loop);
    if (hole_shell != keep_shell) {
        // Move the rest of the shell over
        var f = body.shell(hole_shell).first_face;
        var steps: usize = 0;
        while (f != .none) {
            if (steps > body.faces.items.len) return error.Corrupt;
            steps += 1;
            const next = body.face(f).next_in_shell;
            body.appendFace(keep_shell, f);
            f = next;
        }
        body.shell(hole_shell).first_face = .none;
        body.removeShell(hole_shell);
        body.shell(hole_shell).tombstone = true;
    }
    debugCheck(body);
}

/// Make face, kill ring hole: the inverse of `kfmrh` within a shell. The ring `loop` (not
/// the outer loop of its face) becomes the outer loop of a new face on `surface` in the
/// same shell.
pub fn mfkrh(body: *Body, loop: LoopIndex, surface: geometry.SurfaceRef, same_sense: bool) Error!FaceIndex {
    const old_face = body.loop(loop).face;
    if (body.face(old_face).first_loop == loop) return error.Invalid;
    try body.reserve(1);
    const shell = body.face(old_face).shell;
    const face = body.addFace(.{ .surface = surface, .same_sense = same_sense, .shell = shell }) catch unreachable;
    body.appendFace(shell, face);
    body.removeLoop(old_face, loop);
    body.loop(loop).face = face;
    body.appendLoop(face, loop);
    debugCheck(body);
    return face;
}

// ---------------------------------------------------------------------------------------
// mvh / kvh

/// Make vertex, hole: a new loop of one vertex at `point` in `face`.
pub fn mvh(body: *Body, face: FaceIndex, point: geometry.PointIndex) Error!LoopIndex {
    try body.reserve(1);
    const vertex = body.addVertex(.{ .point = point }) catch unreachable;
    const loop = body.addLoop(.{ .face = face, .vertex = vertex }) catch unreachable;
    body.appendLoop(face, loop);
    debugCheck(body);
    return loop;
}

/// Kill vertex, hole: the inverse of `mvh`, for a ring loop of one vertex.
pub fn kvh(body: *Body, loop: LoopIndex) Error!void {
    const l = body.loop(loop);
    if (l.first != .none or l.vertex == .none or body.face(l.face).first_loop == loop) return error.Invalid;
    body.removeLoop(l.face, loop);
    body.vertex(l.vertex).tombstone = true;
    l.tombstone = true;
    debugCheck(body);
}

// ---------------------------------------------------------------------------------------
// slice_edge / merge_vertices

pub const Slice = struct { face: FaceIndex, edge: EdgeIndex };

/// Slice edge: a new edge beside the edge of `coedge`, between the same vertices on
/// `geom`'s curve, with a new two-edge face on `surface` between them: the old edge's far
/// coedge (`coedge`'s partner) moves to the new face, which also takes the new edge's
/// reverse coedge; the new edge's forward coedge takes the partner's old place.
pub fn sliceEdge(body: *Body, coedge: CoedgeIndex, geom: EdgeGeometry, surface: geometry.SurfaceRef, same_sense: bool) Error!Slice {
    const partner = body.coedge(coedge).partner;
    if (partner == .none) return error.Invalid;
    const va = body.coedgeStart(coedge);
    const vb = body.coedgeEnd(coedge);
    const shell = body.face(body.loop(body.coedge(coedge).loop).face).shell;
    try body.reserve(1);
    const face = body.addFace(.{ .surface = surface, .same_sense = same_sense, .shell = shell }) catch unreachable;
    body.appendFace(shell, face);
    const loop = body.addLoop(.{ .face = face }) catch unreachable;
    body.appendLoop(face, loop);
    const edge = body.addEdge(.{ .curve = geom.curve, .t0 = geom.t0, .t1 = geom.t1, .start = va, .end = vb, .flags = geom.flags }) catch unreachable;
    // The new edge's forward coedge (va → vb) takes the partner's place in its loop
    const n_forward = body.addCoedge(.{ .edge = edge, .same_sense = true, .loop = body.coedge(partner).loop }) catch unreachable;
    // ... no: the partner ran vb → va there; the replacement must too
    body.coedge(n_forward).same_sense = false;
    const n_reverse = body.addCoedge(.{ .edge = edge, .same_sense = true, .loop = loop }) catch unreachable;
    body.edge(edge).coedge = n_reverse;
    const p_prev = body.coedge(partner).prev;
    const p_next = body.coedge(partner).next;
    link(body, p_prev, n_forward);
    link(body, n_forward, p_next);
    if (body.loop(body.coedge(partner).loop).first == partner) body.loop(body.coedge(partner).loop).first = n_forward;
    body.coedge(n_forward).partner = n_reverse;
    body.coedge(n_reverse).partner = n_forward;
    // The new face: the old partner (vb → va on the old edge) then the new edge forward (va → vb)
    body.coedge(partner).loop = loop;
    link(body, partner, n_reverse);
    link(body, n_reverse, partner);
    body.loop(loop).first = partner;
    if (body.vertex(vb).coedge == partner) body.vertex(vb).coedge = n_forward;
    debugCheck(body);
    return .{ .face = face, .edge = edge };
}

/// Merge vertices: every edge at `gone` moves to `keep`; `gone` goes. The caller has
/// decided the two coincide (within `zone`); the result may have a two-edge loop or a
/// non-manifold vertex, which the checker reports.
pub fn mergeVertices(body: *Body, keep: VertexIndex, gone: VertexIndex) Error!void {
    if (keep == gone) return error.Invalid;
    for (body.edges.items) |*e| {
        if (e.flags.tombstone) continue;
        if (e.start == gone) e.start = keep;
        if (e.end == gone) e.end = keep;
    }
    if (body.vertex(keep).coedge == .none) body.vertex(keep).coedge = body.vertex(gone).coedge;
    body.vertex(gone).tombstone = true;
    debugCheck(body);
}

// ---------------------------------------------------------------------------------------

fn link(body: *Body, a: CoedgeIndex, b: CoedgeIndex) void {
    body.coedge(a).next = b;
    body.coedge(b).prev = a;
}

/// The coedge of `coedge`'s edge that traverses it forward.
fn forwardCoedge(body: *const Body, coedge: CoedgeIndex) CoedgeIndex {
    return if (body.coedge(coedge).same_sense) coedge else body.coedge(coedge).partner;
}

fn fixLoopFirst(body: *Body, loop: LoopIndex, removed: CoedgeIndex, replacement: CoedgeIndex) void {
    if (body.loop(loop).first == removed) body.loop(loop).first = replacement;
}
