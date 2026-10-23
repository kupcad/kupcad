//! The Random class: `Random.new(seed)` (`randomNew`, which registry.zig binds) and its
//! methods (`methods`): `rand`, `rand(n)`, `rand(a..b)`, `shuffle(array)`, `sample(array)`
//! and `seed`. A SplitMix64 generator written out here, not std's, so a seed gives the
//! same numbers every run, on every platform and after an upgrade: a model made with one is
//! the same model. There is no unseeded Random.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

/// SplitMix64's increment and mixing multipliers (Steele, Lea and Flood, 2014).
const GOLDEN_GAMMA: u64 = 0x9e3779b97f4a7c15;
const MIX_1: u64 = 0xbf58476d1ce4e5b9;
const MIX_2: u64 = 0x94d049bb133111eb;
/// Past 2^53 a Number no longer holds every whole number: the bound of a seed and of a
/// whole-number draw.
const MAX_EXACT_INT: f64 = 9007199254740992;
/// The bits of a draw a float in [0, 1) takes: a double's mantissa and its hidden bit.
const FLOAT_BITS = 53;

fn next(r: *value.ObjRandom) u64 {
    r.state +%= GOLDEN_GAMMA;
    var z = r.state;
    z = (z ^ (z >> 30)) *% MIX_1;
    z = (z ^ (z >> 27)) *% MIX_2;
    return z ^ (z >> 31);
}

/// A float in [0, 1), every one of the 2^53 equally likely.
fn unit(r: *value.ObjRandom) f64 {
    return @as(f64, @floatFromInt(next(r) >> (64 - FLOAT_BITS))) * 0x1p-53;
}

/// A whole number in [0, n), n at least 1, each equally likely: draws below 2^64 mod n are
/// thrown away, so the remainder has no bias.
fn below(r: *value.ObjRandom, n: u64) u64 {
    const threshold = (0 -% n) % n;
    while (true) {
        const x = next(r);
        if (x >= threshold) return x % n;
    }
}

fn isWhole(n: f64) bool {
    return @trunc(n) == n and @abs(n) <= MAX_EXACT_INT;
}

/// Random.new(seed) -> a generator that gives the same numbers for the same seed, a whole
/// number (there is none without one: a model must be the same each run).
pub fn randomNew(vm: *VM, class: value.Value, seed_opt: ?f64) !value.Value {
    _ = class;
    const seed = seed_opt orelse return vm.fail(.ArgumentError, "Random.new takes a seed, a whole number: the same seed gives the same numbers every run", .{});
    if (!isWhole(seed)) return vm.fail(.ArgumentError, "Random.new: the seed is a whole number up to 2^53, got {f}", .{value.fmtNumber(seed)});
    const state: u64 = @bitCast(@as(i64, @intFromFloat(seed)));
    return value.Value.initObj(&(try vm.gc.allocateRandom(vm, seed, state)).obj);
}

/// Random#rand -> a float in [0, 1); rand(n) a whole number in [0, n) for a whole n, else
/// a float in [0, n); rand(a..b) a whole number in the Range for whole bounds (`a...b`
/// leaves b out), else a float from a up to b.
pub fn randomRand(vm: *VM, r: *value.ObjRandom, limit: ?value.Value) !value.Value {
    const bound = limit orelse return value.Value.initNumber(unit(r));
    if (bound.isNumber()) {
        const n = bound.asNumber();
        if (!(n > 0) or !std.math.isFinite(n)) return vm.fail(.ArgumentError, "rand: the limit is a number greater than 0, got {f}", .{value.fmtNumber(n)});
        if (isWhole(n)) return value.Value.initNumber(@floatFromInt(below(r, @intFromFloat(n))));
        return value.Value.initNumber(unit(r) * n);
    }
    if (bound.isRange()) {
        const range = bound.asRange();
        if (range.step != 1) return vm.fail(.ArgumentError, "rand: the Range has a step of {f}; give it one without", .{value.fmtNumber(range.step)});
        const lo = range.start;
        const hi = range.end;
        if (!std.math.isFinite(lo) or !std.math.isFinite(hi)) return vm.fail(.ArgumentError, "rand: the Range's ends are finite numbers", .{});
        if (isWhole(lo) and isWhole(hi)) {
            const top = if (range.is_exclusive) hi - 1 else hi;
            if (top < lo) return vm.fail(.ArgumentError, "rand: the Range {f}{s}{f} is empty", .{ value.fmtNumber(lo), if (range.is_exclusive) "..." else "..", value.fmtNumber(hi) });
            const count: u64 = @intFromFloat(top - lo + 1);
            return value.Value.initNumber(lo + @as(f64, @floatFromInt(below(r, count))));
        }
        if (!(hi > lo)) return vm.fail(.ArgumentError, "rand: the Range {f}{s}{f} is empty", .{ value.fmtNumber(lo), if (range.is_exclusive) "..." else "..", value.fmtNumber(hi) });
        return value.Value.initNumber(lo + unit(r) * (hi - lo));
    }
    return vm.fail(.TypeError, "rand takes nothing, a Number or a Range, got {s}", .{vm.typeName(bound)});
}

/// Random#shuffle(array) -> a copy of the Array in an order drawn from the generator
/// (Fisher-Yates), the Array itself as it was.
pub fn randomShuffle(vm: *VM, r: *value.ObjRandom, arr: *value.ObjArray) !value.Value {
    const shuffled = try vm.gc.allocateArrayOf(vm, arr.items.items);
    const items = shuffled.items.items;
    var i = items.len;
    while (i > 1) : (i -= 1) {
        const j = below(r, i);
        std.mem.swap(value.Value, &items[i - 1], &items[j]);
    }
    return value.Value.initObj(&shuffled.obj);
}

/// Random#sample(array) -> one of its items, each equally likely; nil for an empty Array.
pub fn randomSample(vm: *VM, r: *value.ObjRandom, arr: *value.ObjArray) !value.Value {
    _ = vm;
    const items = arr.items.items;
    if (items.len == 0) return value.Value.initNil();
    return items[below(r, items.len)];
}

/// Random#seed -> the seed it was made with.
pub fn randomSeed(vm: *VM, r: *value.ObjRandom) !value.Value {
    _ = vm;
    return value.Value.initNumber(r.seed);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "rand", .func = common.wrapMethod(randomRand) },
    .{ .name = "shuffle", .func = common.wrapMethod(randomShuffle) },
    .{ .name = "sample", .func = common.wrapMethod(randomSample) },
    .{ .name = "seed", .func = common.wrapMethod(randomSeed) },
};
