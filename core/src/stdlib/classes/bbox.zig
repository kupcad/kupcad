const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

inline fn getField(inst: *value.ObjInstance, name: []const u8) f64 {
    if (inst.fields.get(name)) |v| return v.asNumber();
    return 0.0;
}

fn buildVec3(vm: *VM, x: f64, y: f64, z: f64) !value.Value {
    const arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&arr.obj));
    defer _ = vm.pop();

    try arr.items.append(vm.allocator, value.Value.initNumber(x));
    try arr.items.append(vm.allocator, value.Value.initNumber(y));
    try arr.items.append(vm.allocator, value.Value.initNumber(z));
    return value.Value.initObj(&arr.obj);
}

pub fn bboxSize(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const inst = (args - 1)[0].asInstance();
    return buildVec3(vm, getField(inst, "size_x"), getField(inst, "size_y"), getField(inst, "size_z"));
}

pub fn bboxCenter(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const inst = (args - 1)[0].asInstance();
    return buildVec3(vm, getField(inst, "center_x"), getField(inst, "center_y"), getField(inst, "center_z"));
}

pub fn bboxMin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const inst = (args - 1)[0].asInstance();
    return buildVec3(vm, getField(inst, "min_x"), getField(inst, "min_y"), getField(inst, "min_z"));
}

pub fn bboxMax(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const inst = (args - 1)[0].asInstance();
    return buildVec3(vm, getField(inst, "max_x"), getField(inst, "max_y"), getField(inst, "max_z"));
}

pub const methods = [_]common.MethodDef{
    .{ .name = "size", .func = bboxSize },
    .{ .name = "center", .func = bboxCenter },
    .{ .name = "min", .func = bboxMin },
    .{ .name = "max", .func = bboxMax },
};
