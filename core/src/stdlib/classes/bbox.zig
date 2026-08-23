const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

fn getSafeInstance(vm: *VM, args: [*]value.Value) !*value.ObjInstance {
    const receiver = vm.getReceiver(args);
    if (!receiver.isInstance()) {
        vm.reportError("TypeError: Expected BoundingBox instance.\n", .{});
        return error.RuntimeError;
    }
    return receiver.asInstance();
}

inline fn getField(inst: *value.ObjInstance, name: []const u8) f64 {
    if (inst.class.instance_layout.get(name)) |idx| {
        if (idx < inst.fields.items.len and inst.fields.items[idx].isNumber()) {
            return inst.fields.items[idx].asNumber();
        }
    }
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

    // Use the safe unboxer instead of std.debug.assert
    const inst = try getSafeInstance(vm, args);

    // Sanity check: Size should never be negative
    const sx = @max(0.0, getField(inst, "size_x"));
    const sy = @max(0.0, getField(inst, "size_y"));
    const sz = @max(0.0, getField(inst, "size_z"));

    return buildVec3(vm, sx, sy, sz);
}

pub fn bboxCenter(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const inst = try getSafeInstance(vm, args);
    return buildVec3(vm, getField(inst, "center_x"), getField(inst, "center_y"), getField(inst, "center_z"));
}

pub fn bboxMin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const inst = vm.getReceiver(args).asInstance();
    return buildVec3(vm, getField(inst, "min_x"), getField(inst, "min_y"), getField(inst, "min_z"));
}

pub fn bboxMax(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const inst = vm.getReceiver(args).asInstance();
    return buildVec3(vm, getField(inst, "max_x"), getField(inst, "max_y"), getField(inst, "max_z"));
}

/// Rich string formatting for `inspect(bbox)` and `bbox.to_s()`
pub fn bboxToS(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const inst = vm.getReceiver(args).asInstance();

    const min_x = getField(inst, "min_x");
    const min_y = getField(inst, "min_y");
    const min_z = getField(inst, "min_z");
    const max_x = getField(inst, "max_x");
    const max_y = getField(inst, "max_y");
    const max_z = getField(inst, "max_z");
    const sz_x = getField(inst, "size_x");
    const sz_y = getField(inst, "size_y");
    const sz_z = getField(inst, "size_z");

    var buf: [256]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "BoundingBox(min: [{d}, {d}, {d}], max: [{d}, {d}, {d}], size: [{d}, {d}, {d}])", .{
        min_x, min_y, min_z,
        max_x, max_y, max_z,
        sz_x,  sz_y,  sz_z,
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
