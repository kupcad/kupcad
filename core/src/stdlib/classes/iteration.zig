//! Shared numeric iteration used by Range and Number (times/upto/downto), so both
//! agree on how many values a span yields and what each value is.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const HandleScope = @import("../../vm/scope.zig").HandleScope;
const limits = @import("../../core/limits.zig");
const sequence = @import("../../vm/sequence.zig");

pub const Span = sequence.Span;
pub const validatedCount = sequence.validatedCount;
const iterationCount = sequence.iterationCount;

/// Count for building an array: capped by MAX_RANGE_MATERIALIZE, checked before allocating.
fn materializeCount(vm: *VM, span: Span, method: []const u8) !usize {
    const n = try validatedCount(vm, span, method);
    if (n > @as(f64, @floatFromInt(limits.MAX_RANGE_MATERIALIZE))) {
        return vm.fail(.ValueError, "{s} would build an array of {d} values (limit {d}); iterate with each instead", .{ method, n, limits.MAX_RANGE_MATERIALIZE });
    }
    // Finite, non-negative and bounded by the check above (which fits usize on wasm32).
    return @intFromFloat(n);
}

/// Integral receiver/argument check for Number#times/upto/downto.
pub fn requireInteger(vm: *VM, n: f64, method: []const u8) !void {
    if (!std.math.isFinite(n) or @trunc(n) != n) {
        return vm.fail(.ValueError, "{s} requires an integer, got {f}", .{ method, value.fmtNumber(n) });
    }
}

/// What a block gave an iterating method: its value, or the value of a `break` in it.
pub const BlockResult = union(enum) { value: value.Value, broke: value.Value };

/// Calls `block` with `args` the way an iterating method does. A `break` in the block ends
/// the iteration with `.broke`, its value taken off the stack: natives that read it there
/// and returned left it pushed, so everything after the call was off by one slot
/// (`show(1, xs.each { break 2 })` then called a Number). Other errors propagate.
pub fn callBlock(vm: *VM, block: *value.ObjClosure, args: []const value.Value) !BlockResult {
    const result = vm.callClosureSync(block, args) catch |err| switch (err) {
        error.BlockBreak => return .{ .broke = vm.takeBlockBreak() orelse return error.BlockBreak },
        else => return err,
    };
    return .{ .value = result };
}

/// Yields every value of `span` to `block`. Returns `receiver`, or the value of a
/// `break` inside the block. Exceptions and `return` propagate unchanged.
pub fn each(vm: *VM, span: Span, receiver: value.Value, block: *value.ObjClosure, method: []const u8) !value.Value {
    const n = try iterationCount(vm, span, method);
    // u64, not usize: on wasm32 usize would truncate counts above 4G.
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        switch (try callBlock(vm, block, &.{value.Value.initNumber(span.at(i))})) {
            .broke => |v| return v,
            .value => {},
        }
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
        const out = if (block) |b| switch (try callBlock(vm, b, &.{item})) {
            .broke => |v| return v,
            .value => |v| v,
        } else item;
        arr.items.appendAssumeCapacity(out);
    }
    return value.Value.initObj(&arr.obj);
}
