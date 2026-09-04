const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");

pub const UvTriangle = struct {
    uv1: math.Vec2,
    uv2: math.Vec2,
    uv3: math.Vec2,
};

pub const Mesh3D = struct {
    vertices: std.ArrayListUnmanaged(math.Vec3),
    indices: std.ArrayListUnmanaged([3]u32),

    pub fn deinit(self: *Mesh3D, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.indices.deinit(allocator);
    }
};

/// Projects a 2D UV triangulation onto a 3D NURBS surface.
/// Merges duplicate vertices that map to the same 3D coordinate (e.g., at singularities).
pub fn projectUvMeshTo3D(
    allocator: std.mem.Allocator,
    surface: *const geom.NurbsSurface,
    uv_triangles: []const UvTriangle,
) !Mesh3D {
    var mesh = Mesh3D{
        .vertices = .empty,
        .indices = .empty,
    };
    errdefer mesh.deinit(allocator);

    for (uv_triangles) |tri| {
        const uvs = [_]math.Vec2{ tri.uv1, tri.uv2, tri.uv3 };
        var tri_indices: [3]u32 = undefined;

        for (uvs, 0..) |uv, i| {
            const pt_3d = surface.evaluate(uv[0], uv[1]);

            // Deduplicate 3D vertices using a simple linear scan (sufficient for patches)
            var found_idx: ?u32 = null;
            for (mesh.vertices.items, 0..) |v, v_idx| {
                const dx = pt_3d[0] - v[0];
                const dy = pt_3d[1] - v[1];
                const dz = pt_3d[2] - v[2];
                if ((dx * dx + dy * dy + dz * dz) < 1e-10) {
                    found_idx = @intCast(v_idx);
                    break;
                }
            }

            if (found_idx) |idx| {
                tri_indices[i] = idx;
            } else {
                tri_indices[i] = @intCast(mesh.vertices.items.len);
                try mesh.vertices.append(allocator, pt_3d);
            }
        }

        // Discard degenerate triangles (zero 3D area)
        if (tri_indices[0] != tri_indices[1] and
            tri_indices[1] != tri_indices[2] and
            tri_indices[2] != tri_indices[0])
        {
            try mesh.indices.append(allocator, tri_indices);
        }
    }

    return mesh;
}
