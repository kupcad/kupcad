const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");

pub const MergeError = error{OutOfMemory};

/// Deep copies all topological and geometric data from the source arenas into the destination arenas.
/// Safely offsets all internal relational indices in O(N) linear time to maintain graph integrity.
/// Returns the new translated ID for the requested target_solid.
pub fn mergeSolidArenas(
    allocator: std.mem.Allocator,
    dest_t: *topo.TopologyArena,
    dest_g: *geom.GeometryArena,
    src_t: *const topo.TopologyArena,
    src_g: *const geom.GeometryArena,
    target_solid: topo.SolidId,
) MergeError!topo.SolidId {
    // --- 1. Capture Offset Baselines ---

    // Geometry Offsets
    const line_off = @as(u24, @intCast(dest_g.lines.items.len));
    const arc_off = @as(u24, @intCast(dest_g.circle_arcs.items.len));
    const nc_off = @as(u24, @intCast(dest_g.nurbs_curves.items.len));

    const plane_off = @as(u24, @intCast(dest_g.planes.items.len));
    const sphere_off = @as(u24, @intCast(dest_g.spheres.items.len));
    const cyl_off = @as(u24, @intCast(dest_g.cylinders.items.len));

    // Topology Offsets
    const v_off = @as(u32, @intCast(dest_t.vertices.items.len));
    const e_off = @as(u32, @intCast(dest_t.edges.items.len));
    const w_off = @as(u32, @intCast(dest_t.wires.items.len));
    const f_off = @as(u32, @intCast(dest_t.faces.items.len));
    const sh_off = @as(u32, @intCast(dest_t.shells.items.len));
    const solid_off = @as(u32, @intCast(dest_t.solids.items.len));

    const we_off = @as(u32, @intCast(dest_t.wire_edges.items.len));
    const fw_off = @as(u32, @intCast(dest_t.face_wires.items.len));
    const sf_off = @as(u32, @intCast(dest_t.shell_faces.items.len));
    const ss_off = @as(u32, @intCast(dest_t.solid_shells.items.len));

    // --- 2. Bulk Append Geometry (O(1) memory copies) ---
    try dest_g.lines.appendSlice(allocator, src_g.lines.items);
    try dest_g.circle_arcs.appendSlice(allocator, src_g.circle_arcs.items);
    try dest_g.nurbs_curves.appendSlice(allocator, src_g.nurbs_curves.items);

    try dest_g.planes.appendSlice(allocator, src_g.planes.items);
    try dest_g.spheres.appendSlice(allocator, src_g.spheres.items);
    try dest_g.cylinders.appendSlice(allocator, src_g.cylinders.items);

    // --- 3. Bulk Append Topology (O(1) memory copies) ---
    try dest_t.vertices.appendSlice(allocator, src_t.vertices.items);
    try dest_t.edges.appendSlice(allocator, src_t.edges.items);
    try dest_t.wires.appendSlice(allocator, src_t.wires.items);
    try dest_t.faces.appendSlice(allocator, src_t.faces.items);
    try dest_t.shells.appendSlice(allocator, src_t.shells.items);
    try dest_t.solids.appendSlice(allocator, src_t.solids.items);

    try dest_t.wire_edges.appendSlice(allocator, src_t.wire_edges.items);
    try dest_t.face_wires.appendSlice(allocator, src_t.face_wires.items);
    try dest_t.shell_faces.appendSlice(allocator, src_t.shell_faces.items);
    try dest_t.solid_shells.appendSlice(allocator, src_t.solid_shells.items);

    // --- 4. Linear Patching (O(N) cache-friendly updates) ---

    for (dest_t.edges.items[e_off..]) |*edge| {
        edge.front += v_off;
        edge.back += v_off;
        switch (edge.curve.curve_type) {
            .line => edge.curve.index += line_off,
            .circle_arc => edge.curve.index += arc_off,
            .nurbs => edge.curve.index += nc_off,
        }
    }

    for (dest_t.wires.items[w_off..]) |*wire| {
        wire.edges_start += we_off;
    }

    for (dest_t.faces.items[f_off..]) |*face| {
        face.wires_start += fw_off;
        switch (face.surface.surface_type) {
            .plane => face.surface.index += plane_off,
            .sphere => face.surface.index += sphere_off,
            .cylinder => face.surface.index += cyl_off,
            .nurbs => {},
        }
    }

    for (dest_t.shells.items[sh_off..]) |*shell| {
        shell.faces_start += sf_off;
    }

    for (dest_t.solids.items[solid_off..]) |*solid| {
        solid.shells_start += ss_off;
    }

    for (dest_t.wire_edges.items[we_off..]) |*d_edge| d_edge.edge += e_off;
    for (dest_t.face_wires.items[fw_off..]) |*w_id| w_id.* += w_off;
    for (dest_t.shell_faces.items[sf_off..]) |*f_id| f_id.* += f_off;
    for (dest_t.solid_shells.items[ss_off..]) |*sh_id| sh_id.* += sh_off;

    // Return the shifted ID for the requested solid
    return target_solid + solid_off;
}
