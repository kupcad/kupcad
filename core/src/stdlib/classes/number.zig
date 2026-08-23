const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

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
    const str = try std.fmt.bufPrint(&buf, "{d}", .{receiver.asNumber()});
    return try vm.allocateString(str);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "to_s", .func = common.wrapMethod(numberToS) },
    .{ .name = "to_i", .func = common.wrapMethod(numberToI) },
    .{ .name = "to_f", .func = common.wrapMethod(numberToF) },
    .{ .name = "round", .func = common.wrapMethod(numberRound) },
    .{ .name = "ceil", .func = common.wrapMethod(numberCeil) },
    .{ .name = "floor", .func = common.wrapMethod(numberFloor) },
    .{ .name = "abs", .func = common.wrapMethod(numberAbs) },
};
