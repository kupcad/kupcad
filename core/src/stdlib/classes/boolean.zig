const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

pub fn toS(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;

    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    if (!receiver.isBool()) return error.RuntimeError;

    const str = if (receiver.asBool()) "true" else "false";
    return try vm.allocateString(str);
}

pub fn toNum(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;

    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    if (!receiver.isBool()) return error.RuntimeError;

    const num_val: f64 = if (receiver.asBool()) 1.0 else 0.0;
    return value.Value.initNumber(num_val);
}

pub fn invert(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;

    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    if (!receiver.isBool()) return error.RuntimeError;

    return value.Value.initBool(!receiver.asBool());
}

pub const methods = [_]common.MethodDef{
    .{ .name = "to_s", .func = toS },
    .{ .name = "inspect", .func = toS },
    .{ .name = "to_i", .func = toNum },
    .{ .name = "to_f", .func = toNum },
    .{ .name = "invert", .func = invert },
};
