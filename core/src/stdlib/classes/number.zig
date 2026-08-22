const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

pub fn numberRound(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count > 1) return error.RuntimeError; // Takes 0 or 1 args

    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    if (!receiver.isNumber()) return error.RuntimeError;

    const num = receiver.asNumber();
    var decimals: f64 = 0.0;

    if (arg_count == 1) {
        if (!args[0].isNumber()) return error.RuntimeError;
        decimals = args[0].asNumber();
    }

    if (decimals == 0.0) {
        return value.Value.initNumber(@round(num));
    } else {
        const multiplier = std.math.pow(f64, 10.0, decimals);
        return value.Value.initNumber(@round(num * multiplier) / multiplier);
    }
}

pub fn numberCeil(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;

    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    if (!receiver.isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@ceil(receiver.asNumber()));
}

pub fn numberFloor(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;

    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    if (!receiver.isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@floor(receiver.asNumber()));
}

pub fn numberAbs(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;

    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    if (!receiver.isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@abs(receiver.asNumber()));
}

pub fn numberToI(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;

    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    if (!receiver.isNumber()) return error.RuntimeError;
    // Truncates decimal portion
    return value.Value.initNumber(@trunc(receiver.asNumber()));
}

pub fn numberToF(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;

    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    // Number is already a float internally, just return it
    return receiver;
}

// Number to String
pub fn numberToS(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;

    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    if (!receiver.isNumber()) return error.RuntimeError;

    var buf: [64]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{d}", .{receiver.asNumber()});
    return try vm.allocateString(str);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "to_s", .func = numberToS },
    .{ .name = "to_i", .func = numberToI },
    .{ .name = "to_f", .func = numberToF },
    .{ .name = "round", .func = numberRound },
    .{ .name = "ceil", .func = numberCeil },
    .{ .name = "floor", .func = numberFloor },
    .{ .name = "abs", .func = numberAbs },
};
