//! The Range class's methods (`each`, `map`, `to_a`, `step`, `include?` and the rest), as a
//! `methods` table of `common.MethodDef`; iteration itself is in iteration.zig.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");
const iteration = @import("iteration.zig");
const util = @import("../methods/util.zig");

fn spanOf(r: *value.ObjRange) iteration.Span {
    return .{ .start = r.start, .end = r.end, .step = r.step, .is_exclusive = r.is_exclusive };
}

/// Range#each { |i| ... }
pub fn rangeEach(vm: *VM, r: *value.ObjRange, block: ?*value.ObjClosure) !value.Value {
    const b = try util.requireBlock(vm, block, "Range#each");
    return iteration.each(vm, spanOf(r), value.Value.initObj(&r.obj), b, "Range#each");
}

/// Range#map { |i| ... }
pub fn rangeMap(vm: *VM, r: *value.ObjRange, block: ?*value.ObjClosure) !value.Value {
    const b = try util.requireBlock(vm, block, "Range#map");
    return iteration.collect(vm, spanOf(r), b, "Range#map");
}

/// Range#to_a
pub fn rangeToA(vm: *VM, r: *value.ObjRange) !value.Value {
    return iteration.collect(vm, spanOf(r), null, "Range#to_a");
}

/// Range#size / #length / #count
pub fn rangeSize(vm: *VM, r: *value.ObjRange) !value.Value {
    // Pure arithmetic: no iteration, so no cap.
    return value.Value.initNumber(try iteration.validatedCount(vm, spanOf(r), "Range#size"));
}

/// Range#include?(x) / #cover?(x): same rule as `case`/`when` matching in the VM; x
/// does not have to lie on a step.
pub fn rangeInclude(vm: *VM, r: *value.ObjRange, x: value.Value) !value.Value {
    _ = vm;
    if (!x.isNumber()) return value.Value.initBool(false);
    const n = x.asNumber();
    const hit = if (r.is_exclusive) n >= r.start and n < r.end else n >= r.start and n <= r.end;
    return value.Value.initBool(hit);
}

/// Range#first
pub fn rangeFirst(vm: *VM, r: *value.ObjRange) !value.Value {
    _ = vm;
    return value.Value.initNumber(r.start);
}

/// Range#last: the raw end, as in Ruby, even for an exclusive range.
pub fn rangeLast(vm: *VM, r: *value.ObjRange) !value.Value {
    _ = vm;
    return value.Value.initNumber(r.end);
}

/// Range#step(n): a new range with the same bounds and step `n`.
pub fn rangeStep(vm: *VM, r: *value.ObjRange, step: f64) !value.Value {
    if (!std.math.isFinite(step) or step == 0) {
        return vm.fail(.ValueError, "Range#step requires a finite, non-zero step, got {f}", .{value.fmtNumber(step)});
    }
    const out = try vm.gc.allocateRange(vm, r.start, r.end, step, r.is_exclusive);
    return value.Value.initObj(&out.obj);
}

/// Range#exclusive?
pub fn rangeExclusive(vm: *VM, r: *value.ObjRange) !value.Value {
    _ = vm;
    return value.Value.initBool(r.is_exclusive);
}

/// Range#to_s: same text as `puts` prints.
pub fn rangeToS(vm: *VM, r: *value.ObjRange) !value.Value {
    var buf: [128]u8 = undefined;
    const str = try std.mem.print(&buf, "{f}{s}{f}", .{ value.fmtNumber(r.start), if (r.is_exclusive) "..." else "..", value.fmtNumber(r.end) });
    return try vm.allocateString(str);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "each", .func = common.wrapMethod(rangeEach) },
    .{ .name = "map", .func = common.wrapMethod(rangeMap) },
    .{ .name = "to_a", .func = common.wrapMethod(rangeToA) },
    .{ .name = "size", .func = common.wrapMethod(rangeSize) },
    .{ .name = "length", .func = common.wrapMethod(rangeSize) },
    .{ .name = "count", .func = common.wrapMethod(rangeSize) },
    .{ .name = "include?", .func = common.wrapMethod(rangeInclude) },
    .{ .name = "cover?", .func = common.wrapMethod(rangeInclude) },
    .{ .name = "first", .func = common.wrapMethod(rangeFirst) },
    .{ .name = "last", .func = common.wrapMethod(rangeLast) },
    .{ .name = "step", .func = common.wrapMethod(rangeStep) },
    .{ .name = "exclusive?", .func = common.wrapMethod(rangeExclusive) },
    .{ .name = "to_s", .func = common.wrapMethod(rangeToS) },
};
