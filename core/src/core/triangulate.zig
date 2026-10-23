//! A polyhedron's face of any number of corners as triangles, for the kernels, which take
//! triangles: the face's corners, in order, are put on its own plane (the Newell normal's)
//! and ear-clipped there, so a concave face is cut along its inside, and every triangle
//! turns the way the face does (its outward side stays outward). Both engines get the same
//! triangles.

const std = @import("std");
const vec3 = @import("vec3.zig");

pub const Error = error{
    /// The corners enclose no area: they are in a line, or one point.
    Degenerate,
    /// No corner can be cut off: the face's outline crosses itself.
    SelfIntersecting,
} || std.mem.Allocator.Error;

/// Appends the triangles of the face whose corners are `points[face[i]]`, in order (three
/// or more, each corner once), to `out`, as indices into `points`.
pub fn face(allocator: std.mem.Allocator, points: []const [3]f64, corners: []const u32, out: *std.ArrayList([3]u32)) Error!void {
    std.debug.assert(corners.len >= 3);
    if (corners.len == 3) return out.append(allocator, .{ corners[0], corners[1], corners[2] });

    const normal = newellNormal(points, corners);
    const length = @sqrt(vec3.dot(normal, normal));
    if (!(length > 0)) return error.Degenerate;
    const n = vec3.scale(normal, 1 / length);
    // A basis of the plane, u then v = n × u, so the face runs counter-clockwise in it
    const u = vec3.normalize(firstEdge(points, corners) orelse return error.Degenerate);
    const v = vec3.cross(n, u);

    const flat = try allocator.alloc([2]f64, corners.len);
    defer allocator.free(flat);
    for (corners, flat) |c, *p| p.* = .{ vec3.dot(points[c], u), vec3.dot(points[c], v) };

    // The corners still uncut, as positions in `corners`
    var left: std.ArrayList(u32) = .empty;
    defer left.deinit(allocator);
    try left.ensureTotalCapacity(allocator, corners.len);
    for (0..corners.len) |i| left.appendAssumeCapacity(@intCast(i));

    try out.ensureUnusedCapacity(allocator, corners.len - 2);
    while (left.items.len > 3) {
        const at = findEar(flat, left.items) orelse return error.SelfIntersecting;
        const count = left.items.len;
        const a = left.items[(at + count - 1) % count];
        const b = left.items[at];
        const c = left.items[(at + 1) % count];
        out.appendAssumeCapacity(.{ corners[a], corners[b], corners[c] });
        _ = left.orderedRemove(at);
    }
    out.appendAssumeCapacity(.{ corners[left.items[0]], corners[left.items[1]], corners[left.items[2]] });
}

/// The face's normal by Newell's method, its length twice the face's area: the sum over
/// the edges, which a slightly bent face still gets a fair plane from.
fn newellNormal(points: []const [3]f64, corners: []const u32) [3]f64 {
    var normal: [3]f64 = @splat(0);
    for (corners, 0..) |c, i| {
        const p = points[c];
        const q = points[corners[(i + 1) % corners.len]];
        normal[0] += (p[1] - q[1]) * (p[2] + q[2]);
        normal[1] += (p[2] - q[2]) * (p[0] + q[0]);
        normal[2] += (p[0] - q[0]) * (p[1] + q[1]);
    }
    return normal;
}

fn firstEdge(points: []const [3]f64, corners: []const u32) ?[3]f64 {
    for (corners, 0..) |c, i| {
        const e = vec3.sub(points[corners[(i + 1) % corners.len]], points[c]);
        if (vec3.dot(e, e) > 0) return e;
    }
    return null;
}

/// A corner of `left` (a counter-clockwise outline in `flat`) that can be cut off: it turns
/// left and no other corner lies in the triangle it makes with its neighbours.
fn findEar(flat: []const [2]f64, left: []const u32) ?usize {
    const count = left.len;
    for (0..count) |at| {
        const a = flat[left[(at + count - 1) % count]];
        const b = flat[left[at]];
        const c = flat[left[(at + 1) % count]];
        if (turn(a, b, c) <= 0) continue;
        const clear = for (left, 0..) |other, k| {
            if (k == at or k == (at + count - 1) % count or k == (at + 1) % count) continue;
            if (inTriangle(flat[other], a, b, c)) break false;
        } else true;
        if (clear) return at;
    }
    return null;
}

/// Twice the signed area of a, b, c: positive when they turn left.
fn turn(a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

/// Whether `p` is in the counter-clockwise triangle a, b, c or on its edges.
fn inTriangle(p: [2]f64, a: [2]f64, b: [2]f64, c: [2]f64) bool {
    return turn(a, b, p) >= 0 and turn(b, c, p) >= 0 and turn(c, a, p) >= 0;
}
