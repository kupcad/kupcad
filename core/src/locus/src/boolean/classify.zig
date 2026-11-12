//! The boolean's third phase (docs/architecture.md §7.4 step 4, KNOWLEDGE §7; Hoffmann
//! p.76–80, OCCT's `BRepClass3d_SClassifier`): each fragment classified once against the
//! other operand, at a point strictly inside it (the centroid of the largest triangle of
//! its triangulation). A fragment of a face lying in one plane with faces of the other
//! operand is decided first by those: inside one of them, it is the same domain, `on_same`
//! when their outward normals agree and `on_opposite` when they are opposed, never by a
//! ray. Any other fragment is inside or outside the other operand by
//! `query/point_in_body.zig`'s rays; its point found on the other operand's boundary is a
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

/// Each fragment's class, by index; owned by `allocator`.
pub fn run(allocator: std.mem.Allocator, paves: *const Paves, fragments: *const Fragments, options: diagnostics.Options, diag: *Diagnostics) Error![]Classified {
    var indexes: [2]index_mod.FaceIndex = undefined;
    indexes[0] = try index_mod.FaceIndex.build(allocator, paves.operands[0], diag);
    defer indexes[0].deinit(allocator);
    indexes[1] = try index_mod.FaceIndex.build(allocator, paves.operands[1], diag);
    defer indexes[1].deinit(allocator);
    const classes = try allocator.alloc(Classified, fragments.items.items.len);
    errdefer allocator.free(classes);
    var partners: std.ArrayList(u32) = .empty;
    defer partners.deinit(allocator);
    for (fragments.items.items, 0..) |fragment, i| {
        try options.checkCancel();
        const body = paves.operands[fragment.operand];
        const other = 1 - fragment.operand;
        const f = types.FaceIndex.of(fragment.face);
        const p = try sample(allocator, paves, fragments, i) orelse return diag.fail(error.Degenerate, .{ .code = .unclassified, .entity = .of(.face, fragment.face), .label = "a piece of a face with no area" });
        try paves.coplanarWith(fragment.operand, fragment.face, &partners);
        const same_domain: ?Classified = for (partners.items) |g| {
            const face_g = types.FaceIndex.of(g);
            if (try planar_faces.place(paves.operands[other], face_g, p, paves.tol, diag) != .inside) continue;
            const n_f = in_face.outwardNormal(body, f, .{ 0, 0 });
            const n_g = in_face.outwardNormal(paves.operands[other], face_g, .{ 0, 0 });
            break .{ .class = if (vec.dot(n_f, n_g) > 0) .on_same else .on_opposite, .partner = g };
        } else null;
        if (same_domain) |classified| {
            classes[i] = classified;
            continue;
        }
        classes[i].partner = NONE;
        classes[i].class = switch (try point_in_body.classify(allocator, paves.operands[other], &indexes[other], p, options, diag)) {
            .inside => .inside,
            .outside => .outside,
            .boundary => return diag.fail(error.IntersectionFailed, .{ .code = .unclassified, .entity = .of(.face, fragment.face), .label = if (fragment.operand == 0) "a face of the first operand, classified against the second" else "a face of the second operand, classified against the first" }),
        };
    }
    return classes;
}

/// A point strictly inside fragment `i`, as far from its edges as a triangle's centroid
/// gets, or null when it has no area. Its loops are triangulated without their spurs: a
/// section segment ending inside the face (the other operand touching it along a line from
/// one side) is an edge the loop runs there and back, which bounds no area and which the
/// triangulator, rightly, takes for a ring touching itself; the point keeps clear of it
/// all the same, since the other operand touches the face there (a centroid on the slit's
/// tip was found on the other's boundary, 2026-11-12).
fn sample(allocator: std.mem.Allocator, paves: *const Paves, fragments: *const Fragments, i: usize) Error!?Vec3 {
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
    if (starts.items.len == 0) return null;
    try starts.append(allocator, @intCast(points.items.len));
    return overlap.interiorPoint(allocator, frame, points.items, starts.items, edges.items);
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
