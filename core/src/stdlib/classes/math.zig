const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

pub fn mathSin(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(std.math.sin(x));
}
pub fn mathCos(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(std.math.cos(x));
}
pub fn mathTan(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(std.math.tan(x));
}
pub fn mathSqrt(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(std.math.sqrt(x));
}
pub fn mathAbs(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(@abs(x));
}
pub fn mathAsin(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(std.math.asin(x));
}
pub fn mathAcos(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(std.math.acos(x));
}
pub fn mathAtan2(vm: *VM, receiver: value.Value, y: f64, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(std.math.atan2(y, x));
}
pub fn mathRound(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(@round(x));
}
pub fn mathCeil(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(@ceil(x));
}
pub fn mathFloor(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(@floor(x));
}
pub fn mathDeg2Rad(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(x * std.math.pi / 180.0);
}
pub fn mathRad2Deg(vm: *VM, receiver: value.Value, x: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(x * 180.0 / std.math.pi);
}
pub fn mathMin(vm: *VM, receiver: value.Value, a: f64, b: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(@min(a, b));
}
pub fn mathMax(vm: *VM, receiver: value.Value, a: f64, b: f64) !value.Value {
    _ = vm;
    _ = receiver;
    return value.Value.initNumber(@max(a, b));
}

pub const methods = [_]common.MethodDef{
    .{ .name = "sin", .func = common.wrapMethod(mathSin) },
    .{ .name = "cos", .func = common.wrapMethod(mathCos) },
    .{ .name = "tan", .func = common.wrapMethod(mathTan) },
    .{ .name = "asin", .func = common.wrapMethod(mathAsin) },
    .{ .name = "acos", .func = common.wrapMethod(mathAcos) },
    .{ .name = "atan2", .func = common.wrapMethod(mathAtan2) },
    .{ .name = "sqrt", .func = common.wrapMethod(mathSqrt) },
    .{ .name = "abs", .func = common.wrapMethod(mathAbs) },
    .{ .name = "round", .func = common.wrapMethod(mathRound) },
    .{ .name = "ceil", .func = common.wrapMethod(mathCeil) },
    .{ .name = "floor", .func = common.wrapMethod(mathFloor) },
    .{ .name = "deg2rad", .func = common.wrapMethod(mathDeg2Rad) },
    .{ .name = "rad2deg", .func = common.wrapMethod(mathRad2Deg) },
    .{ .name = "min", .func = common.wrapMethod(mathMin) },
    .{ .name = "max", .func = common.wrapMethod(mathMax) },
};
