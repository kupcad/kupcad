const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const geom = @import("../../kernel/geometry_handle.zig");
const kernel = @import("../../kernel/kernel.zig");

pub fn buildStepBuffer(allocator: std.mem.Allocator, handles: []const geom.GeometryHandle) ![]const u8 {
    return kernel.exportStep(allocator, handles);
}

pub fn meshExportStep(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    var export_handles = std.ArrayListUnmanaged(geom.GeometryHandle).empty;
    defer export_handles.deinit(vm.allocator);

    if (receiver.isAssembly()) {
        for (receiver.asAssembly().parts.items.items) |part_val| {
            if (part_val.isGeometry()) {
                const h = try vm.ensureConcrete(part_val);
                try export_handles.append(vm.allocator, h);
            }
        }
    } else {
        const h = try vm.ensureConcrete(receiver);
        try export_handles.append(vm.allocator, h);
    }

    const step_bytes = buildStepBuffer(vm.allocator, export_handles.items) catch |err| {
        vm.reportError("Export Error: Failed to generate STEP ({})\n", .{err});
        return error.RuntimeError;
    };
    defer vm.allocator.free(step_bytes);

    try vm.vfs.writeFile(filepath, step_bytes);

    return receiver;
}

pub fn nativeExportStep(vm: *VM, path_str: []const u8, target: value.Value) !value.Value {
    return meshExportStep(vm, target, path_str);
}

pub fn nativeImportStep(vm: *VM, path_str: []const u8) !value.Value {
    _ = path_str;
    vm.reportError("Runtime Error: import_step not yet supported for native B-Rep engine.\n", .{});
    return error.RuntimeError;
}
