const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;

pub fn nativeImportStep(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count != 1 or !args[0].isString()) {
        std.log.err("import_step expects 1 argument (filename string)\n", .{});
        return error.RuntimeError;
    }

    const filename = args[0].asString();
    std.log.info("Mocking STEP import for file: {s}...", .{filename});

    // Allocate an empty stub B-Rep GeometryHandle in the VM ARC manager
    const mock_handle = @as(*anyopaque, @ptrFromInt(0xDEADBEEF));

    // We return the Geometry Value directly. No more topology.Brep needed!
    return try vm.allocateGeometry(.{ .concrete = .{ .engine = .brep_native, .ptr = mock_handle } });
}

pub fn nativeExportStep(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    // Updated isBrep() to isGeometry()
    if (arg_count != 2 or !args[0].isString() or !args[1].isGeometry()) {
        std.log.err("export_step expects 2 arguments (filename string, geometry object)\n", .{});
        return error.RuntimeError;
    }

    const filename = args[0].asString();
    std.log.info("Mocking STEP export to file: {s}...", .{filename});

    // Force JIT materialization to guarantee physical C++ geometry exists
    _ = try vm.ensureConcrete(args[1]);

    // Return the unmodified geometry value to allow fluent method chaining
    // Retain it to grant +1 ownership to the VM loop
    vm.retainValue(args[1]);
    return args[1];
}
