const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const Triangle = [3]u32;
pub const Mesh = struct {
    vertices: std.ArrayListUnmanaged(math.Vec3) = .empty,
    normals: std.ArrayListUnmanaged(math.Vec3) = .empty,
    triangles: std.ArrayListUnmanaged(Triangle) = .empty,
};

/// Triangulates a B-Rep face by projecting it to 2D UV space and ear-clipping.
pub fn tessellateFace(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    face_id: topo.FaceId,
    out_mesh: *Mesh,
    chordal_deflection: f64,
) !void {
    _ = chordal_deflection;
    const face = t_arena.faces.items[face_id];
    const surf = g_arena.surfaces.items[face.surface_idx];

    // 1. Extract the outer wire and inner hole wires[cite: 31].
    // 2. Map 3D wire vertices to 2D (u, v) points on the surface[cite: 31].

    // 3. If there are holes, find the minimum-X point of the hole and "bridge" it
    // to the nearest point on the outer contour, merging them into a single polygon[cite: 31].

    // 4. Ear-Clipping Loop[cite: 31]:
    // Iterate through polygon vertices. A vertex is an "ear" if:
    //   a. The interior angle is convex.
    //   b. No other vertices lie inside the triangle formed by the ear[cite: 31].
    // Clip the ear, push the triangle to `out_mesh`, and remove the vertex. Repeat until 3 vertices remain.

    // 5. Evaluate the 3D position and normal for the resulting UV triangles using `surf.subs(u,v)`[cite: 31].
    const u: f64 = 0.5; // Dummy
    const v: f64 = 0.5;
    const p3d = surf.subs(u, v);
    const n3d = surf.normal(u, v);

    try out_mesh.vertices.append(allocator, p3d);
    try out_mesh.normals.append(allocator, n3d);
}
