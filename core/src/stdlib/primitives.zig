const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

pub fn nativeCube(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const x = if (arg_count > 0 and args[0].isNumber()) args[0].asNumber() else 1.0;
    const y = if (arg_count > 1 and args[1].isNumber()) args[1].asNumber() else 1.0;
    const z = if (arg_count > 2 and args[2].isNumber()) args[2].asNumber() else 1.0;
    const center = if (arg_count > 3 and args[3].isBool()) args[3].asBool() else false;

    const dag_idx = try vm.dag_builder.addCube(x, y, z, center);

    const ptr = try vm.allocator.create(value.ObjGeometry);
    ptr.* = .{
        .obj = .{ .obj_type = .geometry, .is_marked = false, .next = null },
        .ref_count = 1,
        .dag_idx = dag_idx,
        .cached_handle = null,
        .cached_bbox = null,
        .cached_topology = null,
    };
    return value.Value.initGeometry(ptr);
}

pub fn nativeCylinder(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const r = if (arg_count > 0 and args[0].isNumber()) args[0].asNumber() else 1.0;
    const h = if (arg_count > 1 and args[1].isNumber()) args[1].asNumber() else 1.0;
    const center = if (arg_count > 2 and args[2].isBool()) args[2].asBool() else false;

    const dag_idx = try vm.dag_builder.addCylinder(r, h, center);

    const ptr = try vm.allocator.create(value.ObjGeometry);
    ptr.* = .{
        .obj = .{ .obj_type = .geometry, .is_marked = false, .next = null },
        .ref_count = 1,
        .dag_idx = dag_idx,
        .cached_handle = null,
        .cached_bbox = null,
        .cached_topology = null,
    };
    return value.Value.initGeometry(ptr);
}

pub fn nativeSphere(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const r = if (arg_count > 0 and args[0].isNumber()) args[0].asNumber() else 1.0;

    const dag_idx = try vm.dag_builder.addSphere(r);

    const ptr = try vm.allocator.create(value.ObjGeometry);
    ptr.* = .{
        .obj = .{ .obj_type = .geometry, .is_marked = false, .next = null },
        .ref_count = 1,
        .dag_idx = dag_idx,
        .cached_handle = null,
        .cached_bbox = null,
        .cached_topology = null,
    };
    return value.Value.initGeometry(ptr);
}
