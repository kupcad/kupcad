const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

// --- Math Macros ---
fn wrapMath1(comptime func: anytype) value.NativeFn {
    return struct {
        fn wrapper(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
            const vm: *VM = @ptrCast(@alignCast(vm_opaque));
            if (arg_count < 1 or !args[0].isNumber()) {
                vm.reportError("RuntimeError: Math function expects a number.\n", .{});
                return error.RuntimeError;
            }
            return value.Value.initNumber(@call(.auto, func, .{args[0].asNumber()}));
        }
    }.wrapper;
}

// Builtins must be explicitly wrapped to pass their function pointers
fn mathAbs(x: f64) f64 {
    return @abs(x);
}
fn mathRound(x: f64) f64 {
    return @round(x);
}
fn mathCeil(x: f64) f64 {
    return @ceil(x);
}
fn mathFloor(x: f64) f64 {
    return @floor(x);
}
fn mathDeg2Rad(x: f64) f64 {
    return x * std.math.pi / 180.0;
}
fn mathRad2Deg(x: f64) f64 {
    return x * 180.0 / std.math.pi;
}

// --- Variadic Math.min ---
pub fn mathMin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count == 0) return value.Value.initNil();

    var min_val = std.math.inf(f64);
    for (0..arg_count) |i| {
        if (!args[i].isNumber()) {
            vm.reportError("RuntimeError: Math.min expects numeric arguments.\n", .{});
            return error.RuntimeError;
        }
        min_val = @min(min_val, args[i].asNumber());
    }
    return value.Value.initNumber(min_val);
}

// --- Variadic Math.max ---
pub fn mathMax(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count == 0) return value.Value.initNil();

    var max_val = -std.math.inf(f64);
    for (0..arg_count) |i| {
        if (!args[i].isNumber()) {
            vm.reportError("RuntimeError: Math.max expects numeric arguments.\n", .{});
            return error.RuntimeError;
        }
        max_val = @max(max_val, args[i].asNumber());
    }
    return value.Value.initNumber(max_val);
}

// --- Specific Arity = 2 for atan2 ---
pub fn mathAtan2(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count < 2 or !args[0].isNumber() or !args[1].isNumber()) {
        vm.reportError("RuntimeError: Math.atan2 expects two numbers.\n", .{});
        return error.RuntimeError;
    }
    return value.Value.initNumber(std.math.atan2(args[0].asNumber(), args[1].asNumber()));
}

// --- CAD-Specific Math Helpers ---

pub fn mathClamp(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count < 3 or !args[0].isNumber() or !args[1].isNumber() or !args[2].isNumber()) {
        vm.reportError("RuntimeError: Math.clamp expects (value, min, max).\n", .{});
        return error.RuntimeError;
    }
    const val = args[0].asNumber();
    const min_val = args[1].asNumber();
    const max_val = args[2].asNumber();
    return value.Value.initNumber(std.math.clamp(val, min_val, max_val));
}

pub fn mathLerp(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count < 3 or !args[0].isNumber() or !args[1].isNumber() or !args[2].isNumber()) {
        vm.reportError("RuntimeError: Math.lerp expects (start, end, t).\n", .{});
        return error.RuntimeError;
    }
    const a = args[0].asNumber();
    const b = args[1].asNumber();
    const t = args[2].asNumber();
    // Standard lerp formula: a + (b - a) * t
    return value.Value.initNumber(a + (b - a) * t);
}

pub fn mathHypot(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count < 2 or !args[0].isNumber() or !args[1].isNumber()) {
        vm.reportError("RuntimeError: Math.hypot expects (x, y).\n", .{});
        return error.RuntimeError;
    }
    const x = args[0].asNumber();
    const y = args[1].asNumber();
    return value.Value.initNumber(std.math.hypot(x, y));
}

pub fn mathSign(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count < 1 or !args[0].isNumber()) {
        vm.reportError("RuntimeError: Math.sign expects a number.\n", .{});
        return error.RuntimeError;
    }
    const val = args[0].asNumber();
    const res: f64 = if (val > 0.0) 1.0 else if (val < 0.0) -1.0 else 0.0;
    return value.Value.initNumber(res);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "sin", .func = wrapMath1(std.math.sin) },
    .{ .name = "cos", .func = wrapMath1(std.math.cos) },
    .{ .name = "tan", .func = wrapMath1(std.math.tan) },
    .{ .name = "asin", .func = wrapMath1(std.math.asin) },
    .{ .name = "acos", .func = wrapMath1(std.math.acos) },
    .{ .name = "atan2", .func = mathAtan2 },
    .{ .name = "sqrt", .func = wrapMath1(std.math.sqrt) },
    .{ .name = "abs", .func = wrapMath1(mathAbs) },
    .{ .name = "round", .func = wrapMath1(mathRound) },
    .{ .name = "ceil", .func = wrapMath1(mathCeil) },
    .{ .name = "floor", .func = wrapMath1(mathFloor) },
    .{ .name = "deg2rad", .func = wrapMath1(mathDeg2Rad) },
    .{ .name = "rad2deg", .func = wrapMath1(mathRad2Deg) },
    .{ .name = "min", .func = mathMin },
    .{ .name = "max", .func = mathMax },
    .{ .name = "clamp", .func = mathClamp },
    .{ .name = "lerp", .func = mathLerp },
    .{ .name = "hypot", .func = mathHypot },
    .{ .name = "sign", .func = mathSign },
};
