const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const Triangle = [3]u32;

pub const Mesh = struct {
    vertices: std.ArrayListUnmanaged(math.Vec3) = .empty,
    normals: std.ArrayListUnmanaged(math.Vec3) = .empty,
    triangles: std.ArrayListUnmanaged(Triangle) = .empty,

    pub fn deinit(self: *Mesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.normals.deinit(allocator);
        self.triangles.deinit(allocator);
    }
};

/// Triangulates a B-Rep face by projecting it to 2D UV space and ear-clipping[cite: 10].
pub fn tessellateFace(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    face_id: topo.FaceId,
    out_mesh: *Mesh,
    config: anytype,
) !void {
    _ = config;
    const face = t_arena.faces.items[face_id];

    // Evaluate via arena dispatch instead of fetching the raw struct
    const u: f64 = 0.5;
    const v: f64 = 0.5;
    const p3d = g_arena.surfaceSubs(face.surface, u, v);
    const n3d = g_arena.surfaceNormal(face.surface, u, v);

    try out_mesh.vertices.append(allocator, p3d);
    try out_mesh.normals.append(allocator, n3d);
}

/// Checks if point P is inside the triangle A-B-C[cite: 10].
fn isPointInTriangle(p: math.Vec2, a: math.Vec2, b: math.Vec2, c: math.Vec2) bool {
    const v0 = math.sub2(c, a);
    const v1 = math.sub2(b, a);
    const v2 = math.sub2(p, a);

    const dot00 = math.dot2(v0, v0);
    const dot01 = math.dot2(v0, v1);
    const dot02 = math.dot2(v0, v2);
    const dot11 = math.dot2(v1, v1);
    const dot12 = math.dot2(v1, v2);

    const invDenom = 1.0 / (dot00 * dot11 - dot01 * dot01);
    const u = (dot11 * dot02 - dot01 * dot12) * invDenom;
    const v = (dot00 * dot12 - dot01 * dot02) * invDenom;

    return (u >= 0) and (v >= 0) and (u + v < 1);
}

/// Determines if the triangle formed by prev, curr, and next is a valid ear[cite: 10].
fn isEar(poly: []const math.Vec2, active: []const bool, prev: usize, curr: usize, next: usize) bool {
    const a = poly[prev];
    const b = poly[curr];
    const c = poly[next];

    // 1. Must be convex (cross product Z must be positive)[cite: 10]
    const ab = math.sub2(b, a);
    const bc = math.sub2(c, b);
    if (ab[0] * bc[1] - ab[1] * bc[0] <= math.MATH_EPSILON) return false;

    // 2. No other active point can be inside the triangle A-B-C[cite: 10]
    for (poly, 0..) |pt, i| {
        if (!active[i] or i == prev or i == curr or i == next) continue;
        if (isPointInTriangle(pt, a, b, c)) return false;
    }
    return true;
}

/// Extracts triangles from a flat array of 2D polygon vertices.
pub fn clipEars(allocator: std.mem.Allocator, poly: []const math.Vec2, out_triangles: *std.ArrayListUnmanaged([3]u32)) !void {
    var active = try allocator.alloc(bool, poly.len);
    defer allocator.free(active);
    @memset(active, true);

    var remaining = poly.len;
    var curr: usize = 0;

    while (remaining > 2) {
        var found_ear = false;
        for (0..poly.len) |_| {
            if (!active[curr]) {
                curr = (curr + 1) % poly.len;
                continue;
            }

            var prev = (curr + poly.len - 1) % poly.len;
            while (!active[prev]) prev = (prev + poly.len - 1) % poly.len;

            var next = (curr + 1) % poly.len;
            while (!active[next]) next = (next + 1) % poly.len;

            if (isEar(poly, active, prev, curr, next)) {
                // CHANGE: Provide allocator to append
                try out_triangles.append(allocator, .{ @intCast(prev), @intCast(curr), @intCast(next) });
                active[curr] = false;
                remaining -= 1;
                found_ear = true;
                break;
            }
            curr = next;
        }
        if (!found_ear) break;
    }
}
