const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const tessellate = @import("tessellate.zig");

pub const BoundingBox = struct {
    min: math.Vec3,
    max: math.Vec3,
};

/// Computes the B-Rep's exact structural genus (handles / holes) using Euler-Poincaré characteristics.
pub fn genus(allocator: std.mem.Allocator, t_arena: *const topo.TopologyArena, solid_id: topo.SolidId) i32 {
    const solid = t_arena.solids.items[solid_id];
    var v_set = std.AutoHashMap(topo.VertexId, void).init(allocator);
    defer v_set.deinit();

    var he_count: usize = 0;
    var f_count: usize = 0;
    var l_count: usize = 0;

    // Strictly isolate traversal to the requested solid
    for (0..solid.shells_len) |s_off| {
        const shell_id = t_arena.solid_shells.items[solid.shells_start + s_off];
        const shell = t_arena.shells.items[shell_id];
        f_count += shell.faces_len;

        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
            const face = t_arena.faces.items[face_id];
            l_count += face.loops_len;

            for (0..face.loops_len) |l_off| {
                const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
                const loop = t_arena.loops.items[loop_id];
                var curr_he = loop.first_half_edge;
                while (true) {
                    const he = t_arena.half_edges.items[curr_he];
                    he_count += 1;
                    v_set.put(he.start_vertex, {}) catch {};
                    curr_he = he.next;
                    if (curr_he == loop.first_half_edge) break;
                }
            }
        }
    }

    const v = @as(i32, @intCast(v_set.count()));
    const e = @as(i32, @intCast(he_count / 2));
    const f = @as(i32, @intCast(f_count));
    const l = @as(i32, @intCast(l_count));

    // Euler Formula accounting for faces with multiple boundaries (holes):
    // V - E + F - (L - F) = 2(1 - G)  ==> V - E + 2F - L
    const euler = v - e + (2 * f) - l;
    return @divTrunc(2 - euler, 2);
}

/// Evaluates the 3D axis-aligned bounding box (AABB) of the solid's active vertices.
pub fn boundingBox(t_arena: *const topo.TopologyArena, solid_id: topo.SolidId) ?BoundingBox {
    var min = [_]f64{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var max = [_]f64{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    var found = false;

    const s = t_arena.solids.items[solid_id];
    for (0..s.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[s.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face = t_arena.faces.items[t_arena.shell_faces.items[shell.faces_start + f_off]];
            for (0..face.loops_len) |l_off| {
                const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start + l_off]];
                var curr_he = loop.first_half_edge;
                while (true) {
                    const he = t_arena.half_edges.items[curr_he];
                    const pt = t_arena.vertices.items[he.start_vertex].point;
                    for (0..3) |i| {
                        if (pt[i] < min[i]) min[i] = pt[i];
                        if (pt[i] > max[i]) max[i] = pt[i];
                    }
                    found = true;
                    curr_he = he.next;
                    if (curr_he == loop.first_half_edge) break;
                }
            }
        }
    }
    if (!found) return null;
    return BoundingBox{ .min = min, .max = max };
}

/// Evaluates total physical solid volume using the Divergence Theorem on a tessellated representation.
pub fn volume(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    solid_id: topo.SolidId,
) f64 {
    var mesh = tessellate.Mesh{};
    defer mesh.deinit(allocator);

    tessellate.tessellateSolid(allocator, t_arena, g_arena, solid_id, &mesh, .{}) catch return 0.0;

    var vol: f64 = 0.0;
    for (mesh.triangles.items) |tri| {
        const p0 = mesh.vertices.items[tri[0]];
        const p1 = mesh.vertices.items[tri[1]];
        const p2 = mesh.vertices.items[tri[2]];

        const cross_x = p1[1] * p2[2] - p1[2] * p2[1];
        const cross_y = p1[2] * p2[0] - p1[0] * p2[2];
        const cross_z = p1[0] * p2[1] - p1[1] * p2[0];

        vol += (p0[0] * cross_x + p0[1] * cross_y + p0[2] * cross_z) / 6.0;
    }
    return @abs(vol);
}

/// Evaluates total 3D surface area via triangle magnitude sums.
pub fn surfaceArea(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    solid_id: topo.SolidId,
) f64 {
    var mesh = tessellate.Mesh{};
    defer mesh.deinit(allocator);

    tessellate.tessellateSolid(allocator, t_arena, g_arena, solid_id, &mesh, .{}) catch return 0.0;

    var area: f64 = 0.0;
    for (mesh.triangles.items) |tri| {
        const p0 = mesh.vertices.items[tri[0]];
        const p1 = mesh.vertices.items[tri[1]];
        const p2 = mesh.vertices.items[tri[2]];

        const v1x = p1[0] - p0[0];
        const v1y = p1[1] - p0[1];
        const v1z = p1[2] - p0[2];

        const v2x = p2[0] - p0[0];
        const v2y = p2[1] - p0[1];
        const v2z = p2[2] - p0[2];

        const cx = v1y * v2z - v1z * v2y;
        const cy = v1z * v2x - v1x * v2z;
        const cz = v1x * v2y - v1y * v2x;

        area += 0.5 * @sqrt(cx * cx + cy * cy + cz * cz);
    }
    return area;
}

/// Evaluates the 2D parametric area of a cross section using the Shoelace formula.
pub fn crossSectionArea(t_arena: *const topo.TopologyArena, solid_id: topo.SolidId) f64 {
    var total_area: f64 = 0.0;
    const face_id: u32 = @intCast(solid_id);
    if (face_id >= t_arena.faces.items.len) return 0.0;

    const face = t_arena.faces.items[face_id];
    for (0..face.loops_len) |l_off| {
        const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
        const loop = t_arena.loops.items[loop_id];
        var area: f64 = 0;
        var curr_he = loop.first_half_edge;

        while (true) {
            const he = t_arena.half_edges.items[curr_he];
            const next_he = t_arena.half_edges.items[he.next];
            const p1 = t_arena.vertices.items[he.start_vertex].point;
            const p2 = t_arena.vertices.items[next_he.start_vertex].point;

            area += (p1[0] * p2[1] - p2[0] * p1[1]);

            curr_he = he.next;
            if (curr_he == loop.first_half_edge) break;
        }
        total_area += area / 2.0;
    }
    return @abs(total_area);
}

/// Evaluates the 2D planar bounding box of a cross section.
pub fn crossSectionBounds(t_arena: *const topo.TopologyArena, solid_id: topo.SolidId) BoundingBox {
    var min = [_]f64{ std.math.inf(f64), std.math.inf(f64), 0 };
    var max = [_]f64{ -std.math.inf(f64), -std.math.inf(f64), 0 };

    const face_id: u32 = @intCast(solid_id);
    if (face_id >= t_arena.faces.items.len) return .{ .min = min, .max = max };

    const face = t_arena.faces.items[face_id];
    var found = false;

    for (0..face.loops_len) |l_off| {
        const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
        const loop = t_arena.loops.items[loop_id];
        var curr_he = loop.first_half_edge;

        while (true) {
            const he = t_arena.half_edges.items[curr_he];
            const pt = t_arena.vertices.items[he.start_vertex].point;

            if (pt[0] < min[0]) min[0] = pt[0];
            if (pt[1] < min[1]) min[1] = pt[1];
            if (pt[0] > max[0]) max[0] = pt[0];
            if (pt[1] > max[1]) max[1] = pt[1];
            found = true;

            curr_he = he.next;
            if (curr_he == loop.first_half_edge) break;
        }
    }

    if (!found) {
        min = .{ 0.0, 0.0, 0.0 };
        max = .{ 0.0, 0.0, 0.0 };
    }
    return .{ .min = min, .max = max };
}
