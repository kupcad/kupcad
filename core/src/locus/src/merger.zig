const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");

pub const MergeError = error{OutOfMemory};

pub fn mergeSolidArenas(
    allocator: std.mem.Allocator,
    dest_t: *topo.TopologyArena,
    dest_g: *geom.GeometryArena,
    src_t: *const topo.TopologyArena,
    src_g: *const geom.GeometryArena,
    target_solid: topo.SolidId,
) MergeError!topo.SolidId {
    const line_off = @as(u24, @intCast(dest_g.lines.items.len));
    const arc_off = @as(u24, @intCast(dest_g.circle_arcs.items.len));
    const plane_off = @as(u24, @intCast(dest_g.planes.items.len));
    const sphere_off = @as(u24, @intCast(dest_g.spheres.items.len));
    const cyl_off = @as(u24, @intCast(dest_g.cylinders.items.len));
    const cone_off = @as(u24, @intCast(dest_g.cones.items.len));
    const torus_off = @as(u24, @intCast(dest_g.toruses.items.len));

    const v_off = @as(u32, @intCast(dest_t.vertices.items.len));
    const he_off = @as(u32, @intCast(dest_t.half_edges.items.len));
    const loop_off = @as(u32, @intCast(dest_t.loops.items.len));
    const f_off = @as(u32, @intCast(dest_t.faces.items.len));
    const sh_off = @as(u32, @intCast(dest_t.shells.items.len));
    const solid_off = @as(u32, @intCast(dest_t.solids.items.len));
    const fl_off = @as(u32, @intCast(dest_t.face_loops.items.len));
    const sf_off = @as(u32, @intCast(dest_t.shell_faces.items.len));
    const ss_off = @as(u32, @intCast(dest_t.solid_shells.items.len));

    try dest_g.lines.appendSlice(allocator, src_g.lines.items);
    try dest_g.circle_arcs.appendSlice(allocator, src_g.circle_arcs.items);
    try dest_g.planes.appendSlice(allocator, src_g.planes.items);
    try dest_g.spheres.appendSlice(allocator, src_g.spheres.items);
    try dest_g.cylinders.appendSlice(allocator, src_g.cylinders.items);
    try dest_g.cones.appendSlice(allocator, src_g.cones.items);
    try dest_g.toruses.appendSlice(allocator, src_g.toruses.items);

    try dest_t.vertices.appendSlice(allocator, src_t.vertices.items);
    try dest_t.half_edges.appendSlice(allocator, src_t.half_edges.items);
    try dest_t.loops.appendSlice(allocator, src_t.loops.items);
    try dest_t.faces.appendSlice(allocator, src_t.faces.items);
    try dest_t.shells.appendSlice(allocator, src_t.shells.items);
    try dest_t.solids.appendSlice(allocator, src_t.solids.items);
    try dest_t.face_loops.appendSlice(allocator, src_t.face_loops.items);
    try dest_t.shell_faces.appendSlice(allocator, src_t.shell_faces.items);
    try dest_t.solid_shells.appendSlice(allocator, src_t.solid_shells.items);

    for (dest_t.half_edges.items[he_off..]) |*he| {
        he.start_vertex += v_off;
        if (he.twin != topo.NULL_ID) he.twin += he_off;
        he.next += he_off;
        he.prev += he_off;
        he.loop_id += loop_off;
        switch (he.curve.curve_type) {
            .line => he.curve.index += line_off,
            .circle_arc => he.curve.index += arc_off,
            .nurbs => {},
        }
    }

    for (dest_t.loops.items[loop_off..]) |*l| {
        l.face_id += f_off;
        l.first_half_edge += he_off;
    }

    for (dest_t.faces.items[f_off..]) |*face| {
        face.loops_start += fl_off;
        switch (face.surface.surface_type) {
            .plane => face.surface.index += plane_off,
            .sphere => face.surface.index += sphere_off,
            .cylinder => face.surface.index += cyl_off,
            .cone => face.surface.index += cone_off,
            .torus => face.surface.index += torus_off,
            .nurbs => {},
        }
    }

    for (dest_t.shells.items[sh_off..]) |*shell| shell.faces_start += sf_off;
    for (dest_t.solids.items[solid_off..]) |*solid| solid.shells_start += ss_off;
    for (dest_t.face_loops.items[fl_off..]) |*l_id| l_id.* += loop_off;
    for (dest_t.shell_faces.items[sf_off..]) |*f_id| f_id.* += f_off;
    for (dest_t.solid_shells.items[ss_off..]) |*sh_id| sh_id.* += sh_off;

    return target_solid + solid_off;
}
