//! A mesh a file gives, checked and mended for the kernel, which takes only a closed mesh
//! (each edge on two triangles that run it opposite ways), as a slicer mends what it
//! imports. `check` says what is wrong; `repair` mends a mesh that isn't closed (one that
//! is stays as it is), step by step: triangles with a corner twice are dropped, and so are
//! duplicates (both of a pair facing opposite ways, an inner wall); the points of open
//! edges within the tolerance of each other are welded; the triangles of each connected
//! piece are turned to agree with their neighbours, as most of the piece's already do (so a
//! cavity's shell, wound inward on purpose, stays so); and each hole is filled, its loop of
//! open edges cut into triangles (core/triangulate.zig), or fanned from a corner where it
//! encloses nothing (the crack a T-junction leaves); a patch that only backs a sheet's own
//! triangles is dropped with them, so a sheet, which encloses nothing, comes out empty.
//! What is still wrong after (an edge on more than two triangles, a hole that isn't a
//! loop) is in the Report.

const std = @import("std");
const triangulate = @import("triangulate.zig");
const limits = @import("limits.zig");

pub const Mesh = struct { points: []const [3]f64, faces: []const [3]u32 };

/// What `check` found wrong, or what `repair` changed and what is still wrong.
pub const Report = struct {
    /// Changed: points welded into others, triangles dropped, triangles turned around,
    /// holes filled
    welded: usize = 0,
    dropped: usize = 0,
    turned: usize = 0,
    filled: usize = 0,
    /// Wrong: edges on one triangle only, on more than two, and on two that run it the same
    /// way; and the first wrong edge (by its points): its ends, and which it is
    open_edges: usize = 0,
    shared_edges: usize = 0,
    turned_edges: usize = 0,
    first: ?[2][3]f64 = null,
    first_kind: Fault = .open,

    pub const Fault = enum { open, shared, turned };

    pub fn closed(self: Report) bool {
        return self.open_edges == 0 and self.shared_edges == 0 and self.turned_edges == 0;
    }

    pub fn changed(self: Report) bool {
        return self.welded + self.dropped + self.turned + self.filled > 0;
    }
};

/// What is wrong with `mesh`.
pub fn check(allocator: std.mem.Allocator, mesh: Mesh) !Report {
    var edges = try Edges.of(allocator, mesh.faces);
    defer edges.deinit(allocator);
    var report: Report = .{};
    edges.judge(mesh.points, &report);
    return report;
}

/// A repaired mesh: its points and triangles owned by the allocator, and the report.
pub const Repaired = struct {
    points: [][3]f64,
    faces: [][3]u32,
    report: Report,

    pub fn deinit(self: Repaired, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.faces);
    }
};

/// `mesh` mended, its open edges' points within `tolerance` of each other welded; a mesh
/// that is closed comes back as it is (copied).
pub fn repair(allocator: std.mem.Allocator, mesh: Mesh, tolerance: f64) !Repaired {
    var report = try check(allocator, mesh);
    if (report.closed()) return .{ .points = try allocator.dupe([3]f64, mesh.points), .faces = try allocator.dupe([3]u32, mesh.faces), .report = report };
    report = .{};
    var faces: std.ArrayList([3]u32) = .empty;
    defer faces.deinit(allocator);
    try faces.appendSlice(allocator, mesh.faces);

    report.dropped += try dropRepeated(allocator, &faces);
    report.welded += try weldOpen(allocator, mesh.points, &faces, tolerance);
    report.dropped += try dropRepeated(allocator, &faces);
    report.turned += try orient(allocator, &faces);
    report.filled += try fillHoles(allocator, mesh.points, &faces);
    // A patch that is a triangle already there turned around closes a sheet, not a solid:
    // both go, so a mesh of sheets alone comes out empty
    report.dropped += try dropRepeated(allocator, &faces);

    var edges = try Edges.of(allocator, faces.items);
    defer edges.deinit(allocator);
    edges.judge(mesh.points, &report);
    // Only the points the triangles use, renumbered
    const index = try allocator.alloc(u32, mesh.points.len);
    defer allocator.free(index);
    @memset(index, std.math.maxInt(u32));
    var points: std.ArrayList([3]f64) = .empty;
    errdefer points.deinit(allocator);
    for (faces.items) |*face| for (face) |*corner| {
        if (index[corner.*] == std.math.maxInt(u32)) {
            index[corner.*] = @intCast(points.items.len);
            try points.append(allocator, mesh.points[corner.*]);
        }
        corner.* = index[corner.*];
    };
    const owned_points = try points.toOwnedSlice(allocator);
    errdefer allocator.free(owned_points);
    return .{ .points = owned_points, .faces = try faces.toOwnedSlice(allocator), .report = report };
}

/// Each edge's triangles: how many, and the first two, each with whether it runs the edge
/// from its lower point to its higher.
const Edges = struct {
    map: std.AutoHashMapUnmanaged(u64, Edge) = .empty,

    const Edge = struct { uses: u32 = 0, faces: [2]u32 = undefined, forward: [2]bool = undefined };

    fn of(allocator: std.mem.Allocator, faces: []const [3]u32) !Edges {
        var edges: Edges = .{};
        errdefer edges.deinit(allocator);
        try edges.map.ensureTotalCapacity(allocator, @intCast(@min(faces.len * 3 / 2 + 1, std.math.maxInt(u32))));
        for (faces, 0..) |face, f| for (0..3) |k| {
            const a = face[k];
            const b = face[(k + 1) % 3];
            const entry = try edges.map.getOrPut(allocator, key(a, b));
            if (!entry.found_existing) entry.value_ptr.* = .{};
            const e = entry.value_ptr;
            if (e.uses < 2) {
                e.faces[e.uses] = @intCast(f);
                e.forward[e.uses] = a < b;
            }
            e.uses += 1;
        };
        return edges;
    }

    fn deinit(self: *Edges, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }

    fn get(self: *const Edges, a: u32, b: u32) Edge {
        return self.map.get(key(a, b)).?;
    }

    /// Counts the wrong edges into `report`, the first of them its `first`.
    fn judge(self: *const Edges, points: []const [3]f64, report: *Report) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr.*;
            if (e.uses == 2 and e.forward[0] != e.forward[1]) continue;
            const fault: Report.Fault = if (e.uses == 1) .open else if (e.uses > 2) .shared else .turned;
            switch (fault) {
                .open => report.open_edges += 1,
                .shared => report.shared_edges += 1,
                .turned => report.turned_edges += 1,
            }
            const k = entry.key_ptr.*;
            const ends = [2][3]f64{ points[@as(u32, @truncate(k))], points[@as(u32, @intCast(k >> 32))] };
            // The first by its points, so the report is the same however the map runs
            if (report.first == null or lessPoint(ends[0], report.first.?[0]) or (std.meta.eql(ends[0], report.first.?[0]) and lessPoint(ends[1], report.first.?[1]))) {
                report.first = ends;
                report.first_kind = fault;
            }
        }
    }
};

fn key(a: u32, b: u32) u64 {
    return if (a < b) (@as(u64, b) << 32) | a else (@as(u64, a) << 32) | b;
}

fn lessPoint(a: [3]f64, b: [3]f64) bool {
    for (a, b) |x, y| if (x != y) return x < y;
    return false;
}

/// Drops the triangles with a corner twice, and duplicates: of the same corners the same
/// way round, all but the first; the same corners the other way round, both. How many.
fn dropRepeated(allocator: std.mem.Allocator, faces: *std.ArrayList([3]u32)) !usize {
    var seen: std.AutoHashMapUnmanaged([3]u32, struct { at: usize, odd: bool }) = .empty;
    defer seen.deinit(allocator);
    const keep = try allocator.alloc(bool, faces.items.len);
    defer allocator.free(keep);
    @memset(keep, true);
    for (faces.items, 0..) |face, f| {
        if (face[0] == face[1] or face[1] == face[2] or face[0] == face[2]) {
            keep[f] = false;
            continue;
        }
        var sorted = face;
        std.mem.sort(u32, &sorted, {}, std.sort.asc(u32));
        // Whether the face runs its corners in the sorted order's other way round
        const odd = !(face[0] == sorted[0] and face[1] == sorted[1] or face[1] == sorted[0] and face[2] == sorted[1] or face[2] == sorted[0] and face[0] == sorted[1]);
        const entry = try seen.getOrPut(allocator, sorted);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .at = f, .odd = odd };
        } else if (entry.value_ptr.odd == odd) {
            keep[f] = false;
        } else {
            // A wall of no thickness: neither side
            keep[f] = false;
            keep[entry.value_ptr.at] = false;
            _ = seen.remove(sorted);
        }
    }
    return compact(faces, keep);
}

fn compact(faces: *std.ArrayList([3]u32), keep: []const bool) usize {
    var n: usize = 0;
    for (faces.items, keep) |face, k| {
        if (!k) continue;
        faces.items[n] = face;
        n += 1;
    }
    const dropped = faces.items.len - n;
    faces.shrinkRetainingCapacity(n);
    return dropped;
}

/// Welds each point of an open edge onto the first such point within `tolerance` of it
/// (found through a grid of cells that wide). How many points were welded.
fn weldOpen(allocator: std.mem.Allocator, points: []const [3]f64, faces: *std.ArrayList([3]u32), tolerance: f64) !usize {
    var edges = try Edges.of(allocator, faces.items);
    defer edges.deinit(allocator);
    var open: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer open.deinit(allocator);
    var it = edges.map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.uses != 1) continue;
        try open.put(allocator, @truncate(entry.key_ptr.*), {});
        try open.put(allocator, @intCast(entry.key_ptr.* >> 32), {});
    }
    // In index order, so the same mesh welds the same way
    std.mem.sort(u32, open.keys(), {}, std.sort.asc(u32));
    var grid: std.AutoHashMapUnmanaged([3]i64, std.ArrayList(u32)) = .empty;
    defer {
        var cells = grid.valueIterator();
        while (cells.next()) |cell| cell.deinit(allocator);
        grid.deinit(allocator);
    }
    var onto: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer onto.deinit(allocator);
    for (open.keys()) |v| {
        const p = points[v];
        const cell = cellOf(p, tolerance);
        const found: ?u32 = search: for (0..27) |n| {
            const near = [3]i64{ cell[0] + @as(i64, @intCast(n % 3)) - 1, cell[1] + @as(i64, @intCast(n / 3 % 3)) - 1, cell[2] + @as(i64, @intCast(n / 9)) - 1 };
            for ((grid.get(near) orelse continue).items) |w| {
                if (distanceSq(p, points[w]) <= tolerance * tolerance) break :search w;
            }
        } else null;
        if (found) |w| {
            try onto.put(allocator, v, w);
            continue;
        }
        const entry = try grid.getOrPut(allocator, cell);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(allocator, v);
    }
    for (faces.items) |*face| for (face) |*corner| {
        if (onto.get(corner.*)) |w| corner.* = w;
    };
    return onto.count();
}

fn cellOf(p: [3]f64, size: f64) [3]i64 {
    var cell: [3]i64 = undefined;
    for (&cell, p) |*c, x| c.* = @intFromFloat(std.math.clamp(@floor(x / size), -1e15, 1e15));
    return cell;
}

fn distanceSq(a: [3]f64, b: [3]f64) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| sum += (x - y) * (x - y);
    return sum;
}

/// Turns triangles around so each agrees with its neighbours across the edges they share
/// (only two to an edge), piece by connected piece, as most of the piece already does. How
/// many triangles were turned.
fn orient(allocator: std.mem.Allocator, faces: *std.ArrayList([3]u32)) !usize {
    var edges = try Edges.of(allocator, faces.items);
    defer edges.deinit(allocator);
    const count = faces.items.len;
    const turn = try allocator.alloc(bool, count);
    defer allocator.free(turn);
    @memset(turn, false);
    const seen = try allocator.alloc(bool, count);
    defer allocator.free(seen);
    @memset(seen, false);
    var piece: std.ArrayList(u32) = .empty;
    defer piece.deinit(allocator);
    var turned: usize = 0;
    for (0..count) |seed| {
        if (seen[seed]) continue;
        // Walk the piece, each triangle turned to run their shared edge against the one it
        // was reached from
        piece.clearRetainingCapacity();
        try piece.append(allocator, @intCast(seed));
        seen[seed] = true;
        var next: usize = 0;
        while (next < piece.items.len) : (next += 1) {
            const f = piece.items[next];
            const face = faces.items[f];
            for (0..3) |k| {
                const e = edges.get(face[k], face[(k + 1) % 3]);
                if (e.uses != 2) continue;
                const slot: usize = if (e.faces[0] == f) 0 else 1;
                const other = e.faces[1 - slot];
                if (seen[other]) continue;
                seen[other] = true;
                // Turned when it runs the edge the way this one (as it will be) does
                turn[other] = e.forward[1 - slot] == (e.forward[slot] != turn[f]);
                try piece.append(allocator, other);
            }
        }
        // Most of the piece keeps its way round: if most were turned, turn the piece back
        var turned_here: usize = 0;
        for (piece.items) |f| turned_here += @intFromBool(turn[f]);
        const back = turned_here * 2 > piece.items.len;
        for (piece.items) |f| {
            if (back) turn[f] = !turn[f];
            if (!turn[f]) continue;
            std.mem.swap(u32, &faces.items[f][1], &faces.items[f][2]);
            turned += 1;
        }
    }
    return turned;
}

/// Fills each hole: its loop of open edges, walked against the triangles' way round, cut
/// into triangles, or fanned from a corner where it encloses nothing or can't be cut. How
/// many holes were filled; an open run that doesn't close into a loop stays.
fn fillHoles(allocator: std.mem.Allocator, points: []const [3]f64, faces: *std.ArrayList([3]u32)) !usize {
    var edges = try Edges.of(allocator, faces.items);
    defer edges.deinit(allocator);
    // Each open edge as its triangle runs it, by where it starts
    var out: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var lists = out.valueIterator();
        while (lists.next()) |list| list.deinit(allocator);
        out.deinit(allocator);
    }
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(allocator);
    for (faces.items) |face| for (0..3) |k| {
        const a = face[k];
        const b = face[(k + 1) % 3];
        if (edges.get(a, b).uses != 1) continue;
        const entry = try out.getOrPut(allocator, a);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(allocator, b);
        try starts.append(allocator, a);
    };
    var filled: usize = 0;
    var loop: std.ArrayList(u32) = .empty;
    defer loop.deinit(allocator);
    // Where each point is in the walk's loop
    var position: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer position.deinit(allocator);
    for (starts.items) |start| {
        if (out.getPtr(start).?.items.len == 0) continue;
        // Walk the open edges from `start`. Each time the walk comes back to a point of its
        // loop, the part since that point is a hole of its own (holes that touch at a point
        // share it, and the walk may have turned from one into the other there): filled,
        // and the walk goes on from that point
        loop.clearRetainingCapacity();
        position.clearRetainingCapacity();
        var at = start;
        while (true) {
            if (position.get(at)) |i| {
                filled += try fillLoop(allocator, points, loop.items[i..], faces);
                for (loop.items[i..]) |v| _ = position.remove(v);
                loop.shrinkRetainingCapacity(i);
            }
            try position.put(allocator, at, loop.items.len);
            try loop.append(allocator, at);
            const next = out.getPtr(at) orelse break;
            // A run that doesn't come back: no hole to fill
            at = next.pop() orelse break;
        }
    }
    return filled;
}

/// Fills the hole whose loop of open edges is `loop`, as the triangles beside it run them:
/// the patch runs it the other way. How many holes that was (none for a loop of less than
/// three points).
fn fillLoop(allocator: std.mem.Allocator, points: []const [3]f64, loop: []u32, faces: *std.ArrayList([3]u32)) !usize {
    if (loop.len < 3) return 0;
    std.mem.reverse(u32, loop);
    try patch(allocator, points, loop, faces);
    return 1;
}

/// The triangles of the hole whose loop is `corners`, onto `faces`.
fn patch(allocator: std.mem.Allocator, points: []const [3]f64, corners: []const u32, faces: *std.ArrayList([3]u32)) !void {
    if (corners.len <= limits.MAX_FACE_CORNERS) {
        const before = faces.items.len;
        if (triangulate.face(allocator, points, corners, faces)) |_| return else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Degenerate, error.SelfIntersecting => faces.shrinkRetainingCapacity(before),
        }
    }
    for (1..corners.len - 1) |i| try faces.append(allocator, .{ corners[0], corners[i], corners[i + 1] });
}
