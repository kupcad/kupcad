const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");
const util = @import("../methods/util.zig");

// Math functions are methods of the Math object; the receiver carries nothing.

/// A one-number Math function such as Math.sin.
fn math1(comptime f: anytype, comptime name: []const u8) value.NativeFn {
    return common.wrapMethod(struct {
        fn call(vm: *VM, receiver: value.Value, x: f64) !value.Value {
            _ = receiver;
            return result(vm, name, &.{x}, f(x));
        }
    }.call);
}

/// A two-number Math function such as Math.atan2.
fn math2(comptime f: anytype, comptime name: []const u8) value.NativeFn {
    return common.wrapMethod(struct {
        fn call(vm: *VM, receiver: value.Value, x: f64, y: f64) !value.Value {
            _ = receiver;
            return result(vm, name, &.{ x, y }, f(x, y));
        }
    }.call);
}

/// A three-number Math function such as Math.clamp.
fn math3(comptime f: anytype, comptime name: []const u8) value.NativeFn {
    return common.wrapMethod(struct {
        fn call(vm: *VM, receiver: value.Value, a: f64, b: f64, c: f64) !value.Value {
            _ = receiver;
            return result(vm, name, &.{ a, b, c }, f(a, b, c));
        }
    }.call);
}

/// Like arithmetic, a Math function given finite numbers raises rather than return NaN
/// (`Math.sqrt(-1)`, `Math.asin(2)` used to) or Infinity.
fn result(vm: *VM, comptime name: []const u8, args: []const f64, res: f64) !value.Value {
    for (args) |a| {
        if (!std.math.isFinite(a)) return value.Value.initNumber(res);
    }
    if (std.math.isNan(res)) {
        _ = vm.raiseError(.MathError, name ++ "({f}) has no real result", .{value.fmtNumber(args[0])});
        return error.RuntimeError;
    }
    if (std.math.isInf(res)) {
        _ = vm.raiseError(.RangeError, name ++ " overflows: the result is beyond the largest number", .{});
        return error.RuntimeError;
    }
    return value.Value.initNumber(res);
}

/// Math.min / Math.max over any number of numbers (nil for none).
fn mathExtremum(comptime pick: anytype, comptime name: []const u8) value.NativeFn {
    return common.wrapMethod(struct {
        fn call(vm: *VM, receiver: value.Value, nums: []const value.Value) !value.Value {
            _ = receiver;
            if (nums.len == 0) return value.Value.initNil();
            var best = try util.requireNumber(vm, nums[0], name, "argument 1");
            for (nums[1..], 2..) |n, i| {
                var label_buf: [24]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "argument {d}", .{i}) catch "an argument";
                best = pick(best, try util.requireNumber(vm, n, name, label));
            }
            return value.Value.initNumber(best);
        }
    }.call);
}

fn abs(x: f64) f64 {
    return @abs(x);
}
fn round(x: f64) f64 {
    return @round(x);
}
fn ceil(x: f64) f64 {
    return @ceil(x);
}
fn floor(x: f64) f64 {
    return @floor(x);
}
fn deg2rad(x: f64) f64 {
    return x * std.math.pi / 180.0;
}
fn rad2deg(x: f64) f64 {
    return x * 180.0 / std.math.pi;
}
fn sign(x: f64) f64 {
    return if (x > 0.0) 1.0 else if (x < 0.0) -1.0 else 0.0;
}
fn atan2(y: f64, x: f64) f64 {
    return std.math.atan2(y, x);
}
fn hypot(x: f64, y: f64) f64 {
    return std.math.hypot(x, y);
}
fn clamp(v: f64, lo: f64, hi: f64) f64 {
    return std.math.clamp(v, lo, hi);
}
/// a + (b - a) * t
fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}
fn min(a: f64, b: f64) f64 {
    return @min(a, b);
}
fn max(a: f64, b: f64) f64 {
    return @max(a, b);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "sin", .func = math1(std.math.sin, "Math.sin") },
    .{ .name = "cos", .func = math1(std.math.cos, "Math.cos") },
    .{ .name = "tan", .func = math1(std.math.tan, "Math.tan") },
    .{ .name = "asin", .func = math1(std.math.asin, "Math.asin") },
    .{ .name = "acos", .func = math1(std.math.acos, "Math.acos") },
    .{ .name = "atan2", .func = math2(atan2, "Math.atan2") },
    .{ .name = "sqrt", .func = math1(std.math.sqrt, "Math.sqrt") },
    .{ .name = "abs", .func = math1(abs, "Math.abs") },
    .{ .name = "round", .func = math1(round, "Math.round") },
    .{ .name = "ceil", .func = math1(ceil, "Math.ceil") },
    .{ .name = "floor", .func = math1(floor, "Math.floor") },
    .{ .name = "deg2rad", .func = math1(deg2rad, "Math.deg2rad") },
    .{ .name = "rad2deg", .func = math1(rad2deg, "Math.rad2deg") },
    .{ .name = "min", .func = mathExtremum(min, "Math.min") },
    .{ .name = "max", .func = mathExtremum(max, "Math.max") },
    .{ .name = "clamp", .func = math3(clamp, "Math.clamp") },
    .{ .name = "lerp", .func = math3(lerp, "Math.lerp") },
    .{ .name = "hypot", .func = math2(hypot, "Math.hypot") },
    .{ .name = "sign", .func = math1(sign, "Math.sign") },
};
