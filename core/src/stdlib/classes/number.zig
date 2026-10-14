const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");
const iteration = @import("iteration.zig");

pub fn numberRound(vm: *VM, receiver: value.Value, decimals_opt: ?f64) !value.Value {
    _ = vm;
    const num = receiver.asNumber();
    const decimals = decimals_opt orelse 0.0;

    if (decimals == 0.0) {
        return value.Value.initNumber(@round(num));
    } else {
        const multiplier = std.math.pow(f64, 10.0, decimals);
        return value.Value.initNumber(@round(num * multiplier) / multiplier);
    }
}

pub fn numberCeil(vm: *VM, receiver: value.Value) !value.Value {
    _ = vm;
    return value.Value.initNumber(@ceil(receiver.asNumber()));
}

pub fn numberFloor(vm: *VM, receiver: value.Value) !value.Value {
    _ = vm;
    return value.Value.initNumber(@floor(receiver.asNumber()));
}

pub fn numberAbs(vm: *VM, receiver: value.Value) !value.Value {
    _ = vm;
    return value.Value.initNumber(@abs(receiver.asNumber()));
}

pub fn numberToI(vm: *VM, receiver: value.Value) !value.Value {
    _ = vm;
    return value.Value.initNumber(@trunc(receiver.asNumber()));
}

pub fn numberToF(vm: *VM, receiver: value.Value) !value.Value {
    _ = vm;
    return receiver;
}

pub fn numberToS(vm: *VM, receiver: value.Value) !value.Value {
    var buf: [64]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{f}", .{value.fmtNumber(receiver.asNumber())});
    return try vm.allocateString(str);
}

/// Number#times { |i| ... }: yields 0...n; a negative n yields nothing (Ruby).
pub fn numberTimes(vm: *VM, receiver: value.Value, block: ?*value.ObjClosure) !value.Value {
    const n = receiver.asNumber();
    try iteration.requireInteger(vm, n, "times");
    const b = try iteration.requireBlock(vm, block, "times");
    return iteration.each(vm, .{ .start = 0, .end = n, .step = 1, .is_exclusive = true }, receiver, b, "times");
}

/// Number#upto(limit) { |i| ... }: yields receiver..limit counting up.
pub fn numberUpto(vm: *VM, receiver: value.Value, limit: f64, block: ?*value.ObjClosure) !value.Value {
    return countTo(vm, receiver, limit, 1, block, "upto");
}

/// Number#downto(limit) { |i| ... }: yields receiver..limit counting down.
pub fn numberDownto(vm: *VM, receiver: value.Value, limit: f64, block: ?*value.ObjClosure) !value.Value {
    return countTo(vm, receiver, limit, -1, block, "downto");
}

fn countTo(vm: *VM, receiver: value.Value, limit: f64, step: f64, block: ?*value.ObjClosure, method: []const u8) !value.Value {
    try iteration.requireInteger(vm, receiver.asNumber(), method);
    try iteration.requireInteger(vm, limit, method);
    const b = try iteration.requireBlock(vm, block, method);
    return iteration.each(vm, .{ .start = receiver.asNumber(), .end = limit, .step = step, .is_exclusive = false }, receiver, b, method);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "times", .func = common.wrapMethod(numberTimes) },
    .{ .name = "upto", .func = common.wrapMethod(numberUpto) },
    .{ .name = "downto", .func = common.wrapMethod(numberDownto) },
    .{ .name = "to_s", .func = common.wrapMethod(numberToS) },
    .{ .name = "to_i", .func = common.wrapMethod(numberToI) },
    .{ .name = "to_f", .func = common.wrapMethod(numberToF) },
    .{ .name = "round", .func = common.wrapMethod(numberRound) },
    .{ .name = "ceil", .func = common.wrapMethod(numberCeil) },
    .{ .name = "floor", .func = common.wrapMethod(numberFloor) },
    .{ .name = "abs", .func = common.wrapMethod(numberAbs) },
};
