const std = @import("std");
const topo_arena = @import("arena.zig");
const geom_arena = @import("../geometry/arena.zig");

pub const Checkpoint = struct {
    // Topology Array Bounds
    vertices_len: usize,
    half_edges_len: usize,
    loops_len: usize,
    faces_len: usize,
    shells_len: usize,
    solids_len: usize,
    face_loops_len: usize,
    shell_faces_len: usize,
    solid_shells_len: usize,

    // Geometry Array Bounds
    points_len: usize,
    lines_len: usize,
    circle_arcs_len: usize,
    planes_len: usize,
    spheres_len: usize,
    cylinders_len: usize,
    cones_len: usize,
    toruses_len: usize,
    nurbs_curves_len: usize,
    nurbs_surfaces_len: usize,

    /// Captures the current length of all arena buffers in O(1) time.
    pub fn save(t: *const topo_arena.TopologyArena, g: *const geom_arena.GeometryArena) Checkpoint {
        return .{
            .vertices_len = t.vertices.items.len,
            .half_edges_len = t.half_edges.items.len,
            .loops_len = t.loops.items.len,
            .faces_len = t.faces.items.len,
            .shells_len = t.shells.items.len,
            .solids_len = t.solids.items.len,
            .face_loops_len = t.face_loops.items.len,
            .shell_faces_len = t.shell_faces.items.len,
            .solid_shells_len = t.solid_shells.items.len,

            .points_len = g.points.items.len,
            .lines_len = g.lines.items.len,
            .circle_arcs_len = g.circle_arcs.items.len,
            .planes_len = g.planes.items.len,
            .spheres_len = g.spheres.items.len,
            .cylinders_len = g.cylinders.items.len,
            .cones_len = g.cones.items.len,
            .toruses_len = g.toruses.items.len,
            .nurbs_curves_len = g.nurbs_curves.items.len,
            .nurbs_surfaces_len = g.nurbs_surfaces.items.len,
        };
    }

    /// Rollbacks both arenas to the exact checkpoint state without releasing capacity.
    pub fn restore(t: *topo_arena.TopologyArena, g: *geom_arena.GeometryArena, cp: Checkpoint) void {
        t.vertices.shrinkRetainingCapacity(cp.vertices_len);
        t.half_edges.shrinkRetainingCapacity(cp.half_edges_len);
        t.loops.shrinkRetainingCapacity(cp.loops_len);
        t.faces.shrinkRetainingCapacity(cp.faces_len);
        t.shells.shrinkRetainingCapacity(cp.shells_len);
        t.solids.shrinkRetainingCapacity(cp.solids_len);
        t.face_loops.shrinkRetainingCapacity(cp.face_loops_len);
        t.shell_faces.shrinkRetainingCapacity(cp.shell_faces_len);
        t.solid_shells.shrinkRetainingCapacity(cp.solid_shells_len);

        g.points.shrinkRetainingCapacity(cp.points_len);
        g.lines.shrinkRetainingCapacity(cp.lines_len);
        g.circle_arcs.shrinkRetainingCapacity(cp.circle_arcs_len);
        g.planes.shrinkRetainingCapacity(cp.planes_len);
        g.spheres.shrinkRetainingCapacity(cp.spheres_len);
        g.cylinders.shrinkRetainingCapacity(cp.cylinders_len);
        g.cones.shrinkRetainingCapacity(cp.cones_len);
        g.toruses.shrinkRetainingCapacity(cp.toruses_len);
        g.nurbs_curves.shrinkRetainingCapacity(cp.nurbs_curves_len);
        g.nurbs_surfaces.shrinkRetainingCapacity(cp.nurbs_surfaces_len);
    }
};
