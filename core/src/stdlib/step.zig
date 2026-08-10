const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const Brep = @import("../brep/topology.zig").Brep;

pub fn nativeImportStep(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count != 1 or !args[0].isString()) {
        std.log.err("import_step expects 1 argument (filename string)\n", .{});
        return error.RuntimeError;
    }

    const filename = args[0].asString();
    std.log.info("Mocking STEP import for file: {s}...", .{filename});

    // TODO: Actually parse the STEP file here and build a Brep

    // For now, allocate an empty stub B-Rep in the VM Garbage Collector
    const empty_brep = try vm.allocator.create(Brep);
    empty_brep.* = Brep.initEmpty(vm.allocator);

    return try vm.allocateBrep(empty_brep);
}

pub fn nativeExportStep(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm; // Ignore unused variable

    if (arg_count != 2 or !args[0].isString() or !args[1].isBrep()) {
        std.log.err("export_step expects 2 arguments (filename string, Brep object)\n", .{});
        return error.RuntimeError;
    }

    const filename = args[0].asString();
    std.log.info("Mocking STEP export to file: {s}...", .{filename});

    // TODO: Write the B-Rep data to a STEP ASCII file format

    return args[1]; // Return the Brep object for method chaining
}
