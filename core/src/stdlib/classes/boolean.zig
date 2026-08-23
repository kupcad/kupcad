const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

pub fn toS(vm: *VM, receiver: value.Value) !value.Value {
    const str = if (receiver.asBool()) "true" else "false";
    return try vm.allocateString(str);
}

pub fn toNum(vm: *VM, receiver: value.Value) !value.Value {
    _ = vm;
    const num_val: f64 = if (receiver.asBool()) 1.0 else 0.0;
    return value.Value.initNumber(num_val);
}

pub fn invert(vm: *VM, receiver: value.Value) !value.Value {
    _ = vm;
    return value.Value.initBool(!receiver.asBool());
}

pub const methods = [_]common.MethodDef{
    .{ .name = "to_s", .func = common.wrapMethod(toS) },
    .{ .name = "inspect", .func = common.wrapMethod(toS) },
    .{ .name = "to_i", .func = common.wrapMethod(toNum) },
    .{ .name = "to_f", .func = common.wrapMethod(toNum) },
    .{ .name = "invert", .func = common.wrapMethod(invert) },
};
