//! The gap between two solids (docs/architecture.md §7.6; KupCAD's `min_gap`): the least
//! distance between their boundaries when it is below `search`, `search` otherwise, 0
//! where they touch or cross (within the zone).
//!
//! A BVH-guided closest-point search: the two bodies' meshes (the host's, at their
//! resolutions, `mesh/tessellate.zig`) are searched for their nearest triangles by branch
//! and bound over the two triangle trees, keeping every pair of faces whose triangles come
//! within the meshes' own deviation of the nearest (twice the bow a chord as long as the
//! longest triangle side may have, `Resolution.chordBow`, for each mesh): the exact gap
//! lies among them. Each such pair is then polished on the exact faces by alternating
//! projection (the nearest point of one face to a point of the other, back and forth, a
//! face's nearest point its surface's foot when that is in the face, else the nearest
//! point of its edges), which converges to a pair of mutually nearest points (face to
//! face, face to edge, edge to edge, vertex); the least is the gap. So the answer is the
//! exact geometry's, not the meshes' (the mesh engine's gap between two cylinders is its
//! polygons'; the exact one is a chord's sagitta from it).

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const bvh_mod = @import("../spatial/bvh.zig");
const tessellate = @import("../mesh/tessellate.zig");
const in_face = @import("in_face.zig");
const Vec3 = vec.Vec3;
const Body = body_mod.Body;
const Box3 = geometry.Box3;
const Mesh = tessellate.Mesh;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// Face pairs polished at most: the nearest ones, past which the meshes say nothing new.
const MAX_PAIRS: usize = 64;
/// Alternating projections per pair at most.
const MAX_ROUNDS: usize = 64;
/// The meshes' deviation counted twice over (each mesh's bow, both ways).
const DEVIATION_FACTOR: f64 = 2;
/// The deepest pair stack of the branch-and-bound descent: each step leaves at most one
/// sibling pair behind per level of either tree, and a tree is at most 48 deep
/// (`spatial/bvh.zig`), so 2 · (48 + 48) + 2 suffice.
const MAX_STACK: usize = 256;

/// One body with its mesh, for the gap.
pub const Part = struct {
    body: *const Body,
    mesh: *const Mesh,
    resolution: tolerance.Resolution,
};

/// The least distance between the boundaries of `a` and `b` below `search`, `search`
/// otherwise; 0 where they touch or cross within the zone.
pub fn minGap(allocator: std.mem.Allocator, a: Part, b: Part, search: f64, options: diagnostics.Options, diag: *Diagnostics) Error!f64 {
    try options.checkCancel();
    if (a.mesh.triangles.len == 0 or b.mesh.triangles.len == 0 or !(search > 0)) return @max(search, 0);
    var tree_a = try triangleTree(allocator, a.mesh);
    defer tree_a.deinit(allocator);
    var tree_b = try triangleTree(allocator, b.mesh);
    defer tree_b.deinit(allocator);
    const face_a = try faceOfTriangle(allocator, a.mesh);
    defer allocator.free(face_a);
    const face_b = try faceOfTriangle(allocator, b.mesh);
    defer allocator.free(face_b);
    const margin = DEVIATION_FACTOR * (deviation(a) + deviation(b));

    // The nearest triangles, and every face pair within the margin of them
    var search_state: Search = .{ .allocator = allocator, .a = a.mesh, .b = b.mesh, .face_a = face_a, .face_b = face_b, .margin = margin, .best = search + margin };
    defer search_state.pairs.deinit(allocator);
    try search_state.run(&tree_a, &tree_b);
    if (search_state.pairs.count() == 0) return search;
    const nearest_mesh = search_state.nearest;

    // The pairs within the margin of the nearest, nearest first, polished
    var seeds: std.ArrayList(Seed) = .empty;
    defer seeds.deinit(allocator);
    var it = search_state.pairs.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.distance <= nearest_mesh + margin) try seeds.append(allocator, entry.value_ptr.*);
    }
    std.mem.sort(Seed, seeds.items, {}, Seed.lessThan);
    var gap = std.math.inf(f64);
    for (seeds.items[0..@min(seeds.items.len, MAX_PAIRS)]) |seed| {
        try options.checkCancel();
        gap = @min(gap, try polish(a.body, seed.fa, seed.pa, b.body, seed.fb, seed.pb, diag));
    }
    if (gap <= @max(a.body.tol.zone, b.body.tol.zone)) return 0;
    return @min(gap, search);
}

/// The bow a mesh's longest triangle side may have from the surface it chords.
fn deviation(part: Part) f64 {
    var longest: f64 = 0;
    for (part.mesh.triangles) |t| {
        for (0..3) |k| longest = @max(longest, vec.distance(part.mesh.positions[t[k]], part.mesh.positions[t[(k + 1) % 3]]));
    }
    return part.resolution.chordBow(longest);
}

/// A pair of faces and the nearest points of their nearest triangles.
const Seed = struct {
    fa: types.FaceIndex,
    fb: types.FaceIndex,
    pa: Vec3,
    pb: Vec3,
    distance: f64,

    fn lessThan(_: void, x: Seed, y: Seed) bool {
        return x.distance < y.distance or (x.distance == y.distance and (@backingInt(x.fa) < @backingInt(y.fa) or (x.fa == y.fa and @backingInt(x.fb) < @backingInt(y.fb))));
    }
};

/// The branch-and-bound descent of the two triangle trees: a pair of nodes farther apart
/// than the nearest triangles found plus the margin is cut.
const Search = struct {
    allocator: std.mem.Allocator,
    a: *const Mesh,
    b: *const Mesh,
    face_a: []const types.FaceIndex,
    face_b: []const types.FaceIndex,
    margin: f64,
    /// The cut: the nearest so far plus the margin (at first the search plus the margin).
    best: f64,
    nearest: f64 = std.math.inf(f64),
    pairs: std.AutoHashMapUnmanaged([2]u32, Seed) = .empty,

    fn run(self: *Search, ta: *const bvh_mod.Bvh, tb: *const bvh_mod.Bvh) Error!void {
        var stack: [MAX_STACK][2]u32 = undefined;
        var top: usize = 1;
        stack[0] = .{ 0, 0 };
        while (top > 0) {
            top -= 1;
            const ia = stack[top][0];
            const ib = stack[top][1];
            const na = ta.nodes[ia];
            const nb = tb.nodes[ib];
            if (boxDistance(na.box, nb.box) > self.best) continue;
            if (na.isLeaf() and nb.isLeaf()) {
                for (ta.items[na.right .. na.right + na.count]) |x| {
                    for (tb.items[nb.right .. nb.right + nb.count]) |y| try self.triangles(x, y, ta, tb);
                }
                continue;
            }
            std.debug.assert(top + 2 <= MAX_STACK);
            // Descend the larger node, the nearer child last so it is visited first
            const split_a = nb.isLeaf() or (!na.isLeaf() and na.box.extent() >= nb.box.extent());
            const first: [2]u32 = if (split_a) .{ ia + 1, ib } else .{ ia, ib + 1 };
            const second: [2]u32 = if (split_a) .{ na.right, ib } else .{ ia, nb.right };
            const d_first = boxDistance(ta.nodes[first[0]].box, tb.nodes[first[1]].box);
            const d_second = boxDistance(ta.nodes[second[0]].box, tb.nodes[second[1]].box);
            if (d_first <= d_second) {
                stack[top] = second;
                stack[top + 1] = first;
            } else {
                stack[top] = first;
                stack[top + 1] = second;
            }
            top += 2;
        }
    }

    fn triangles(self: *Search, x: u32, y: u32, ta: *const bvh_mod.Bvh, tb: *const bvh_mod.Bvh) Error!void {
        if (boxDistance(ta.boxes[x], tb.boxes[y]) > self.best) return;
        const tx = corners(self.a, x);
        const ty = corners(self.b, y);
        const near = triangleTriangle(tx, ty);
        if (near.distance > self.best) return;
        if (near.distance < self.nearest) {
            self.nearest = near.distance;
            self.best = near.distance + self.margin;
        }
        const key: [2]u32 = .{ @backingInt(self.face_a[x]), @backingInt(self.face_b[y]) };
        const entry = try self.pairs.getOrPut(self.allocator, key);
        if (!entry.found_existing or near.distance < entry.value_ptr.distance) {
            entry.value_ptr.* = .{ .fa = self.face_a[x], .fb = self.face_b[y], .pa = near.p, .pb = near.q, .distance = near.distance };
        }
    }
};

/// Alternating projection between face `fa` of `a` and face `fb` of `b` from the seed
/// points: the distance of the pair it settles on.
fn polish(a: *const Body, fa: types.FaceIndex, seed_a: Vec3, b: *const Body, fb: types.FaceIndex, seed_b: Vec3, diag: *Diagnostics) Error!f64 {
    // The seeds are on the meshes: onto the exact faces first
    var pa = try nearestOnFace(a, fa, seed_a, diag);
    var pb = try nearestOnFace(b, fb, seed_b, diag);
    const settle = @min(a.tol.approx, b.tol.approx);
    for (0..MAX_ROUNDS) |_| {
        const next_a = try nearestOnFace(a, fa, pb, diag);
        const next_b = try nearestOnFace(b, fb, next_a, diag);
        const moved = vec.distance(next_a, pa) + vec.distance(next_b, pb);
        pa = next_a;
        pb = next_b;
        if (moved <= settle) break;
    }
    return vec.distance(pa, pb);
}

/// The point of face `f` nearest `q`: the foot of `q` on the face's surface when that is
/// in the face (or on its boundary), else the nearest point of its edges.
fn nearestOnFace(body: *const Body, f: types.FaceIndex, q: Vec3, diag: *Diagnostics) Error!Vec3 {
    const uv = in_face.uvOf(body, f, q);
    const foot = body.geometry.surface(body.face(f).surface).eval(uv[0], uv[1]);
    if (try in_face.classify(body, f, foot, uv, body.tol.zone, diag) != .outside) return foot;
    var best = foot;
    var best_d = std.math.inf(f64);
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        if (body.loop(l).vertex != .none) {
            const p = body.point(body.loop(l).vertex);
            if (vec.distance(p, q) < best_d) {
                best = p;
                best_d = vec.distance(p, q);
            }
        }
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const p = in_face.nearestOnEdge(body, body.coedge(c).edge, q);
            const d = vec.distance(p, q);
            if (d < best_d) {
                best = p;
                best_d = d;
            }
        }
    }
    return best;
}

/// A BVH over a mesh's triangles. Owned by `allocator`.
fn triangleTree(allocator: std.mem.Allocator, mesh: *const Mesh) Error!bvh_mod.Bvh {
    const boxes = try allocator.alloc(Box3, mesh.triangles.len);
    defer allocator.free(boxes);
    for (mesh.triangles, boxes) |t, *box| {
        box.* = Box3.ofPoint(mesh.positions[t[0]]);
        box.grow(mesh.positions[t[1]]);
        box.grow(mesh.positions[t[2]]);
    }
    return bvh_mod.Bvh.build(allocator, boxes);
}

/// Each triangle's face, from the mesh's face ranges. Owned by `allocator`.
fn faceOfTriangle(allocator: std.mem.Allocator, mesh: *const Mesh) Error![]types.FaceIndex {
    const out = try allocator.alloc(types.FaceIndex, mesh.triangles.len);
    for (mesh.faces) |range| @memset(out[range.first .. range.first + range.count], range.face);
    return out;
}

fn corners(mesh: *const Mesh, t: u32) [3]Vec3 {
    const tri = mesh.triangles[t];
    return .{ mesh.positions[tri[0]], mesh.positions[tri[1]], mesh.positions[tri[2]] };
}

fn boxDistance(a: Box3, b: Box3) f64 {
    var sum: f64 = 0;
    for (0..3) |k| {
        const d = @max(0, @max(a.min[k] - b.max[k], b.min[k] - a.max[k]));
        sum += d * d;
    }
    return @sqrt(sum);
}

/// The nearest points of two triangles and their distance; 0 (at a common point) when
/// they meet.
pub const Near = struct { p: Vec3, q: Vec3, distance: f64 };

pub fn triangleTriangle(a: [3]Vec3, b: [3]Vec3) Near {
    // Crossing: an edge of one through the other
    for (0..3) |i| {
        if (segmentTriangle(a[i], a[(i + 1) % 3], b)) |p| return .{ .p = p, .q = p, .distance = 0 };
        if (segmentTriangle(b[i], b[(i + 1) % 3], a)) |p| return .{ .p = p, .q = p, .distance = 0 };
    }
    var best: Near = .{ .p = a[0], .q = b[0], .distance = std.math.inf(f64) };
    // A vertex against the other triangle
    for (a) |p| {
        const q = closestOnTriangle(p, b);
        const d = vec.distance(p, q);
        if (d < best.distance) best = .{ .p = p, .q = q, .distance = d };
    }
    for (b) |q| {
        const p = closestOnTriangle(q, a);
        const d = vec.distance(p, q);
        if (d < best.distance) best = .{ .p = p, .q = q, .distance = d };
    }
    // An edge against an edge
    for (0..3) |i| {
        for (0..3) |j| {
            const near = segmentSegment(a[i], a[(i + 1) % 3], b[j], b[(j + 1) % 3]);
            if (near.distance < best.distance) best = near;
        }
    }
    return best;
}

/// The point of triangle `t` nearest `p` (RTCD §5.1.5, by its Voronoi regions).
pub fn closestOnTriangle(p: Vec3, t: [3]Vec3) Vec3 {
    const a = t[0];
    const b = t[1];
    const c = t[2];
    const ab = vec.sub(b, a);
    const ac = vec.sub(c, a);
    const ap = vec.sub(p, a);
    const d1 = vec.dot(ab, ap);
    const d2 = vec.dot(ac, ap);
    if (d1 <= 0 and d2 <= 0) return a;
    const bp = vec.sub(p, b);
    const d3 = vec.dot(ab, bp);
    const d4 = vec.dot(ac, bp);
    if (d3 >= 0 and d4 <= d3) return b;
    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 and d1 >= 0 and d3 <= 0) return vec.addScaled(a, ab, d1 / (d1 - d3));
    const cp = vec.sub(p, c);
    const d5 = vec.dot(ab, cp);
    const d6 = vec.dot(ac, cp);
    if (d6 >= 0 and d5 <= d6) return c;
    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 and d2 >= 0 and d6 <= 0) return vec.addScaled(a, ac, d2 / (d2 - d6));
    const va = d3 * d6 - d5 * d4;
    if (va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0) return vec.addScaled(b, vec.sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6)));
    const denom = 1 / (va + vb + vc);
    return vec.add(a, vec.add(vec.scale(ab, vb * denom), vec.scale(ac, vc * denom)));
}

/// The nearest points of segments `p1 q1` and `p2 q2` (RTCD §5.1.9).
pub fn segmentSegment(p1: Vec3, q1: Vec3, p2: Vec3, q2: Vec3) Near {
    const d1 = vec.sub(q1, p1);
    const d2 = vec.sub(q2, p2);
    const r = vec.sub(p1, p2);
    const a = vec.dot(d1, d1);
    const e = vec.dot(d2, d2);
    const f = vec.dot(d2, r);
    var s: f64 = 0;
    var t: f64 = 0;
    if (a == 0 and e == 0) {
        // Both points
    } else if (a == 0) {
        t = std.math.clamp(f / e, 0, 1);
    } else {
        const c = vec.dot(d1, r);
        if (e == 0) {
            s = std.math.clamp(-c / a, 0, 1);
        } else {
            const b = vec.dot(d1, d2);
            const denom = a * e - b * b;
            s = if (denom != 0) std.math.clamp((b * f - c * e) / denom, 0, 1) else 0;
            t = (b * s + f) / e;
            if (t < 0) {
                t = 0;
                s = std.math.clamp(-c / a, 0, 1);
            } else if (t > 1) {
                t = 1;
                s = std.math.clamp((b - c) / a, 0, 1);
            }
        }
    }
    const p = vec.addScaled(p1, d1, s);
    const q = vec.addScaled(p2, d2, t);
    return .{ .p = p, .q = q, .distance = vec.distance(p, q) };
}

/// Where segment `p q` crosses triangle `t`, if it does (its ends on opposite sides of
/// the triangle's plane, or in it, and the crossing inside the triangle).
fn segmentTriangle(p: Vec3, q: Vec3, t: [3]Vec3) ?Vec3 {
    const n = vec.cross(vec.sub(t[1], t[0]), vec.sub(t[2], t[0]));
    const dp = vec.dot(n, vec.sub(p, t[0]));
    const dq = vec.dot(n, vec.sub(q, t[0]));
    if ((dp > 0 and dq > 0) or (dp < 0 and dq < 0)) return null;
    if (dp == dq) return null;
    const x = vec.lerp(p, q, dp / (dp - dq));
    // Inside: on the same side of every edge as the normal
    for (0..3) |i| {
        const edge_n = vec.cross(vec.sub(t[(i + 1) % 3], t[i]), vec.sub(x, t[i]));
        if (vec.dot(edge_n, n) < 0) return null;
    }
    return x;
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
