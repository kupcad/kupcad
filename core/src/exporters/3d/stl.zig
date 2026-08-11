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

    // TODO: Pass stl_data.vertices and stl_data.faces to the active Geometry Kernel
    // to construct a native C++ Manifold/OCCT mesh handle.
    // For now, we mock the handle creation.
    const mock_handle = @as(*anyopaque, @ptrFromInt(0xDEADBEEF));

    // Allocate the Geometry on the VM using ARC (bypassing the Mark-and-Sweep GC).
    // Since this is an imported physical file, it bypasses the Symbolic DAG and
    // initializes directly in the `.concrete` state
    return try vm.allocateGeometry(.{ .concrete = .{ .engine = .manifold, .ptr = mock_handle } });
}

pub fn nativeExportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count != 2) {
        std.log.err("export_stl expects exactly 2 arguments (filename, geometry)\n", .{});
        return error.RuntimeError;
    }

    // Updated to use the new isGeometry() type checker instead of isMesh()
    if (!args[0].isString() or !args[1].isGeometry()) {
        std.log.err("export_stl arguments must be (String, Geometry)\n", .{});
        return error.RuntimeError;
    }

    const filename = args[0].asString();

    // JIT MATERIALIZATION TRIGGER:
    // Force the VM to traverse the DAG subgraph and evaluate it into a physical
    // C++ Mesh Handle before we attempt to write it to disk
    _ = try vm.ensureConcrete(args[1]);

    std.log.info("Exporting evaluated geometry to '{s}'...\n", .{filename});

    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();

    // TODO: Extract the raw vertices and faces from the concrete `kernel_handle`
    // using the active C++ Kernel driver (e.g., manifold_get_meshgl), then pass
    // that physical geometry data to stl_format.write().
    //
    // stl_format.write(extracted_mesh_data, &out.writer) catch |err| {
    //     std.log.err("Error writing to STL buffer: {}\n", .{err});
    //     return error.RuntimeError;
    // };

    vm.cwd.writeFile(vm.io, .{
        .sub_path = filename,
        .data = out.written(),
    }) catch |err| {
        std.log.err("Could not write STL file '{s}': {}\n", .{ filename, err });
        return error.RuntimeError;
    };

    // Return the unmodified geometry value to allow fluent method chaining
    // Retain it to grant +1 ownership to the VM loop
    vm.retainValue(args[1]);
    return args[1];
}
