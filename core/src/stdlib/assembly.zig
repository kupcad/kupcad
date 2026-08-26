const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

pub fn nativeAssemble(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    var name_val = value.Value.initNil();
    var parts_val = value.Value.initNil();

    if (arg_count > 0 and args[arg_count - 1].isMap()) {
        const map = args[arg_count - 1].asMap();
        if (vm.findMapKeyByString(map, "name")) |idx| name_val = map.map.values()[idx];
        if (vm.findMapKeyByString(map, "parts")) |idx| parts_val = map.map.values()[idx];
    }

    if (!name_val.isString() or !parts_val.isArray()) {
        vm.reportError("ArgumentError: assemble requires name: String and parts: Array.\n", .{});
        return error.RuntimeError;
    }

    const assembly = try vm.gc.allocateAssembly(vm, name_val.asString(), parts_val.asArray());
    return value.Value.initObj(&assembly.obj);
}

pub fn nativeUnion(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count != 1 or !args[0].isArray()) {
        vm.reportError("ArgumentError: union expects exactly 1 Array argument.\n", .{});
        return error.RuntimeError;
    }

    const parts = args[0].asArray();
    if (parts.items.items.len == 0) {
        vm.reportError("ArgumentError: union array cannot be empty.\n", .{});
        return error.RuntimeError;
    }

    var scratch_indices = std.ArrayListUnmanaged(u32).empty;
    defer scratch_indices.deinit(vm.allocator);

    for (parts.items.items) |part| {
        if (!part.isGeometry()) {
            vm.reportError("TypeError: union array must contain only Geometries.\n", .{});
            return error.RuntimeError;
        }
        try scratch_indices.append(vm.allocator, part.asGeometry().dag_idx);
    }

    const dag_idx = try vm.dag_builder.addBatchUnion(scratch_indices.items);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativeBatchHull(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count != 1 or !args[0].isArray()) {
        vm.reportError("ArgumentError: batch_hull expects exactly 1 Array argument.\n", .{});
        return error.RuntimeError;
    }

    const parts = args[0].asArray();
    if (parts.items.items.len == 0) {
        vm.reportError("ArgumentError: batch_hull array cannot be empty.\n", .{});
        return error.RuntimeError;
    }

    var scratch_indices = std.ArrayListUnmanaged(u32).empty;
    defer scratch_indices.deinit(vm.allocator);

    for (parts.items.items) |part| {
        if (!part.isGeometry()) {
            vm.reportError("TypeError: batch_hull array must contain only Geometries.\n", .{});
            return error.RuntimeError;
        }
        try scratch_indices.append(vm.allocator, part.asGeometry().dag_idx);
    }

    const dag_idx = try vm.dag_builder.addBatchHull(scratch_indices.items);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}
