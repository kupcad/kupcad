const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../kernel/geometry_handle.zig");

/// Mocks generating a STEP file buffer in memory
pub fn buildStepBuffer(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ![]const u8 {
    _ = handle; // Will use this when linking C++ OpenCASCADE STEP exporter

    const mock_step_data =
        \\ISO-10303-21;
        \\HEADER;
        \\/* Mock KupCAD STEP Export */
        \\ENDSEC;
        \\DATA;
        \\ENDSEC;
        \\END-ISO-10303-21;
        \\
    ;
    return try allocator.dupe(u8, mock_step_data);
}

pub fn nativeImportStep(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count != 1 or !args[0].isString()) {
        std.log.err("import_step expects 1 argument (filename string)\n", .{});
        return error.RuntimeError;
    }

    const filename = args[0].asString();
    std.log.info("Mocking STEP import for file: {s}...", .{filename.chars});

    const mock_handle = @as(*anyopaque, @ptrFromInt(0xDEADBEEF));
    return try vm.allocateGeometry(.{ .concrete = .{ .engine = .brep_native, .ptr = mock_handle } });
}

pub fn nativeExportStep(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count != 2 or !args[0].isString() or !args[1].isGeometry()) {
        std.log.err("export_step expects 2 arguments (filename string, geometry object)\n", .{});
        return error.RuntimeError;
    }

    const filename = args[0].asString();
    std.log.info("Mocking STEP export to file: {s}...", .{filename.chars});

    _ = try vm.ensureConcrete(args[1]);

    return args[1];
}
