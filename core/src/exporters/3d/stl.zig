const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;

pub fn nativeExportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 2) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (!args[0].isString()) return error.RuntimeError;
    if (!args[1].isGeometry()) return error.RuntimeError;

    const path_str = args[0].asString();

    // 1. Force materialization
    const handle = try vm.ensureConcrete(args[1]);

    // 2. Safely extract raw mesh geometry
    const mesh = vm.active_kernel.?.getMesh(vm.allocator, handle) orelse return error.RuntimeError;
    defer {
        vm.allocator.free(mesh.vert_props);
        vm.allocator.free(mesh.tri_verts);
    }

    // 3. Write standard Binary STL
    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();

    // STL requires exactly an 80-byte header
    const header = [_]u8{0} ** 80;
    try out.writer.writeAll(&header);

    // Number of triangles
    const num_tris: u32 = @intCast(mesh.tri_verts.len / 3);
    try out.writer.writeInt(u32, num_tris, .little);

    var i: usize = 0;
    while (i < mesh.tri_verts.len) : (i += 3) {
        // Normal Vector (Calculated later, use 0.0 for now)
        try out.writer.writeInt(u32, @as(u32, @bitCast(@as(f32, 0.0))), .little);
        try out.writer.writeInt(u32, @as(u32, @bitCast(@as(f32, 0.0))), .little);
        try out.writer.writeInt(u32, @as(u32, @bitCast(@as(f32, 0.0))), .little);

        // 3 Vertices (x, y, z)
        for (0..3) |v| {
            const idx = mesh.tri_verts[i + v];
            const px = mesh.vert_props[idx * mesh.num_prop + 0];
            const py = mesh.vert_props[idx * mesh.num_prop + 1];
            const pz = mesh.vert_props[idx * mesh.num_prop + 2];

            // Bit-cast f32 to u32 to write raw bytes
            try out.writer.writeInt(u32, @as(u32, @bitCast(px)), .little);
            try out.writer.writeInt(u32, @as(u32, @bitCast(py)), .little);
            try out.writer.writeInt(u32, @as(u32, @bitCast(pz)), .little);
        }
        // Attribute byte count (always 0)
        try out.writer.writeInt(u16, 0, .little);
    }

    // Write file natively to disk
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(vm.io, .{
        .sub_path = path_str,
        .data = out.written(),
    });

    return value.Value.initNil();
}

pub fn nativeImportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    _ = arg_count;
    _ = args;
    return error.RuntimeError; // Implemented later!
}
