const std = @import("std");
const topo = @import("topology.zig");
const driver = @import("driver.zig");

pub fn generateCube(allocator: std.mem.Allocator, x: f64, y: f64, z: f64, center: bool) !*driver.BrepSolid {
    const solid = try driver.BrepSolid.create(allocator);
    errdefer solid.destroy();

    const b = &solid.brep;

    const min_x = if (center) -x / 2.0 else 0.0;
    const max_x = if (center) x / 2.0 else x;
    const min_y = if (center) -y / 2.0 else 0.0;
    const max_y = if (center) y / 2.0 else y;
    const min_z = if (center) -z / 2.0 else 0.0;
    const max_z = if (center) z / 2.0 else z;

    // 1. Add Vertices (8 corners)
    try b.vertices.appendSlice(allocator, &[_]topo.Vertex{
        .{ .point = .{ .x = min_x, .y = min_y, .z = min_z } }, // 0: Bottom-Left-Front
        .{ .point = .{ .x = max_x, .y = min_y, .z = min_z } }, // 1: Bottom-Right-Front
        .{ .point = .{ .x = max_x, .y = max_y, .z = min_z } }, // 2: Bottom-Right-Back
        .{ .point = .{ .x = min_x, .y = max_y, .z = min_z } }, // 3: Bottom-Left-Back
        .{ .point = .{ .x = min_x, .y = min_y, .z = max_z } }, // 4: Top-Left-Front
        .{ .point = .{ .x = max_x, .y = min_y, .z = max_z } }, // 5: Top-Right-Front
        .{ .point = .{ .x = max_x, .y = max_y, .z = max_z } }, // 6: Top-Right-Back
        .{ .point = .{ .x = min_x, .y = max_y, .z = max_z } }, // 7: Top-Left-Back
    });

    // 2. Add Edges (12 bounding lines)
    try b.edges.appendSlice(allocator, &[_]topo.Edge{
        .{ .start_vertex = 0, .end_vertex = 1 }, // 0: Bottom Front
        .{ .start_vertex = 1, .end_vertex = 2 }, // 1: Bottom Right
        .{ .start_vertex = 2, .end_vertex = 3 }, // 2: Bottom Back
        .{ .start_vertex = 3, .end_vertex = 0 }, // 3: Bottom Left
        .{ .start_vertex = 4, .end_vertex = 5 }, // 4: Top Front
        .{ .start_vertex = 5, .end_vertex = 6 }, // 5: Top Right
        .{ .start_vertex = 6, .end_vertex = 7 }, // 6: Top Back
        .{ .start_vertex = 7, .end_vertex = 4 }, // 7: Top Left
        .{ .start_vertex = 0, .end_vertex = 4 }, // 8: Pillar Front-Left
        .{ .start_vertex = 1, .end_vertex = 5 }, // 9: Pillar Front-Right
        .{ .start_vertex = 2, .end_vertex = 6 }, // 10: Pillar Back-Right
        .{ .start_vertex = 3, .end_vertex = 7 }, // 11: Pillar Back-Left
    });

    // Helper to rapidly weave edges into closed wires
    const addWire = struct {
        fn apply(brep: *topo.Brep, alloc: std.mem.Allocator, edges: []const u32) !u32 {
            const start = @as(u32, @intCast(brep.wire_edges.items.len));
            try brep.wire_edges.appendSlice(alloc, edges);
            const wire_id = @as(u32, @intCast(brep.wires.items.len));
            try brep.wires.append(alloc, .{ .first_edge = start, .num_edges = @intCast(edges.len) });
            return wire_id;
        }
    }.apply;

    // 3. Wires (6 boundary loops, 1 for each face)
    const w0 = try addWire(b, allocator, &[_]u32{ 0, 1, 2, 3 }); // Bottom
    const w1 = try addWire(b, allocator, &[_]u32{ 4, 5, 6, 7 }); // Top
    const w2 = try addWire(b, allocator, &[_]u32{ 0, 9, 4, 8 }); // Front
    const w3 = try addWire(b, allocator, &[_]u32{ 1, 10, 5, 9 }); // Right
    const w4 = try addWire(b, allocator, &[_]u32{ 2, 11, 6, 10 }); // Back
    const w5 = try addWire(b, allocator, &[_]u32{ 3, 8, 7, 11 }); // Left

    // 4. Faces (6 squares)
    try b.faces.appendSlice(allocator, &[_]topo.Face{
        .{ .outer_wire = w0, .first_inner_wire = 0, .num_inner_wires = 0 },
        .{ .outer_wire = w1, .first_inner_wire = 0, .num_inner_wires = 0 },
        .{ .outer_wire = w2, .first_inner_wire = 0, .num_inner_wires = 0 },
        .{ .outer_wire = w3, .first_inner_wire = 0, .num_inner_wires = 0 },
        .{ .outer_wire = w4, .first_inner_wire = 0, .num_inner_wires = 0 },
        .{ .outer_wire = w5, .first_inner_wire = 0, .num_inner_wires = 0 },
    });

    // 5. Shell (Groups all 6 faces together)
    const shell_faces_start = @as(u32, @intCast(b.shell_faces.items.len));
    try b.shell_faces.appendSlice(allocator, &[_]u32{ 0, 1, 2, 3, 4, 5 });
    const shell_id = @as(u32, @intCast(b.shells.items.len));
    try b.shells.append(allocator, .{ .first_face = shell_faces_start, .num_faces = 6 });

    // 6. Solid (The final CAD entity pointing to the outer shell)
    try b.solids.append(allocator, .{ .outer_shell = shell_id });

    return solid;
}
