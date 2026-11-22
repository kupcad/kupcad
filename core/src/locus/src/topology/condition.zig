//! The condition of a shell, one vocabulary for a B-Rep shell and an output mesh
//! (research/truck.md §2, KNOWLEDGE §10): `irregular` < `regular` (every edge on at most
//! two faces) < `oriented` (the two uses of every edge run opposite) < `closed` (every
//! edge on exactly two faces), each condition implying the ones below it; and beside it
//! the vertices whose faces do not form one link (a singular vertex: two cones meeting at
//! their apex, two squares touching at a corner), which no edge count sees. The checker
//! reports a body's shells in these words (`check.Report.shells`) and the mesh validator
//! an output mesh's (`mesh/validate.zig`), so `CHECK_EDGE_PAIRS` is `closed` with no
//! singular vertex, whichever is graded. The singular-vertex test is Edelsbrunner's link
//! test on the records (a vertex's link one cycle, IV.13), which presumes the records form
//! a proper complex: contacts that are no shared record (a corner inside a face, two edges
//! on one segment) are the overlap rules' and the boolean's (`query/overlap.zig`,
//! `Solids`).

const std = @import("std");
const diagnostics = @import("../diagnostics.zig");
const types = @import("types.zig");
const body_mod = @import("body.zig");
const traverse = @import("traverse.zig");
const Body = body_mod.Body;
const CoedgeIndex = types.CoedgeIndex;
const Diagnostics = diagnostics.Diagnostics;

pub const Error = error{ OutOfMemory, Corrupt };

/// Bytes on the stack for a grade's scratch (the coedges leaving each vertex, a vertex's
/// fans, the singular vertices) before it takes the allocator: a box's or a cylinder's
/// fit, which a builder grades once each and frees at once (a page allocator maps and
/// unmaps an allocation alone in its size each time; 2026-11-22).
const SCRATCH_STACK_BYTES: usize = 4096;

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
    var buffer: [SCRATCH_STACK_BYTES]u8 align(@alignOf(u32)) = undefined;
    var first_buffer: std.heap.BufferFirstAllocator = .init(&buffer, allocator);
    const scratch = first_buffer.allocator();
    var leaving = try Leaving.of(scratch, body, .{ .graded = out.items[first..] });
    defer leaving.deinit(scratch);
    var singular: std.ArrayList(u32) = .empty;
    defer singular.deinit(scratch);
    try singularVertices(scratch, body, &leaving, &singular);
    for (singular.items) |v| {
        const list = leaving.get(v);
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
    var buffer: [SCRATCH_STACK_BYTES]u8 align(@alignOf(u32)) = undefined;
    var first_buffer: std.heap.BufferFirstAllocator = .init(&buffer, allocator);
    const scratch = first_buffer.allocator();
    var leaving = try Leaving.of(scratch, body, .{ .one = s });
    defer leaving.deinit(scratch);
    var singular: std.ArrayList(u32) = .empty;
    defer singular.deinit(scratch);
    try singularVertices(scratch, body, &leaving, &singular);
    grade.singular_vertices = @intCast(singular.items.len);
    for (singular.items) |v| {
        if (grade.first_singular == null or v < grade.first_singular.?) grade.first_singular = v;
    }
    return grade;
}

/// The coedges leaving each vertex (by its index), of the shells taken: every coedge by
/// the vertex it starts at, in the order the shells' faces give them within a vertex (a
/// counting sort), and where each vertex's run of them starts. One array for the body, not
/// a list a vertex: a 4,000-face polyhedron's pinch test spent most of its time making and
/// freeing them (2026-11-22).
const Leaving = struct {
    /// Where vertex `v`'s coedges start in `coedges`, and `start[v + 1]` where they end.
    start: []u32,
    coedges: []CoedgeIndex,

    /// The shells whose coedges are taken: one, those graded, or every one.
    const Shells = union(enum) {
        one: types.ShellIndex,
        graded: []const ShellGrade,
        all,
    };

    /// Two passes over the shells' coedges, counting each vertex's and then placing them
    /// from each run's end back (a counting sort in place): two allocations, made once,
    /// whatever the body's size (an allocation a builder makes for a moment, alone in its
    /// size, is mapped and unmapped each time by a page allocator).
    fn of(allocator: std.mem.Allocator, body: *const Body, shells: Shells) Error!Leaving {
        const start = try allocator.alloc(u32, body.vertices.items.len + 1);
        errdefer allocator.free(start);
        @memset(start, 0);
        var total: u32 = 0;
        try visit(body, shells, start, null, &total);
        // Each vertex's run ends where the next starts: counted from the front, then
        // filled from each end back, leaving `start[v]` at the run's start
        for (1..start.len) |k| start[k] += start[k - 1];
        const coedges = try allocator.alloc(CoedgeIndex, total);
        errdefer allocator.free(coedges);
        try visit(body, shells, start, coedges, &total);
        return .{ .start = start, .coedges = coedges };
    }

    /// The first pass (`coedges` null) counts a vertex's coedges into `start[v + 1]`; the
    /// second places each coedge at its vertex's run's end, moving `start[v + 1]` back,
    /// and afterwards shifts `start` so that `start[v]` begins vertex `v`'s run.
    fn visit(body: *const Body, shells: Shells, start: []u32, coedges: ?[]CoedgeIndex, total: *u32) Error!void {
        switch (shells) {
            .one => |s| try visitShell(body, s, start, coedges, total),
            .graded => |list| for (list) |sg| try visitShell(body, sg.shell, start, coedges, total),
            .all => {
                var it = traverse.Shells.init(body);
                while (try it.next()) |s| try visitShell(body, s, start, coedges, total);
            },
        }
        if (coedges == null) return;
        // The runs were filled from their ends: `start[v + 1]` now holds where vertex
        // `v`'s run starts; shift them down one
        std.mem.copyForwards(u32, start[0 .. start.len - 1], start[1..]);
        start[start.len - 1] = total.*;
    }

    fn visitShell(body: *const Body, s: types.ShellIndex, start: []u32, coedges: ?[]CoedgeIndex, total: *u32) Error!void {
        var faces = traverse.Faces.init(body, s);
        while (try faces.next()) |f| {
            var loops = traverse.Loops.init(body, f);
            while (try loops.next()) |l| {
                var it = traverse.Coedges.init(body, l);
                while (try it.next()) |c| {
                    const v = @backingInt(body.coedgeStart(c));
                    if (coedges) |out| {
                        start[v + 1] -= 1;
                        out[start[v + 1]] = c;
                    } else {
                        start[v + 1] += 1;
                        total.* += 1;
                    }
                }
            }
        }
    }

    fn deinit(self: *Leaving, allocator: std.mem.Allocator) void {
        allocator.free(self.start);
        allocator.free(self.coedges);
        self.* = undefined;
    }

    /// The coedges leaving vertex `v`.
    fn get(self: *const Leaving, v: u32) []const CoedgeIndex {
        return self.coedges[self.start[v]..self.start[v + 1]];
    }

    fn vertexCount(self: *const Leaving) u32 {
        return @intCast(self.start.len - 1);
    }
};

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

/// The vertices whose leaving coedges fall into more than one fan, in increasing order.
fn singularVertices(allocator: std.mem.Allocator, body: *const Body, leaving: *const Leaving, out: *std.ArrayList(u32)) Error!void {
    var fan: Fans = .{};
    defer fan.deinit(allocator);
    for (0..leaving.vertexCount()) |v| {
        if (try fan.of(allocator, body, leaving.get(@intCast(v))) > 1) try out.append(allocator, @intCast(v));
    }
}

/// The coedges leaving one vertex grouped into fans: a coedge and the partner of the
/// coedge before it in its loop leave the vertex from neighbouring faces; a degenerate
/// coedge before it leaves the vertex too, from the same face. A union-find over the
/// vertex's coedges sorted by index, each one's neighbour found by a binary search, each
/// fan's root its lowest coedge (whatever the order of the unions).
const Fans = struct {
    /// The vertex's coedges, by index.
    sorted: std.ArrayList(CoedgeIndex) = .empty,
    /// Each one's parent, by position in `sorted`.
    parent: std.ArrayList(u32) = .empty,

    fn deinit(self: *Fans, allocator: std.mem.Allocator) void {
        self.sorted.deinit(allocator);
        self.parent.deinit(allocator);
        self.* = undefined;
    }

    /// How many fans the coedges `list` leaving one vertex fall into.
    fn of(self: *Fans, allocator: std.mem.Allocator, body: *const Body, list: []const CoedgeIndex) Error!usize {
        self.sorted.clearRetainingCapacity();
        self.parent.clearRetainingCapacity();
        if (list.len < 2) return list.len;
        try self.sorted.appendSlice(allocator, list);
        std.sort.pdq(CoedgeIndex, self.sorted.items, {}, lessCoedge);
        try self.parent.resize(allocator, list.len);
        for (self.parent.items, 0..) |*p, i| p.* = @intCast(i);
        for (self.sorted.items, 0..) |c, i| {
            const prev = body.coedge(c).prev;
            if (prev == .none) continue;
            // A degenerate edge before it (a pole, an apex) starts and ends here: the fan
            // runs straight through it, in the same face
            if (body.edge(body.coedge(prev).edge).flags.degenerate) {
                if (self.position(prev)) |k| {
                    self.unite(@intCast(i), k);
                    continue;
                }
            }
            const around = body.coedge(prev).partner;
            if (around == .none) continue;
            self.unite(@intCast(i), self.position(around) orelse continue);
        }
        var roots: usize = 0;
        for (0..self.parent.items.len) |i| roots += @intFromBool(self.root(@intCast(i)) == i);
        return roots;
    }

    /// Where coedge `c` is in `sorted`, null when it leaves another vertex.
    fn position(self: *const Fans, c: CoedgeIndex) ?u32 {
        const Order = struct {
            fn order(key: CoedgeIndex, item: CoedgeIndex) std.math.Order {
                return std.math.order(@backingInt(key), @backingInt(item));
            }
        };
        const k = std.sort.binarySearch(CoedgeIndex, self.sorted.items, c, Order.order) orelse return null;
        return @intCast(k);
    }

    fn root(self: *Fans, i: u32) u32 {
        var x = i;
        while (self.parent.items[x] != x) {
            // Halving the path as it goes
            self.parent.items[x] = self.parent.items[self.parent.items[x]];
            x = self.parent.items[x];
        }
        return x;
    }

    /// Joins the fans of positions `a` and `b`; the lower position, the lower coedge, the
    /// root.
    fn unite(self: *Fans, a: u32, b: u32) void {
        const ra = self.root(a);
        const rb = self.root(b);
        if (ra == rb) return;
        if (ra < rb) self.parent.items[rb] = ra else self.parent.items[ra] = rb;
    }
};

/// One fan of a singular vertex: the vertex, and the shell of the faces about it.
pub const Fan = struct { vertex: u32, shell: types.ShellIndex };

/// Every fan of every singular vertex of `body` (a vertex whose faces about it are more
/// than one fan: shells touching there, or one touching itself), appended to `out` by
/// vertex, each vertex's fans by their lowest coedge.
pub fn fans(allocator: std.mem.Allocator, body: *const Body, out: *std.ArrayList(Fan)) Error!void {
    var buffer: [SCRATCH_STACK_BYTES]u8 align(@alignOf(u32)) = undefined;
    var first_buffer: std.heap.BufferFirstAllocator = .init(&buffer, allocator);
    const scratch = first_buffer.allocator();
    var leaving = try Leaving.of(scratch, body, .all);
    defer leaving.deinit(scratch);
    var fan: Fans = .{};
    defer fan.deinit(scratch);
    for (0..leaving.vertexCount()) |v| {
        if (try fan.of(scratch, body, leaving.get(@intCast(v))) < 2) continue;
        // The roots by position, so by coedge
        for (fan.sorted.items, 0..) |c, i| {
            if (fan.root(@intCast(i)) != i) continue;
            try out.append(allocator, .{ .vertex = @intCast(v), .shell = body.face(body.loop(body.coedge(c).loop).face).shell });
        }
    }
}

fn lessCoedge(_: void, a: CoedgeIndex, b: CoedgeIndex) bool {
    return @backingInt(a) < @backingInt(b);
}
