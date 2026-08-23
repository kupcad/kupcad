const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../kernel/geometry_handle.zig");

/// Generates an STL binary buffer in memory.
pub fn buildStlBuffer(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ![]const u8 {
    const mesh = kernel.getMesh(allocator, handle) orelse return error.MeshExtractionFailed;
    defer allocator.free(mesh.vert_props);
    defer allocator.free(mesh.tri_verts);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // STL Header (80 bytes)
    try out.appendNTimes(allocator, 0, 80);
    // Triangle Count (4 bytes)
    const tri_count: u32 = @intCast(mesh.tri_verts.len / 3);
    try out.appendSlice(allocator, std.mem.asBytes(&tri_count));

    var i: usize = 0;
    while (i < mesh.tri_verts.len) : (i += 3) {
        // Normal vector (dummy 0.0, 0.0, 0.0)
        const zero: f32 = 0.0;
        try out.appendSlice(allocator, std.mem.asBytes(&zero));
        try out.appendSlice(allocator, std.mem.asBytes(&zero));
        try out.appendSlice(allocator, std.mem.asBytes(&zero));

        // 3 Vertices (x, y, z floats)
        for (0..3) |v| {
            const idx = mesh.tri_verts[i + v];
            const v_idx = idx * mesh.num_prop;
            try out.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v_idx]));
            try out.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v_idx + 1]));
            try out.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v_idx + 2]));
        }

        // Attribute byte count (2 bytes)
        const attr_count: u16 = 0;
        try out.appendSlice(allocator, std.mem.asBytes(&attr_count));
    }

    return try out.toOwnedSlice(allocator);
}

pub fn nativeExportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 2) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (!args[0].isString()) return error.RuntimeError;
    if (!args[1].isGeometry()) return error.RuntimeError;

    const path_str = args[0].asString().chars;
    const handle = try vm.ensureConcrete(args[1]);

    const stl_bytes = try buildStlBuffer(vm.allocator, handle);
    defer vm.allocator.free(stl_bytes);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(vm.io, .{
        .sub_path = path_str,
        .data = stl_bytes,
    });

    return value.Value.initNil();
}

pub fn nativeImportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    _ = arg_count;
    _ = args;
    return error.RuntimeError; // MVP stub
}
