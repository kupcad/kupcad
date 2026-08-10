const std = @import("std");
const value = @import("../core/value.zig");
const manifold = @import("../core/manifold.zig");
const VM = @import("../vm/vm.zig").VM;

pub fn nativeCube(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const self: *VM = @ptrCast(@alignCast(vm_opaque));

    // A standard 1x1x1 cube centered at the origin
    const vertices = [_]value.Vec3{
        .{ .x = -0.5, .y = -0.5, .z = -0.5 }, // 0: left, front, bottom
        .{ .x = 0.5, .y = -0.5, .z = -0.5 }, // 1: right, front, bottom
        .{ .x = 0.5, .y = 0.5, .z = -0.5 }, // 2: right, back, bottom
        .{ .x = -0.5, .y = 0.5, .z = -0.5 }, // 3: left, back, bottom
        .{ .x = -0.5, .y = -0.5, .z = 0.5 }, // 4: left, front, top
        .{ .x = 0.5, .y = -0.5, .z = 0.5 }, // 5: right, front, top
        .{ .x = 0.5, .y = 0.5, .z = 0.5 }, // 6: right, back, top
        .{ .x = -0.5, .y = 0.5, .z = 0.5 }, // 7: left, back, top
    };

    // Note: Triangles must be wound counter-clockwise (CCW) to face outwards
    const faces = [_][3]u32{
        // Bottom
        .{ 0, 2, 1 }, .{ 0, 3, 2 },
        // Top
        .{ 4, 5, 6 }, .{ 4, 6, 7 },
        // Front
        .{ 0, 1, 5 }, .{ 0, 5, 4 },
        // Right
        .{ 1, 2, 6 }, .{ 1, 6, 5 },
        // Back
        .{ 2, 3, 7 }, .{ 2, 7, 6 },
        // Left
        .{ 3, 0, 4 }, .{ 3, 4, 7 },
    };

    const handle = manifold.cube(1.0, 1.0, 1.0, true);

    return self.allocateMesh(handle, &vertices, &faces);
}
