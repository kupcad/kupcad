//! The natives of Number (`round`, `times`, `upto`, `clamp`, `odd?`, ...) and their
//! dispatch table, `methods`.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");
const iteration = @import("iteration.zig");
const arguments = @import("../arguments.zig");

pub fn numberRound(vm: *VM, receiver: value.Value, decimals_opt: ?f64) !value.Value {
    const num = receiver.asNumber();
    const decimals = decimals_opt orelse 0.0;
    if (!std.math.isFinite(decimals)) {
        return vm.fail(.ValueError, "round: the number of decimals must be finite, got {f}", .{value.fmtNumber(decimals)});
    }
    if (decimals == 0.0) return value.Value.initNumber(@round(num));

    const multiplier = std.math.pow(f64, 10.0, decimals);
    // Rounding to the nearest 10^400 leaves nothing; to more decimals than a Number holds
    // (the multiplier or the product overflows) changes nothing. Both gave NaN.
    if (multiplier == 0.0) return value.Value.initNumber(0.0);
    const scaled = num * multiplier;
    if (!std.math.isFinite(multiplier) or !std.math.isFinite(scaled)) return receiver;
    return value.Value.initNumber(@round(scaled) / multiplier);
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
    const str = try std.mem.print(&buf, "{f}", .{value.fmtNumber(receiver.asNumber())});
    return try vm.allocateString(str);
}

/// Number#times { |i| ... }: yields 0...n; a negative n yields nothing (Ruby).
pub fn numberTimes(vm: *VM, receiver: value.Value, block: ?*value.ObjClosure) !value.Value {
    const n = receiver.asNumber();
    try iteration.requireInteger(vm, n, "times");
    const b = try arguments.requireBlock(vm, block, "times");
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
    const b = try arguments.requireBlock(vm, block, method);
    return iteration.each(vm, .{ .start = receiver.asNumber(), .end = limit, .step = step, .is_exclusive = false }, receiver, b, method);
}

/// Number#odd? and #even?, of whole numbers: `2.5.odd?` is a ValueError, as the number
/// has no parity (Ruby's floats have no such methods at all).
fn parity(comptime want_odd: bool, comptime name: []const u8) value.NativeFn {
    return common.wrapMethod(struct {
        fn call(vm: *VM, receiver: value.Value) !value.Value {
            const n = receiver.asNumber();
            try iteration.requireInteger(vm, n, name);
            return value.Value.initBool((@mod(n, 2) == 1) == want_odd);
        }
    }.call);
}

/// A yes/no question about the number: zero?, positive?, finite?, ...
fn predicate(comptime test_fn: fn (f64) bool) value.NativeFn {
    return common.wrapMethod(struct {
        fn call(vm: *VM, receiver: value.Value) !value.Value {
            _ = vm;
            return value.Value.initBool(test_fn(receiver.asNumber()));
        }
    }.call);
}

fn isZero(n: f64) bool {
    return n == 0;
}
fn isPositive(n: f64) bool {
    return n > 0;
}
fn isNegative(n: f64) bool {
    return n < 0;
}
/// A whole number, as `5` or `5.0` (KupCAD has one number type).
fn isInteger(n: f64) bool {
    return std.math.isFinite(n) and @trunc(n) == n;
}
fn isFinite(n: f64) bool {
    return std.math.isFinite(n);
}
fn isNan(n: f64) bool {
    return std.math.isNan(n);
}
/// True for Number::INFINITY and its negative (Ruby returns 1 or -1, which are as truthy).
fn isInfinite(n: f64) bool {
    return std.math.isInf(n);
}

/// Number#clamp(lo, hi): the number kept within lo..hi.
pub fn numberClamp(vm: *VM, receiver: value.Value, lo: f64, hi: f64) !value.Value {
    try requireOrdered(vm, "clamp", lo, hi);
    return value.Value.initNumber(std.math.clamp(receiver.asNumber(), lo, hi));
}

/// Number#between?(lo, hi): whether lo <= number <= hi.
pub fn numberBetween(vm: *VM, receiver: value.Value, lo: f64, hi: f64) !value.Value {
    try requireOrdered(vm, "between?", lo, hi);
    const n = receiver.asNumber();
    return value.Value.initBool(lo <= n and n <= hi);
}

/// `lo <= hi`, else an ArgumentError naming `name` (a NaN bound fails it too).
pub fn requireOrdered(vm: *VM, comptime name: []const u8, lo: f64, hi: f64) !void {
    if (!(lo <= hi)) {
        return vm.fail(.ArgumentError, name ++ " needs its low bound first, got {f} and {f}", .{ value.fmtNumber(lo), value.fmtNumber(hi) });
    }
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
    .{ .name = "odd?", .func = parity(true, "odd?") },
    .{ .name = "even?", .func = parity(false, "even?") },
    .{ .name = "zero?", .func = predicate(isZero) },
    .{ .name = "positive?", .func = predicate(isPositive) },
    .{ .name = "negative?", .func = predicate(isNegative) },
    .{ .name = "integer?", .func = predicate(isInteger) },
    .{ .name = "finite?", .func = predicate(isFinite) },
    .{ .name = "nan?", .func = predicate(isNan) },
    .{ .name = "infinite?", .func = predicate(isInfinite) },
    .{ .name = "clamp", .func = common.wrapMethod(numberClamp) },
    .{ .name = "between?", .func = common.wrapMethod(numberBetween) },
};
