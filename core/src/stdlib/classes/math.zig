const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

// Math Macros
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

fn wrapMath2(comptime func: anytype) value.NativeFn {
    return struct {
        fn wrapper(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
            const vm: *VM = @ptrCast(@alignCast(vm_opaque));
            if (arg_count < 2 or !args[0].isNumber() or !args[1].isNumber()) {
                vm.reportError("RuntimeError: Math function expects two numbers.\n", .{});
                return error.RuntimeError;
            }
            return value.Value.initNumber(@call(.auto, func, .{ args[0].asNumber(), args[1].asNumber() }));
        }
    }.wrapper;
}

// Builtins must be explicitly wrapped to pass their function pointers
fn mathMin(a: f64, b: f64) f64 {
    return @min(a, b);
}
fn mathMax(a: f64, b: f64) f64 {
    return @max(a, b);
}
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

pub const methods = [_]common.MethodDef{
    .{ .name = "sin", .func = wrapMath1(std.math.sin) },
    .{ .name = "cos", .func = wrapMath1(std.math.cos) },
    .{ .name = "tan", .func = wrapMath1(std.math.tan) },
    .{ .name = "asin", .func = wrapMath1(std.math.asin) },
    .{ .name = "acos", .func = wrapMath1(std.math.acos) },
    .{ .name = "atan2", .func = wrapMath2(std.math.atan2) },
    .{ .name = "sqrt", .func = wrapMath1(std.math.sqrt) },
    .{ .name = "abs", .func = wrapMath1(mathAbs) },
    .{ .name = "round", .func = wrapMath1(mathRound) },
    .{ .name = "ceil", .func = wrapMath1(mathCeil) },
    .{ .name = "floor", .func = wrapMath1(mathFloor) },
    .{ .name = "deg2rad", .func = wrapMath1(mathDeg2Rad) },
    .{ .name = "rad2deg", .func = wrapMath1(mathRad2Deg) },
    .{ .name = "min", .func = wrapMath2(mathMin) },
    .{ .name = "max", .func = wrapMath2(mathMax) },
};
