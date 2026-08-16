const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

pub fn mathSin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.sin(args[0].asNumber()));
}

pub fn mathCos(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.cos(args[0].asNumber()));
}

pub fn mathTan(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.tan(args[0].asNumber()));
}

pub fn mathSqrt(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.sqrt(args[0].asNumber()));
}

pub fn mathAbs(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@abs(args[0].asNumber()));
}

pub fn mathAsin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.asin(args[0].asNumber()));
}

pub fn mathAcos(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.acos(args[0].asNumber()));
}

pub fn mathAtan2(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 2 or !args[0].isNumber() or !args[1].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.atan2(args[0].asNumber(), args[1].asNumber()));
}

pub fn mathRound(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@round(args[0].asNumber()));
}

pub fn mathCeil(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@ceil(args[0].asNumber()));
}

pub fn mathFloor(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@floor(args[0].asNumber()));
}

pub fn mathDeg2Rad(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(args[0].asNumber() * std.math.pi / 180.0);
}

pub fn mathRad2Deg(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(args[0].asNumber() * 180.0 / std.math.pi);
}

pub fn mathMin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 2 or !args[0].isNumber() or !args[1].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@min(args[0].asNumber(), args[1].asNumber()));
}

pub fn mathMax(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 2 or !args[0].isNumber() or !args[1].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@max(args[0].asNumber(), args[1].asNumber()));
}

pub const methods = [_]common.MethodDef{
    .{ .name = "sin", .func = mathSin },
    .{ .name = "cos", .func = mathCos },
    .{ .name = "tan", .func = mathTan },
    .{ .name = "asin", .func = mathAsin },
    .{ .name = "acos", .func = mathAcos },
    .{ .name = "atan2", .func = mathAtan2 },
    .{ .name = "sqrt", .func = mathSqrt },
    .{ .name = "abs", .func = mathAbs },
    .{ .name = "round", .func = mathRound },
    .{ .name = "ceil", .func = mathCeil },
    .{ .name = "floor", .func = mathFloor },
    .{ .name = "deg2rad", .func = mathDeg2Rad },
    .{ .name = "rad2deg", .func = mathRad2Deg },
    .{ .name = "min", .func = mathMin },
    .{ .name = "max", .func = mathMax },
};
