const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const geom = @import("../../kernel/geometry_handle.zig");

// Extracted reusable STL writer!
pub fn writeStl(vm: *VM, handle: geom.GeometryHandle, path_str: []const u8) anyerror!void {
    const mesh = vm.active_kernel.?.getMesh(vm.allocator, handle) orelse return error.RuntimeError;
    defer {
        vm.allocator.free(mesh.vert_props);
        vm.allocator.free(mesh.tri_verts);
    }

    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();

    const header = [_]u8{0} ** 80;
    try out.writer.writeAll(&header);

    const num_tris: u32 = @intCast(mesh.tri_verts.len / 3);
    try out.writer.writeInt(u32, num_tris, .little);

    var i: usize = 0;
    while (i < mesh.tri_verts.len) : (i += 3) {
        try out.writer.writeInt(u32, @as(u32, @bitCast(@as(f32, 0.0))), .little);
        try out.writer.writeInt(u32, @as(u32, @bitCast(@as(f32, 0.0))), .little);
        try out.writer.writeInt(u32, @as(u32, @bitCast(@as(f32, 0.0))), .little);

        for (0..3) |v| {
            const idx = mesh.tri_verts[i + v];
            const px = mesh.vert_props[idx * mesh.num_prop + 0];
            const py = mesh.vert_props[idx * mesh.num_prop + 1];
            const pz = mesh.vert_props[idx * mesh.num_prop + 2];

            try out.writer.writeInt(u32, @as(u32, @bitCast(px)), .little);
            try out.writer.writeInt(u32, @as(u32, @bitCast(py)), .little);
            try out.writer.writeInt(u32, @as(u32, @bitCast(pz)), .little);
        }
        try out.writer.writeInt(u16, 0, .little);
    }

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(vm.io, .{
        .sub_path = path_str,
        .data = out.written(),
    });
}

pub fn nativeExportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 2) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (!args[0].isString()) return error.RuntimeError;
    if (!args[1].isGeometry()) return error.RuntimeError;

    const path_str = args[0].asString();
    const handle = try vm.ensureConcrete(args[1]);

    try writeStl(vm, handle, path_str);

    return value.Value.initNil();
}

pub fn nativeImportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    _ = arg_count;
    _ = args;
    return error.RuntimeError; // Implemented later
}
