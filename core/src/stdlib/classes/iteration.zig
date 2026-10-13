//! Shared numeric iteration used by Range and Number (times/upto/downto), so both
//! agree on how many values a span yields and what each value is.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const HandleScope = @import("../../vm/scope.zig").HandleScope;
const limits = @import("../../core/limits.zig");

/// An arithmetic sequence start, start + step, ... bounded by `end`.
pub const Span = struct {
    start: f64,
    end: f64,
    step: f64,
    is_exclusive: bool,

    /// Number of values the span yields. Mirrors Ruby's `ruby_float_step_size`: the
    /// epsilon allowance makes `(0..0.3).step(0.1)` yield 4 values even though
    /// `0.3 / 0.1` is 2.9999999999999996 in binary floating point.
    /// Callers must have validated the span (finite, non-zero step).
    pub fn count(self: Span) f64 {
        const n = (self.end - self.start) / self.step;
        const err = @min(0.5, (@abs(self.start) + @abs(self.end) + @abs(self.end - self.start)) / @abs(self.step) * std.math.floatEps(f64));
        if (self.is_exclusive) {
            if (n <= 0) return 0;
            var whole: f64 = if (n < 1) 0 else @floor(n - err);
            const next = (whole + 1) * self.step + self.start;
            if (if (self.start < self.end) next < self.end else next > self.end) whole += 1;
            return whole + 1;
        }
        if (n < 0) return 0;
        return @floor(n + err) + 1;
    }

    /// The i-th value, computed from `start` rather than by accumulation so float
    /// error does not grow with the index; clamped so the last value never overshoots.
    pub fn at(self: Span, i: u64) f64 {
        const d = @as(f64, @floatFromInt(i)) * self.step + self.start;
        if (if (self.step >= 0) self.end < d else d < self.end) return self.end;
        return d;
    }
};

/// Largest count whose indices are all exactly representable as f64 (2^53). Beyond it,
/// `start + i * step` stops producing distinct values, so iteration would be wrong, not just
/// long. This is a correctness bound, not a resource limit: block iteration is governed by
/// the VM's instruction budget and cancellation, exactly like a `while` loop.
const MAX_EXACT_COUNT: u64 = 1 << std.math.floatMantissaBits(f64) + 1;

/// Validates `span` for `method` (finite bounds and step, non-zero step) and returns its
/// value count as an f64, or raises a rescuable ValueError.
pub fn validatedCount(vm: *VM, span: Span, method: []const u8) !f64 {
    if (!std.math.isFinite(span.start) or !std.math.isFinite(span.end) or !std.math.isFinite(span.step)) {
        _ = vm.throwDynamicError("ValueError: {s} requires finite bounds and step, got {d}..{d} step {d}", .{ method, span.start, span.end, span.step });
        return error.RuntimeError;
    }
    if (span.step == 0) {
        _ = vm.throwDynamicError("ValueError: {s} step can't be 0", .{method});
        return error.RuntimeError;
    }
    return span.count();
}

/// Count for a block-driven iteration: no resource cap, only MAX_EXACT_COUNT.
fn iterationCount(vm: *VM, span: Span, method: []const u8) !u64 {
    const n = try validatedCount(vm, span, method);
    if (n > @as(f64, @floatFromInt(MAX_EXACT_COUNT))) {
        _ = vm.throwDynamicError("ValueError: {s} would iterate {d} times, more than the {d} distinct values a float can count", .{ method, n, MAX_EXACT_COUNT });
        return error.RuntimeError;
    }
    // Finite, non-negative and at most 2^53, so the cast is defined.
    return @intFromFloat(n);
}

/// Count for building an array: capped by MAX_RANGE_MATERIALIZE, checked before allocating.
fn materializeCount(vm: *VM, span: Span, method: []const u8) !usize {
    const n = try validatedCount(vm, span, method);
    if (n > @as(f64, @floatFromInt(limits.MAX_RANGE_MATERIALIZE))) {
        _ = vm.throwDynamicError("ValueError: {s} would build an array of {d} values (limit {d}); iterate with each instead", .{ method, n, limits.MAX_RANGE_MATERIALIZE });
        return error.RuntimeError;
    }
    // Finite, non-negative and bounded by the check above (which fits usize on wasm32).
    return @intFromFloat(n);
}

/// Integral receiver/argument check for Number#times/upto/downto.
pub fn requireInteger(vm: *VM, n: f64, method: []const u8) !void {
    if (!std.math.isFinite(n) or @trunc(n) != n) {
        _ = vm.throwDynamicError("ValueError: {s} requires an integer, got {d}", .{ method, n });
        return error.RuntimeError;
    }
}

pub fn requireBlock(vm: *VM, block: ?*value.ObjClosure, method: []const u8) !*value.ObjClosure {
    return block orelse {
        _ = vm.throwDynamicError("ValueError: {s} requires a block", .{method});
        return error.RuntimeError;
    };
}

/// Yields every value of `span` to `block`. Returns `receiver`, or the value of a
/// `break` inside the block. Exceptions and `return` propagate unchanged.
pub fn each(vm: *VM, span: Span, receiver: value.Value, block: *value.ObjClosure, method: []const u8) !value.Value {
    const n = try iterationCount(vm, span, method);
    // u64, not usize: on wasm32 usize would truncate counts above 4G.
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        _ = vm.callClosureSync(block, &.{value.Value.initNumber(span.at(i))}) catch |err| {
            if (err == error.BlockBreak) return vm.stack[vm.stack_top - 1];
            return err;
        };
    }
    return receiver;
}

/// Collects `span` into a new array, passing each value through `block` when given.
pub fn collect(vm: *VM, span: Span, block: ?*value.ObjClosure, method: []const u8) !value.Value {
    const n = try materializeCount(vm, span, method);
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const arr = try vm.gc.allocateArray(vm);
    // Rooted on the stack: the block may allocate (and collect) on every call.
    vm.push(value.Value.initObj(&arr.obj));
    try arr.items.ensureTotalCapacity(vm.gc.trackingAllocator(), n);
    for (0..n) |i| {
        const item = value.Value.initNumber(span.at(i));
        const out = if (block) |b| vm.callClosureSync(b, &.{item}) catch |err| {
            if (err == error.BlockBreak) return vm.stack[vm.stack_top - 1];
            return err;
        } else item;
        arr.items.appendAssumeCapacity(out);
    }
    return value.Value.initObj(&arr.obj);
}
