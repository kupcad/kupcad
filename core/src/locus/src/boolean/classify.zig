//! The boolean's third phase (docs/architecture.md §7.4 step 4, KNOWLEDGE §7; Hoffmann
//! p.76–80, OCCT's `BRepClass3d_SClassifier`): each fragment classified once against the
//! other operand, at a point strictly inside it (the centroid of the largest triangle of
//! its triangulation). A fragment of a face lying in one plane with faces of the other
//! operand is decided first by those: inside one of them, it is the same domain, `on_same`
//! when their outward normals agree and `on_opposite` when they are opposed, never by a
//! ray. The others are inside or outside the other operand by `query/point_in_body.zig`'s
//! rays, one for each connected component of them (contagion, research/truck.md §3) and a
//! second that must agree; a point found on the other operand's boundary is a
//! contradiction of the paves (`unclassified`), refused.

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

    // The fragments lying on a coplanar face of the other operand, by their normals
    for (fragments.items.items, 0..) |fragment, i| {
        try options.checkCancel();
        try paves.coplanarWith(fragment.operand, fragment.face, &partners);
        if (partners.items.len == 0) continue;
        try samplesOf(allocator, paves, fragments, i, &samples, diag);
        const body = paves.operands[fragment.operand];
        if (try sameDomain(paves, body, types.FaceIndex.of(fragment.face), 1 - fragment.operand, samples.items, partners.items, diag)) |classified| {
            classes[i] = classified;
            decided[i] = true;
        }
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
            classes[i].class = @enumFromInt(class_of[root]);
            stats.by_contagion += 1;
            continue;
        }
        try samplesOf(allocator, paves, fragments, i, &samples, diag);
        const class = try byRay(allocator, paves, &indexes, fragment, samples.items, options, diag);
        stats.rays += 1;
        classes[i].class = class;
        if (class_of[root] == NO_CLASS) {
            class_of[root] = @intFromEnum(class);
            continue;
        }
        // The component's second ray: the consistency check
        stats.checks += 1;
        checked[root] = true;
        if (@intFromEnum(class) != class_of[root]) return diag.fail(error.IntersectionFailed, .{ .code = .unclassified, .entity = .of(.face, fragment.face), .label = "a fragment whose ray disagrees with the first ray of its component (fragments joined across pieces the other operand does not touch)" });
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
/// other's face that bounds it, and the next is not; 2026-11-13).
fn byRay(allocator: std.mem.Allocator, paves: *const Paves, indexes: *const [2]index_mod.FaceIndex, fragment: imprint.Fragment, samples: []const Vec3, options: diagnostics.Options, diag: *Diagnostics) Error!Class {
    const other = 1 - fragment.operand;
    for (samples) |p| {
        switch (try point_in_body.classify(allocator, paves.operands[other], &indexes[other], p, options, diag)) {
            .inside => return .inside,
            .outside => return .outside,
            .boundary => continue,
        }
    }
    return diag.fail(error.IntersectionFailed, .{ .code = .unclassified, .entity = .of(.face, fragment.face), .label = if (fragment.operand == 0) "a face of the first operand, classified against the second" else "a face of the second operand, classified against the first" });
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
    var decided: [2][]?Class = undefined;
    for (0..2) |k| {
        decided[k] = try allocator.alloc(?Class, paves.operands[k].shells.items.len);
        @memset(decided[k], null);
    }
    defer for (decided) |d| allocator.free(d);
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
        withoutSpurs(&ring);
        if (ring.items.len < 3) continue;
        try starts.append(allocator, @intCast(points.items.len));
        for (ring.items) |v| try points.append(allocator, planar_faces.flat(frame, paves.point(v)));
    }
    if (starts.items.len == 0) return;
    try starts.append(allocator, @intCast(points.items.len));
    try overlap.interiorPoints(allocator, frame, points.items, starts.items, edges.items, out);
}

/// The cycle `ring` with every spur taken out: wherever it runs `a b a` (out to `b` and
/// back), `b` and one `a` go, until none is left.
pub fn withoutSpurs(ring: *std.ArrayList(u32)) void {
    var changed = true;
    while (changed and ring.items.len >= 3) {
        changed = false;
        const n = ring.items.len;
        for (0..n) |k| {
            const before = ring.items[(k + n - 1) % n];
            const after = ring.items[(k + 1) % n];
            if (before != after) continue;
            // Drop the tip and the vertex after it (one of the two visits of `a`)
            const first = @min(k, (k + 1) % n);
            const second = @max(k, (k + 1) % n);
            _ = ring.orderedRemove(second);
            _ = ring.orderedRemove(first);
            changed = true;
            break;
        }
    }
    if (ring.items.len < 3) ring.clearRetainingCapacity();
}
