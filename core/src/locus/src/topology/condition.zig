//! The condition of a shell, one vocabulary for a B-Rep shell and an output mesh
//! (research/truck.md §2, KNOWLEDGE §10): `irregular` < `regular` (every edge on at most
//! two faces) < `oriented` (the two uses of every edge run opposite) < `closed` (every
//! edge on exactly two faces), each condition implying the ones below it; and beside it
//! the vertices whose faces do not form one link (a singular vertex: two cones meeting at
//! their apex, two squares touching at a corner), which no edge count sees. The checker
//! reports a body's shells in these words (`check.Report.shells`) and the mesh validator
//! an output mesh's (`mesh/validate.zig`), so `CHECK_EDGE_PAIRS` is `closed` with no
//! singular vertex, whichever is graded.

const std = @import("std");
const diagnostics = @import("../diagnostics.zig");
const types = @import("types.zig");
const body_mod = @import("body.zig");
const traverse = @import("traverse.zig");
const Body = body_mod.Body;
const CoedgeIndex = types.CoedgeIndex;
const Diagnostics = diagnostics.Diagnostics;

pub const Error = error{ OutOfMemory, Corrupt };

/// Ordered: each implies the ones before it.
pub const Condition = enum(u8) {
    /// An edge on more than two faces (or none).
    irregular,
    /// Every edge on one or two faces.
    regular,
    /// And the two uses of every shared edge run opposite.
    oriented,
    /// And every edge on exactly two faces.
    closed,

    /// The lower of two conditions: what a set of edges is when each is graded alone.
    pub fn meet(a: Condition, b: Condition) Condition {
        return if (@backingInt(a) <= @backingInt(b)) a else b;
    }

    pub fn atLeast(self: Condition, other: Condition) bool {
        return @backingInt(self) >= @backingInt(other);
    }

    /// The word, for a finding or a report.
    pub fn word(self: Condition) []const u8 {
        return @tagName(self);
    }
};

/// What a shell or a mesh is: its condition and its singular vertices.
pub const Grade = struct {
    condition: Condition,
    /// How many vertices have faces that do not form one link.
    singular_vertices: u32 = 0,
    /// The first of them (a vertex index of the body or the mesh), when there is one.
    first_singular: ?u32 = null,
    /// The first edge (a body's edge index, or for a mesh the lower vertex of the pair)
    /// that keeps the condition from the next one up.
    first_short: ?u32 = null,

    /// `closed` with no singular vertex: a manifold solid's boundary.
    pub fn isManifoldClosed(self: Grade) bool {
        return self.condition == .closed and self.singular_vertices == 0;
    }
};

/// One edge's share of a grade: used by `uses` faces, its two uses running `opposite` ways
/// when it has two.
pub fn edgeCondition(uses: u32, opposite: bool) Condition {
    if (uses == 0 or uses > 2) return .irregular;
    if (uses == 1) return .oriented;
    return if (opposite) .closed else .regular;
}

/// A shell and its grade.
pub const ShellGrade = struct { shell: types.ShellIndex, grade: Grade };

/// The grade of every shell of `body`, appended to `out` in the order the shells are
/// listed: each live, non-degenerate edge of a shell's faces by its coedges in the shell
/// (a degenerate edge, a pole or an apex, has one by construction); and the singular
/// vertices over the whole body (two shells sharing a vertex record share a singular
/// vertex, which a shell alone cannot see), each charged to every shell with a coedge
/// leaving it.
pub fn ofBody(allocator: std.mem.Allocator, body: *const Body, out: *std.ArrayList(ShellGrade)) Error!void {
    const first = out.items.len;
    var shells = traverse.Shells.init(body);
    while (try shells.next()) |s| try out.append(allocator, .{ .shell = s, .grade = try edgesOf(allocator, body, s) });
    var leaving: Leaving = .empty;
    defer deinitLeaving(allocator, &leaving);
    for (out.items[first..]) |sg| try collectLeaving(allocator, body, sg.shell, &leaving);
    var singular: std.ArrayList(u32) = .empty;
    defer singular.deinit(allocator);
    try singularVertices(allocator, body, &leaving, &singular);
    for (singular.items) |v| {
        const list = leaving.get(v).?.items;
        for (out.items[first..]) |*sg| {
            var uses = false;
            for (list) |c| uses = uses or body.face(body.loop(body.coedge(c).loop).face).shell == sg.shell;
            if (!uses) continue;
            sg.grade.singular_vertices += 1;
            if (sg.grade.first_singular == null or v < sg.grade.first_singular.?) sg.grade.first_singular = v;
        }
    }
}

/// The grade of shell `s` of `body` alone: `ofBody`'s for one shell, its vertices judged
/// by its own coedges.
pub fn ofShell(allocator: std.mem.Allocator, body: *const Body, s: types.ShellIndex) Error!Grade {
    var grade = try edgesOf(allocator, body, s);
    var leaving: Leaving = .empty;
    defer deinitLeaving(allocator, &leaving);
    try collectLeaving(allocator, body, s, &leaving);
    var singular: std.ArrayList(u32) = .empty;
    defer singular.deinit(allocator);
    try singularVertices(allocator, body, &leaving, &singular);
    grade.singular_vertices = @intCast(singular.items.len);
    for (singular.items) |v| {
        if (grade.first_singular == null or v < grade.first_singular.?) grade.first_singular = v;
    }
    return grade;
}

/// The coedges leaving each vertex (by its index).
const Leaving = std.AutoHashMapUnmanaged(u32, std.ArrayList(CoedgeIndex));

fn deinitLeaving(allocator: std.mem.Allocator, leaving: *Leaving) void {
    var it = leaving.valueIterator();
    while (it.next()) |list| list.deinit(allocator);
    leaving.deinit(allocator);
}

/// Shell `s`'s condition by its edges' coedges in it.
fn edgesOf(allocator: std.mem.Allocator, body: *const Body, s: types.ShellIndex) Error!Grade {
    var grade: Grade = .{ .condition = .closed };
    var uses: std.AutoHashMapUnmanaged(u32, struct { count: u32, first: CoedgeIndex, opposite: bool }) = .empty;
    defer uses.deinit(allocator);
    var faces = traverse.Faces.init(body, s);
    while (try faces.next()) |f| {
        var loops = traverse.Loops.init(body, f);
        while (try loops.next()) |l| {
            var it = traverse.Coedges.init(body, l);
            while (try it.next()) |c| {
                const coedge = body.coedge(c);
                if (body.edge(coedge.edge).flags.degenerate) continue;
                const entry = try uses.getOrPut(allocator, @backingInt(coedge.edge));
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{ .count = 1, .first = c, .opposite = true };
                } else {
                    entry.value_ptr.count += 1;
                    if (entry.value_ptr.count == 2 and body.coedge(entry.value_ptr.first).same_sense == coedge.same_sense) entry.value_ptr.opposite = false;
                }
            }
        }
    }
    var edges = uses.iterator();
    while (edges.next()) |entry| {
        const c = edgeCondition(entry.value_ptr.count, entry.value_ptr.opposite);
        // The lowest condition, named by its lowest edge (the same whatever the hash order)
        if (!c.atLeast(grade.condition)) {
            grade.condition = c;
            grade.first_short = entry.key_ptr.*;
        } else if (c == grade.condition and c != .closed and entry.key_ptr.* < grade.first_short.?) {
            grade.first_short = entry.key_ptr.*;
        }
    }
    return grade;
}

/// Appends the coedges of shell `s` to the lists of the vertices they leave.
fn collectLeaving(allocator: std.mem.Allocator, body: *const Body, s: types.ShellIndex, leaving: *Leaving) Error!void {
    var faces = traverse.Faces.init(body, s);
    while (try faces.next()) |f| {
        var loops = traverse.Loops.init(body, f);
        while (try loops.next()) |l| {
            var it = traverse.Coedges.init(body, l);
            while (try it.next()) |c| {
                const list = try leaving.getOrPut(allocator, @backingInt(body.coedgeStart(c)));
                if (!list.found_existing) list.value_ptr.* = .empty;
                try list.value_ptr.append(allocator, c);
            }
        }
    }
}

/// The vertices whose leaving coedges fall into more than one fan, in increasing order: a
/// coedge and the partner of the coedge before it in its loop leave the vertex from
/// neighbouring faces; a degenerate coedge before it leaves the vertex too, from the same
/// face.
fn singularVertices(allocator: std.mem.Allocator, body: *const Body, leaving: *const Leaving, out: *std.ArrayList(u32)) Error!void {
    var fan: std.AutoHashMapUnmanaged(CoedgeIndex, CoedgeIndex) = .empty;
    defer fan.deinit(allocator);
    var vertices = leaving.iterator();
    while (vertices.next()) |entry| {
        const list = entry.value_ptr.items;
        if (list.len < 2) continue;
        fan.clearRetainingCapacity();
        for (list) |c| try fan.put(allocator, c, c);
        for (list) |c| {
            const prev = body.coedge(c).prev;
            if (prev == .none) continue;
            // A degenerate edge before it (a pole, an apex) starts and ends here: the fan
            // runs straight through it, in the same face
            if (body.edge(body.coedge(prev).edge).flags.degenerate and fan.contains(prev)) {
                unite(&fan, c, prev);
                continue;
            }
            const around = body.coedge(prev).partner;
            if (around == .none or !fan.contains(around)) continue;
            unite(&fan, c, around);
        }
        var roots: usize = 0;
        for (list) |c| roots += @intFromBool(find(&fan, c) == c);
        if (roots > 1) try out.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
}

fn find(parent: *std.AutoHashMapUnmanaged(CoedgeIndex, CoedgeIndex), c: CoedgeIndex) CoedgeIndex {
    var x = c;
    while (parent.get(x).? != x) x = parent.get(x).?;
    return x;
}

fn unite(parent: *std.AutoHashMapUnmanaged(CoedgeIndex, CoedgeIndex), a: CoedgeIndex, b: CoedgeIndex) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra == rb) return;
    // The lower index the root: the same fans whatever the order of the unions
    if (@backingInt(ra) < @backingInt(rb)) parent.putAssumeCapacity(rb, ra) else parent.putAssumeCapacity(ra, rb);
}
