const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");
const util = @import("../methods/util.zig");
const iteration = @import("iteration.zig");

const Exact = struct { at: f64, value: f64 };

/// Exact sines at the angles in [0, 360) where the sine is 0, ±1/2 or ±1.
const EXACT_SIN = [_]Exact{
    .{ .at = 0, .value = 0 },   .{ .at = 30, .value = 0.5 },   .{ .at = 90, .value = 1 },   .{ .at = 150, .value = 0.5 },
    .{ .at = 180, .value = 0 }, .{ .at = 210, .value = -0.5 }, .{ .at = 270, .value = -1 }, .{ .at = 330, .value = -0.5 },
};
/// Exact tangents at the angles in [0, 180) where the tangent is 0 or ±1.
const EXACT_TAN = [_]Exact{ .{ .at = 0, .value = 0 }, .{ .at = 45, .value = 1 }, .{ .at = 135, .value = -1 } };

/// Exact inverse sines (degrees) of 0, ±1/2 and ±1; inverse cosines follow as 90 - asind.
const EXACT_ASIN = [_]Exact{ .{ .at = -1, .value = -90 }, .{ .at = -0.5, .value = -30 }, .{ .at = 0, .value = 0 }, .{ .at = 0.5, .value = 30 }, .{ .at = 1, .value = 90 } };
const EXACT_ATAN = [_]Exact{ .{ .at = -1, .value = -45 }, .{ .at = 0, .value = 0 }, .{ .at = 1, .value = 45 } };

/// Math.close?'s tolerance when none is given.
const DEFAULT_TOLERANCE = 1e-9;

/// Past 2^53 a float no longer holds every whole number.
const MAX_EXACT_INT: f64 = 9007199254740992;

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
/// (`Math.sqrt(-1)`, `Math.asin(2)` used to) or Infinity (`Math.log(0)`, `Math.exp(1000)`).
fn result(vm: *VM, comptime name: []const u8, args: []const f64, res: f64) !value.Value {
    for (args) |a| {
        if (!std.math.isFinite(a)) return value.Value.initNumber(res);
    }
    if (std.math.isNan(res)) {
        _ = vm.raiseError(.MathError, name ++ "({f}) has no real result", .{ArgList{ .args = args }});
        return error.RuntimeError;
    }
    if (std.math.isInf(res)) {
        _ = vm.raiseError(.RangeError, name ++ "({f}) is infinite", .{ArgList{ .args = args }});
        return error.RuntimeError;
    }
    return value.Value.initNumber(res);
}

/// "1, 0": a call's numbers for an error message.
const ArgList = struct {
    args: []const f64,

    pub fn format(self: ArgList, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.args, 0..) |a, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{f}", .{value.fmtNumber(a)});
        }
    }
};

/// Math.log(x) or Math.log(x, base).
fn mathLog(vm: *VM, receiver: value.Value, x: f64, base: ?f64) !value.Value {
    _ = receiver;
    if (base) |b| return result(vm, "Math.log", &.{ x, b }, @log(x) / @log(b));
    return result(vm, "Math.log", &.{x}, @log(x));
}

/// Math.hypot(x, y, ...): the length of a vector of any number of components, so
/// `Math.hypot(dx, dy, dz)` is a 3D distance (Ruby's takes exactly two).
fn mathHypot(vm: *VM, receiver: value.Value, nums: []const value.Value) !value.Value {
    _ = receiver;
    var len: f64 = 0;
    for (nums, 1..) |n, i| {
        var label_buf: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "argument {d}", .{i}) catch "an argument";
        len = std.math.hypot(len, try util.requireNumber(vm, n, "Math.hypot", label));
    }
    return value.Value.initNumber(len);
}

// --- Angles in degrees -----------------------------------------------------------------
// CAD angles are degrees (`rotate(z: 30)`), so Math has degree versions of the trig
// functions. Each is exact where the true value is a simple fraction: `Math.cosd(90)` is 0,
// where `Math.cos(Math::PI / 2)` is 6.1e-17, enough to leave slivers between parts.

fn lookup(table: []const Exact, at: f64) ?f64 {
    for (table) |e| {
        if (e.at == at) return e.value;
    }
    return null;
}

fn sind(deg: f64) f64 {
    if (!std.math.isFinite(deg)) return std.math.nan(f64);
    const turn = @mod(deg, 360.0);
    return lookup(&EXACT_SIN, turn) orelse @sin(turn * std.math.pi / 180.0);
}
fn cosd(deg: f64) f64 {
    return sind(deg + 90.0);
}
/// NaN at ±90° and the like, where the tangent has no value (a MathError).
fn tand(deg: f64) f64 {
    if (!std.math.isFinite(deg)) return std.math.nan(f64);
    const half_turn = @mod(deg, 180.0);
    if (half_turn == 90) return std.math.nan(f64);
    return lookup(&EXACT_TAN, half_turn) orelse @tan(half_turn * std.math.pi / 180.0);
}

fn asind(x: f64) f64 {
    return lookup(&EXACT_ASIN, x) orelse rad2deg(std.math.asin(x));
}
fn acosd(x: f64) f64 {
    if (lookup(&EXACT_ASIN, x)) |a| return 90 - a;
    return rad2deg(std.math.acos(x));
}
fn atand(x: f64) f64 {
    return lookup(&EXACT_ATAN, x) orelse rad2deg(std.math.atan(x));
}
/// The direction of (x, y) in degrees, in (-180, 180]; exact along the axes and diagonals.
fn atan2d(y: f64, x: f64) f64 {
    if (y == 0 and x >= 0) return 0;
    if (y == 0) return 180;
    if (x == 0) return if (y > 0) 90 else -90;
    if (@abs(y) == @abs(x)) return if (x > 0) (if (y > 0) 45 else -45) else (if (y > 0) 135 else -135);
    return rad2deg(std.math.atan2(y, x));
}

// --- Modelling helpers -------------------------------------------------------------------

/// Math.snap(x, step): `x` rounded to the nearest multiple of `step` (a grid, a hole pitch).
fn mathSnap(vm: *VM, receiver: value.Value, x: f64, step: f64) !value.Value {
    _ = receiver;
    if (!(step > 0) or !std.math.isFinite(step)) {
        _ = vm.raiseError(.ValueError, "Math.snap step must be a finite number greater than zero, got {f}", .{value.fmtNumber(step)});
        return error.RuntimeError;
    }
    return result(vm, "Math.snap", &.{ x, step }, @round(x / step) * step);
}

/// Math.remap(x, from_lo, from_hi, to_lo, to_hi): `x`'s place in one range, carried to
/// another (not clamped: values outside extrapolate).
fn mathRemap(vm: *VM, receiver: value.Value, x: f64, from_lo: f64, from_hi: f64, to_lo: f64, to_hi: f64) !value.Value {
    _ = receiver;
    try requireSpan(vm, "Math.remap", from_lo, from_hi);
    return result(vm, "Math.remap", &.{ x, from_lo, from_hi, to_lo, to_hi }, to_lo + (x - from_lo) * (to_hi - to_lo) / (from_hi - from_lo));
}

/// Math.smoothstep(edge0, edge1, x): 0 below edge0, 1 above edge1, and an S-curve between
/// (3t² - 2t³), for blending profiles and fillets.
fn mathSmoothstep(vm: *VM, receiver: value.Value, edge0: f64, edge1: f64, x: f64) !value.Value {
    _ = receiver;
    try requireSpan(vm, "Math.smoothstep", edge0, edge1);
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0, 1);
    return result(vm, "Math.smoothstep", &.{ edge0, edge1, x }, t * t * (3 - 2 * t));
}

fn requireSpan(vm: *VM, comptime name: []const u8, lo: f64, hi: f64) !void {
    if (lo == hi) {
        _ = vm.raiseError(.ValueError, name ++ " needs a range of two different numbers, got {f} and {f}", .{ value.fmtNumber(lo), value.fmtNumber(hi) });
        return error.RuntimeError;
    }
}

/// Math.close?(a, b, tolerance = 1e-9): whether a and b differ by at most `tolerance`, for
/// comparing measurements, which floating point rarely makes exactly equal.
fn mathClose(vm: *VM, receiver: value.Value, a: f64, b: f64, tolerance: ?f64) !value.Value {
    _ = receiver;
    const tol = tolerance orelse DEFAULT_TOLERANCE;
    if (!(tol >= 0)) {
        _ = vm.raiseError(.ValueError, "Math.close? tolerance must be zero or more, got {f}", .{value.fmtNumber(tol)});
        return error.RuntimeError;
    }
    return value.Value.initBool(@abs(a - b) <= tol);
}

/// Math.gcd(a, b) and Math.lcm(a, b), of whole numbers (gear tooth counts, pitches).
fn mathGcd(vm: *VM, receiver: value.Value, a: f64, b: f64) !value.Value {
    _ = receiver;
    return value.Value.initNumber(@floatFromInt(try gcdOf(vm, "Math.gcd", a, b)));
}
fn mathLcm(vm: *VM, receiver: value.Value, a: f64, b: f64) !value.Value {
    _ = receiver;
    const g = try gcdOf(vm, "Math.lcm", a, b);
    if (g == 0) return value.Value.initNumber(0);
    return result(vm, "Math.lcm", &.{ a, b }, @abs(a) / @as(f64, @floatFromInt(g)) * @abs(b));
}
fn gcdOf(vm: *VM, comptime name: []const u8, a: f64, b: f64) !u64 {
    try iteration.requireInteger(vm, a, name);
    try iteration.requireInteger(vm, b, name);
    if (@abs(a) > MAX_EXACT_INT or @abs(b) > MAX_EXACT_INT) {
        _ = vm.raiseError(.RangeError, name ++ " works on whole numbers up to 2^53, got {f} and {f}", .{ value.fmtNumber(a), value.fmtNumber(b) });
        return error.RuntimeError;
    }
    var x: u64 = @intFromFloat(@abs(a));
    var y: u64 = @intFromFloat(@abs(b));
    while (y != 0) {
        const r = x % y;
        x = y;
        y = r;
    }
    return x;
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
fn exp(x: f64) f64 {
    return @exp(x);
}
fn log2(x: f64) f64 {
    return @log2(x);
}
fn log10(x: f64) f64 {
    return @log10(x);
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
    .{ .name = "atan", .func = math1(std.math.atan, "Math.atan") },
    .{ .name = "atan2", .func = math2(atan2, "Math.atan2") },
    .{ .name = "sind", .func = math1(sind, "Math.sind") },
    .{ .name = "cosd", .func = math1(cosd, "Math.cosd") },
    .{ .name = "tand", .func = math1(tand, "Math.tand") },
    .{ .name = "asind", .func = math1(asind, "Math.asind") },
    .{ .name = "acosd", .func = math1(acosd, "Math.acosd") },
    .{ .name = "atand", .func = math1(atand, "Math.atand") },
    .{ .name = "atan2d", .func = math2(atan2d, "Math.atan2d") },
    .{ .name = "sqrt", .func = math1(std.math.sqrt, "Math.sqrt") },
    .{ .name = "cbrt", .func = math1(std.math.cbrt, "Math.cbrt") },
    .{ .name = "exp", .func = math1(exp, "Math.exp") },
    .{ .name = "log", .func = common.wrapMethod(mathLog) },
    .{ .name = "log2", .func = math1(log2, "Math.log2") },
    .{ .name = "log10", .func = math1(log10, "Math.log10") },
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
    .{ .name = "hypot", .func = common.wrapMethod(mathHypot) },
    .{ .name = "sign", .func = math1(sign, "Math.sign") },
    .{ .name = "snap", .func = common.wrapMethod(mathSnap) },
    .{ .name = "remap", .func = common.wrapMethod(mathRemap) },
    .{ .name = "smoothstep", .func = common.wrapMethod(mathSmoothstep) },
    .{ .name = "close?", .func = common.wrapMethod(mathClose) },
    .{ .name = "gcd", .func = common.wrapMethod(mathGcd) },
    .{ .name = "lcm", .func = common.wrapMethod(mathLcm) },
};
