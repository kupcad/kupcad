const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const stl_format = @import("../../formats/stl.zig");

pub fn nativeImportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count != 1 or !args[0].isString()) {
        std.log.err("import_stl expects exactly 1 argument (filename string)\n", .{});
        return error.RuntimeError;
    }

    const filename = args[0].asString();

    // Read the STL file from disk (Max 500 MB limit)
    const file_data = vm.cwd.readFileAlloc(vm.io, filename, vm.allocator, .limited(1024 * 1024 * 500)) catch |err| {
        std.log.err("Could not read STL file '{s}': {}\n", .{ filename, err });
        return error.RuntimeError;
    };
    defer vm.allocator.free(file_data);

    // Parse the binary STL
    var stl_data = stl_format.readBinary(vm.allocator, file_data) catch |err| {
        std.log.err("Failed to parse binary STL file '{s}': {}\n", .{ filename, err });
        return error.RuntimeError;
    };
    defer stl_data.deinit(vm.allocator);

    // Allocate the Mesh on the VM heap with a null kernel handle but populated geometry.
    return try vm.allocateMesh(null, stl_data.vertices, stl_data.faces);
}

pub fn nativeExportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const self: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count != 2) {
        std.log.err("export_stl expects exactly 2 arguments (filename, mesh)\n", .{});
        return error.RuntimeError;
    }

    if (!args[0].isString() or !args[1].isMesh()) {
        std.log.err("export_stl arguments must be (String, Mesh)\n", .{});
        return error.RuntimeError;
    }

    const filename = args[0].asString();
    const mesh = args[1].asMesh();

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    stl_format.write(mesh, &out.writer) catch |err| {
        std.log.err("Error writing to STL buffer: {}\n", .{err});
        return error.RuntimeError;
    };

    self.cwd.writeFile(self.io, .{
        .sub_path = filename,
        .data = out.written(),
    }) catch |err| {
        std.log.err("Could not write STL file '{s}': {}\n", .{ filename, err });
        return error.RuntimeError;
    };

    return args[1]; // Return the mesh to allow method chaining
}
