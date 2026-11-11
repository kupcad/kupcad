//! The mesh validator: an output mesh graded in the checker's words (`topology/
//! condition.zig`): `irregular`, `regular`, `oriented` or `closed` by its edges' uses (an
//! edge is a pair of vertex indices, its use a triangle's side, its direction the way the
//! triangle runs it), its singular vertices (the triangles about a vertex not one fan: the
//! sides opposite the vertex, its link, not one connected chain), and its degenerate
//! triangles (a corner repeated). A mesh is graded by its indices, as it was welded: two
//! vertices at one place are two vertices. `CHECK_EDGE_PAIRS` is `closed`.

const std = @import("std");
const condition = @import("../topology/condition.zig");

pub const Grade = condition.Grade;

pub const Verdict = struct {
    grade: Grade,
    /// Triangles with a corner repeated (no area by their indices).
    degenerate_triangles: u32 = 0,

    /// `closed`, no singular vertex, no degenerate triangle: a manifold solid's mesh.
    pub fn isManifoldClosed(self: Verdict) bool {
        return self.grade.isManifoldClosed() and self.degenerate_triangles == 0;
    }
};

/// The verdict on `triangles` (indices into `vertex_count` vertices).
pub fn grade(allocator: std.mem.Allocator, triangles: []const [3]u32, vertex_count: usize) error{OutOfMemory}!Verdict {
    var verdict: Verdict = .{ .grade = .{ .condition = .closed } };
    const Use = struct { count: u32, first_forward: bool, opposite: bool };
    var uses: std.AutoHashMapUnmanaged([2]u32, Use) = .empty;
    defer uses.deinit(allocator);
    // Each corner's link side: the side opposite the corner
    const Corner = struct { v: u32, a: u32, b: u32 };
    var corners: std.ArrayList(Corner) = .empty;
    defer corners.deinit(allocator);
    try corners.ensureTotalCapacity(allocator, 3 * triangles.len);
    for (triangles) |t| {
        if (t[0] == t[1] or t[1] == t[2] or t[0] == t[2]) {
            verdict.degenerate_triangles += 1;
            continue;
        }
        for (0..3) |k| {
            const from = t[k];
            const to = t[(k + 1) % 3];
            const forward = from < to;
            const key: [2]u32 = if (forward) .{ from, to } else .{ to, from };
            const entry = try uses.getOrPut(allocator, key);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{ .count = 1, .first_forward = forward, .opposite = true };
            } else {
                entry.value_ptr.count += 1;
                if (entry.value_ptr.count == 2 and entry.value_ptr.first_forward == forward) entry.value_ptr.opposite = false;
            }
            corners.appendAssumeCapacity(.{ .v = t[k], .a = t[(k + 1) % 3], .b = t[(k + 2) % 3] });
        }
    }
    var it = uses.iterator();
    while (it.next()) |entry| {
        const c = condition.edgeCondition(entry.value_ptr.count, entry.value_ptr.opposite);
        const low = entry.key_ptr[0];
        if (!c.atLeast(verdict.grade.condition)) {
            verdict.grade.condition = c;
            verdict.grade.first_short = low;
        } else if (c == verdict.grade.condition and c != .closed and low < verdict.grade.first_short.?) {
            verdict.grade.first_short = low;
        }
    }
    // Each vertex's link: its corners' opposite sides, one chain when the vertex is regular
    std.mem.sort(Corner, corners.items, {}, struct {
        fn lessThan(_: void, x: Corner, y: Corner) bool {
            return x.v < y.v;
        }
    }.lessThan);
    var parent: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parent.deinit(allocator);
    var start: usize = 0;
    while (start < corners.items.len) {
        var end = start + 1;
        while (end < corners.items.len and corners.items[end].v == corners.items[start].v) end += 1;
        const fan = corners.items[start..end];
        parent.clearRetainingCapacity();
        for (fan) |c| {
            if (!parent.contains(c.a)) try parent.put(allocator, c.a, c.a);
            if (!parent.contains(c.b)) try parent.put(allocator, c.b, c.b);
        }
        for (fan) |c| unite(&parent, c.a, c.b);
        var roots: usize = 0;
        var keys = parent.keyIterator();
        while (keys.next()) |k| roots += @intFromBool(find(&parent, k.*) == k.*);
        if (roots > 1) {
            verdict.grade.singular_vertices += 1;
            const v = fan[0].v;
            if (verdict.grade.first_singular == null or v < verdict.grade.first_singular.?) verdict.grade.first_singular = v;
        }
        start = end;
    }
    std.debug.assert(vertex_count == 0 or corners.items.len == 0 or corners.items[corners.items.len - 1].v < vertex_count);
    return verdict;
}

fn find(parent: *std.AutoHashMapUnmanaged(u32, u32), x0: u32) u32 {
    var x = x0;
    while (parent.get(x).? != x) x = parent.get(x).?;
    return x;
}

fn unite(parent: *std.AutoHashMapUnmanaged(u32, u32), a: u32, b: u32) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra == rb) return;
    if (ra < rb) parent.putAssumeCapacity(rb, ra) else parent.putAssumeCapacity(ra, rb);
}
