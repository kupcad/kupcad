const std = @import("std");
const geom = @import("geometry.zig");
const booleans = @import("booleans.zig");
const math = @import("math.zig");

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
