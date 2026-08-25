const std = @import("std");
const topo = @import("topology.zig");
const generators = @import("generators.zig");
const geom = @import("geometry.zig");
const booleans = @import("booleans.zig");
const math = @import("math.zig");
const transforms = @import("transforms.zig");

test "March Intersection (Perpendicular Cylinders)" {
    // Cylinder A: Along Z axis
    const cyl_a = geom.Cylinder{
        .origin = .{ 0, 0, 0 },
        .axis = .{ 0, 0, 1 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 1, 0 },
        .radius = 5.0,
    };

    // Cylinder B: Along Y axis
    const cyl_b = geom.Cylinder{
        .origin = .{ 0, 0, 0 },
        .axis = .{ 0, 1, 0 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 0, 1 },
        .radius = 5.0,
    };

    var g_arena = geom.GeometryArena.init(std.testing.allocator);
    defer g_arena.deinit();

    // Push directly to the densely packed cylinders array
    try g_arena.cylinders.append(std.testing.allocator, cyl_a);
    try g_arena.cylinders.append(std.testing.allocator, cyl_b);

    const start_pt = math.Vec3{ 5.0, 0.0, 0.0 };

    // Construct the 32-bit packed IDs
    const id_a = geom.SurfaceId{ .index = 0, .surface_type = .cylinder };
    const id_b = geom.SurfaceId{ .index = 1, .surface_type = .cylinder };

    const curve_id = try booleans.marchIntersection(std.testing.allocator, &g_arena, id_a, id_b, start_pt, 0.5, 10, 1e-5);

    // Using .index to verify it returned the first generated curve
    try std.testing.expectEqual(@as(u32, 0), curve_id.index);
}

test "CSG Pipeline: High-Level Operations (Stubbed)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // Generate TWO distinct cubes
    const cube1 = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, true);
    const cube2 = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, true);

    // Move the second cube so they are completely disjoint (No coplanar edge cases!)
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube2, 20, 0, 0);

    // Now perform the union
    const union_result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube1, cube2, .union_op, .{});

    // 6 faces from Cube1 + 6 faces from Cube2 = 12 exterior faces!
    const union_shell = t_arena.shells.items[t_arena.solid_shells.items[t_arena.solids.items[union_result].shells_start]];
    try std.testing.expectEqual(@as(usize, 12), union_shell.faces_len);
}

test "CSG: Topological Edge Splitting" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // Setup an isolated Edge spanning X=0 to X=10
    const v0 = @as(u32, @intCast(t_arena.vertices.items.len));
    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 0, 0 } });

    const v1 = @as(u32, @intCast(t_arena.vertices.items.len));
    try t_arena.vertices.append(alloc, .{ .point = .{ 10, 0, 0 } });

    const l_idx = @as(u24, @intCast(g_arena.lines.items.len));
    try g_arena.lines.append(alloc, .{ .start = .{ 0, 0, 0 }, .end = .{ 10, 0, 0 } });

    const edge_id = @as(u32, @intCast(t_arena.edges.items.len));
    try t_arena.edges.append(alloc, .{
        .front = v0,
        .back = v1,
        .curve = .{ .index = l_idx, .curve_type = .line },
    });

    // Simulate an intersection at X=5
    const split_pt = math.Vec3{ 5, 0, 0 };

    // This is the private function, we declare it public temporarily or use @call if needed,
    // but since they are in the same module in a real build, it works.
    const result = try booleans.splitEdgeTopologically(alloc, &t_arena, &g_arena, edge_id, split_pt);

    // Validation
    try std.testing.expectEqual(@as(usize, 3), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 3), t_arena.edges.items.len); // Original + 2 New

    const new_e1 = t_arena.edges.items[result.e1];
    const new_e2 = t_arena.edges.items[result.e2];

    try std.testing.expectEqual(v0, new_e1.front);
    try std.testing.expectEqual(result.v_mid, new_e1.back);

    try std.testing.expectEqual(result.v_mid, new_e2.front);
    try std.testing.expectEqual(v1, new_e2.back);
}

test "CSG: Point-in-Solid Raycaster" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // Generate a 10x10x10 cube, centered at origin (-5 to +5 on all axes)
    const cube_id = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, true);

    // 1. Test Point strictly INSIDE the cube
    const pt_inside = math.Vec3{ 0.0, 0.0, 0.0 };
    const is_in = booleans.isPointInsideSolid(&t_arena, &g_arena, cube_id, pt_inside);
    try std.testing.expectEqual(true, is_in);

    // 2. Test Point strictly OUTSIDE the cube
    const pt_outside = math.Vec3{ 20.0, 20.0, 20.0 };
    const is_out = booleans.isPointInsideSolid(&t_arena, &g_arena, cube_id, pt_outside);
    try std.testing.expectEqual(false, is_out);
}

test "CSG: Topological Edge Splitting & Wire Reweaving" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // 1. Setup an isolated Edge spanning X=0 to X=10
    const v0 = @as(u32, @intCast(t_arena.vertices.items.len));
    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 0, 0 } });

    const v1 = @as(u32, @intCast(t_arena.vertices.items.len));
    try t_arena.vertices.append(alloc, .{ .point = .{ 10, 0, 0 } });

    const l_idx = @as(u24, @intCast(g_arena.lines.items.len));
    try g_arena.lines.append(alloc, .{ .start = .{ 0, 0, 0 }, .end = .{ 10, 0, 0 } });

    const edge_id = @as(u32, @intCast(t_arena.edges.items.len));
    try t_arena.edges.append(alloc, .{
        .front = v0,
        .back = v1,
        .curve = .{ .index = l_idx, .curve_type = .line },
    });

    // 2. Wrap the Edge in a Wire
    const w_edges_start = @as(u32, @intCast(t_arena.wire_edges.items.len));
    try t_arena.wire_edges.append(alloc, .{ .edge = edge_id, .forward = true });

    const wire_id = @as(u32, @intCast(t_arena.wires.items.len));
    try t_arena.wires.append(alloc, .{ .edges_start = w_edges_start, .edges_len = 1 });

    // 3. Simulate an intersection at X=5 and split it!
    const split_pt = math.Vec3{ 5, 0, 0 };

    _ = try booleans.splitEdgeTopologically(alloc, &t_arena, &g_arena, edge_id, split_pt);

    // 4. Validation
    const updated_wire = t_arena.wires.items[wire_id];

    // The wire used to have 1 edge. Now it should have 2!
    try std.testing.expectEqual(@as(usize, 2), updated_wire.edges_len);

    // Verify the winding order of the newly inserted edges
    const d_edge_1 = t_arena.wire_edges.items[updated_wire.edges_start + 0];
    const d_edge_2 = t_arena.wire_edges.items[updated_wire.edges_start + 1];

    try std.testing.expectEqual(true, d_edge_1.forward);
    try std.testing.expectEqual(true, d_edge_2.forward);
}

test "CSG: Face Splitting" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // 1. Generate a Base Cube, we will extract its top face (Face 1)
    _ = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, false);

    const face_id: u32 = 1; // Top face (Z=10)

    // The top face is bounded by 4 edges.
    // We will split the first edge (Y=0) and the third edge (Y=10) in half.
    const wire_id = t_arena.face_wires.items[t_arena.faces.items[face_id].wires_start];
    const wire = t_arena.wires.items[wire_id];

    const edge1_id = t_arena.wire_edges.items[wire.edges_start + 0].edge; // Bottom edge
    const edge3_id = t_arena.wire_edges.items[wire.edges_start + 2].edge; // Top edge

    // 2. Split Edge 1 at X=5, Y=0
    const res1 = try booleans.splitEdgeTopologically(alloc, &t_arena, &g_arena, edge1_id, .{ 5, 0, 10 });
    // 3. Split Edge 3 at X=5, Y=10
    const res2 = try booleans.splitEdgeTopologically(alloc, &t_arena, &g_arena, edge3_id, .{ 5, 10, 10 });

    // 4. Split the Face across the two new vertices!
    const new_sub_face_id = try booleans.splitFaceTopologically(alloc, &t_arena, &g_arena, face_id, res1.v_mid, res2.v_mid);

    // 5. Validation
    // The face was cut in half, so the new face should exist.
    // The original face's wire should now have 4 edges (it was 4, split into 6, divided into 4 and 4).
    const modified_orig_wire = t_arena.wires.items[wire_id];
    try std.testing.expectEqual(@as(usize, 4), modified_orig_wire.edges_len);

    const new_sub_wire_id = t_arena.face_wires.items[t_arena.faces.items[new_sub_face_id].wires_start];
    const new_sub_wire = t_arena.wires.items[new_sub_wire_id];
    try std.testing.expectEqual(@as(usize, 4), new_sub_wire.edges_len);
}

test "CSG: 2D Point-in-Polygon Algorithm" {
    // We can expose the private function for testing using @call,
    // or since this is a test block within the same compilation unit, we can just call it.
    // Ensure `isPointInPolygon2D` is accessible (add `pub` if needed).

    // Create a 2D chevron / arrow shape
    const polygon = [_][2]f64{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 5.0, 5.0 }, // The inner notch of the chevron
        .{ 10.0, 10.0 },
        .{ 0.0, 10.0 },
    };

    // 1. Point strictly inside the top wing
    try std.testing.expectEqual(true, booleans.isPointInPolygon2D(.{ 2.0, 8.0 }, &polygon));

    // 2. Point strictly inside the bottom wing
    try std.testing.expectEqual(true, booleans.isPointInPolygon2D(.{ 2.0, 2.0 }, &polygon));

    // 3. Point outside (inside the notch of the chevron)
    try std.testing.expectEqual(false, booleans.isPointInPolygon2D(.{ 7.0, 5.0 }, &polygon));

    // 4. Point completely outside the bounding box
    try std.testing.expectEqual(false, booleans.isPointInPolygon2D(.{ 15.0, 5.0 }, &polygon));
}

test "CSG: Loop Tracer (Graph Traversal)" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();

    // 1. Create 4 vertices forming a square
    const v0: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 0, 0 } });
    const v1: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.append(alloc, .{ .point = .{ 1, 0, 0 } });
    const v2: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.append(alloc, .{ .point = .{ 1, 1, 0 } });
    const v3: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 1, 0 } });

    // 2. Create 4 edges, intentionally scrambling their direction to test the auto-winding
    const e0: u32 = @intCast(t_arena.edges.items.len);
    try t_arena.edges.append(alloc, .{ .front = v0, .back = v1, .curve = undefined }); // Forward
    const e1: u32 = @intCast(t_arena.edges.items.len);
    try t_arena.edges.append(alloc, .{ .front = v2, .back = v1, .curve = undefined }); // BACKWARD!
    const e2: u32 = @intCast(t_arena.edges.items.len);
    try t_arena.edges.append(alloc, .{ .front = v2, .back = v3, .curve = undefined }); // Forward
    const e3: u32 = @intCast(t_arena.edges.items.len);
    try t_arena.edges.append(alloc, .{ .front = v0, .back = v3, .curve = undefined }); // BACKWARD!

    // 3. Throw the edges into an unordered bag
    const edge_bag = [_]topo.EdgeId{ e2, e0, e3, e1 }; // Totally random order

    // 4. Run the Loop Tracer!
    var new_wires = try booleans.traceLoopsTopologically(alloc, &t_arena, &edge_bag);
    defer new_wires.deinit(alloc);

    // 5. Validation
    // It should have successfully found 1 closed loop.
    try std.testing.expectEqual(@as(usize, 1), new_wires.items.len);

    const wire_id = new_wires.items[0];
    const wire = t_arena.wires.items[wire_id];

    // The wire must contain exactly 4 edges
    try std.testing.expectEqual(@as(usize, 4), wire.edges_len);

    // Let's verify it correctly figured out the forward/backward winding!
    // Since it started on e2 (v2->v3), the next connecting edge MUST be e3 (v0->v3) traversing BACKWARD (v3->v0).
    const d_edge_0 = t_arena.wire_edges.items[wire.edges_start + 0]; // e2
    const d_edge_1 = t_arena.wire_edges.items[wire.edges_start + 1]; // e3

    try std.testing.expectEqual(e2, d_edge_0.edge);
    try std.testing.expectEqual(true, d_edge_0.forward); // v2 -> v3

    try std.testing.expectEqual(e3, d_edge_1.edge);
    try std.testing.expectEqual(false, d_edge_1.forward); // v3 -> v0
}
