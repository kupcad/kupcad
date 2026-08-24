const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

fn getSafeBBox(vm: *VM, args: [*]value.Value) !*value.ObjBBox {
    const receiver = vm.getReceiver(args);
    if (!receiver.isObject() or receiver.asObj().obj_type != .bbox) {
        vm.reportError("TypeError: Expected BoundingBox native object.\n", .{});
        return error.RuntimeError;
    }
    return @as(*value.ObjBBox, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
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
    const bbox = try getSafeBBox(vm, args);
    const sx = @max(0.0, bbox.max[0] - bbox.min[0]);
    const sy = @max(0.0, bbox.max[1] - bbox.min[1]);
    const sz = @max(0.0, bbox.max[2] - bbox.min[2]);
    return buildVec3(vm, sx, sy, sz);
}

pub fn bboxCenter(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const bbox = try getSafeBBox(vm, args);
    const cx = bbox.min[0] + (bbox.max[0] - bbox.min[0]) / 2.0;
    const cy = bbox.min[1] + (bbox.max[1] - bbox.min[1]) / 2.0;
    const cz = bbox.min[2] + (bbox.max[2] - bbox.min[2]) / 2.0;
    return buildVec3(vm, cx, cy, cz);
}

pub fn bboxMin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const bbox = try getSafeBBox(vm, args);
    return buildVec3(vm, bbox.min[0], bbox.min[1], bbox.min[2]);
}

pub fn bboxMax(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const bbox = try getSafeBBox(vm, args);
    return buildVec3(vm, bbox.max[0], bbox.max[1], bbox.max[2]);
}

pub fn bboxToS(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const bbox = try getSafeBBox(vm, args);
    const sx = @max(0.0, bbox.max[0] - bbox.min[0]);
    const sy = @max(0.0, bbox.max[1] - bbox.min[1]);
    const sz = @max(0.0, bbox.max[2] - bbox.min[2]);

    var buf: [256]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "BoundingBox(min: [{d}, {d}, {d}], max: [{d}, {d}, {d}], size: [{d}, {d}, {d}])", .{
        bbox.min[0], bbox.min[1], bbox.min[2],
        bbox.max[0], bbox.max[1], bbox.max[2],
        sx,          sy,          sz,
    });
    return try vm.allocateString(str);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "size", .func = bboxSize },
    .{ .name = "center", .func = bboxCenter },
    .{ .name = "min", .func = bboxMin },
    .{ .name = "max", .func = bboxMax },
    .{ .name = "to_s", .func = bboxToS },
    .{ .name = "inspect", .func = bboxToS },
};
