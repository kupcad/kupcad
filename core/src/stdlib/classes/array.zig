//! The natives of Array (`Array.new`, `push`, `map`, `reduce`, `slice`, `sort`, `sort_by`,
//! `group_by`, `each_cons`, ...) and their dispatch table, `methods`.

const std = @import("std");
const value = @import("../../core/value.zig");
const limits = @import("../../core/limits.zig");
const VM = @import("../../vm/vm.zig").VM;
const HandleScope = @import("../../vm/scope.zig").HandleScope;
const common = @import("common.zig");
const callBlock = @import("iteration.zig").callBlock;
const arguments = @import("../arguments.zig");

/// Array#length / Array#size
pub fn arrayLength(vm: *VM, arr: *value.ObjArray) !value.Value {
    _ = vm;
    return value.Value.initNumber(@floatFromInt(arr.items.items.len));
}

/// Array.new(size = 0, fill = nil) -> an Array of `size` copies of `fill`
pub fn arrayNew(vm: *VM, class: value.Value, size_num: ?f64, fill: ?value.Value) !value.Value {
    _ = class;
    const size = size_num orelse 0;
    if (!(size >= 0) or @trunc(size) != size or size > @as(f64, @floatFromInt(limits.MAX_RANGE_MATERIALIZE))) {
        return vm.fail(.ValueError, "Array.new size must be a whole number from 0 to {d}, got {f}", .{ limits.MAX_RANGE_MATERIALIZE, value.fmtNumber(size) });
    }
    const arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&arr.obj));
    defer _ = vm.pop();
    try arr.items.appendNTimes(vm.gc.trackingAllocator(), fill orelse value.Value.initNil(), @intFromFloat(size));
    return value.Value.initObj(&arr.obj);
}

/// Array#push(*values): appends each value, like Ruby (so `arr.push(*more)` works).
pub fn arrayPush(vm: *VM, arr: *value.ObjArray, vals: []const value.Value) !value.Value {
    try arr.items.appendSlice(vm.gc.trackingAllocator(), vals);
    return value.Value.initObj(&arr.obj);
}

/// Array#pop
pub fn arrayPop(vm: *VM, arr: *value.ObjArray) !value.Value {
    _ = vm;
    if (arr.items.items.len > 0) {
        const val = arr.items.items[arr.items.items.len - 1];
        arr.items.shrinkRetainingCapacity(arr.items.items.len - 1);
        return val;
    }
    return value.Value.initNil();
}

/// Array#shift
pub fn arrayShift(vm: *VM, arr: *value.ObjArray) !value.Value {
    _ = vm;
    if (arr.items.items.len > 0) {
        return arr.items.orderedRemove(0);
    }
    return value.Value.initNil();
}

/// Array#unshift(val)
pub fn arrayUnshift(vm: *VM, arr: *value.ObjArray, val: value.Value) !value.Value {
    try arr.items.insert(vm.gc.trackingAllocator(), 0, val);
    return value.Value.initObj(&arr.obj);
}

/// Array#slice(start, len), Ruby `arr[start, len]` semantics: fractional
/// arguments truncate, a negative start counts from the end, a start outside
/// 0..size or a negative length is nil, and the length is clamped to the
/// elements available (so start == size yields []).
pub fn arraySlice(vm: *VM, arr: *value.ObjArray, start_num: f64, len_num: f64) !value.Value {
    if (std.math.isNan(start_num) or std.math.isNan(len_num)) {
        return vm.fail(.ValueError, "Array#slice arguments must be numbers, got NaN.", .{});
    }
    // Resolve everything in f64 first: @intFromFloat on a negative or huge value
    // panics in Debug and is UB in ReleaseFast, and an unclamped length used to
    // drive ensureTotalCapacity (a 1e12 length tried to allocate 8 TB).
    const size: f64 = @floatFromInt(arr.items.items.len);
    var start = @trunc(start_num);
    if (start < 0) start += size;
    const len = @trunc(len_num);
    if (start < 0 or start > size or len < 0) return value.Value.initNil();

    const start_idx: usize = @intFromFloat(start);
    const count: usize = @intFromFloat(@min(len, size - start));

    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_arr = try scope.array();
    try new_arr.items.appendSlice(vm.gc.trackingAllocator(), arr.items.items[start_idx..][0..count]);
    return value.Value.initObj(&new_arr.obj);
}

/// Array#join(delim)
pub fn arrayJoin(vm: *VM, arr: *value.ObjArray, delim_obj: *value.ObjString) !value.Value {
    const delim = delim_obj.chars;

    var out: std.Io.Writer.Allocating = .init(vm.gc.trackingAllocator());
    errdefer out.deinit();

    for (arr.items.items, 0..) |item, idx| {
        item.stringify(false, &out.writer) catch return error.RuntimeError;
        if (idx < arr.items.items.len - 1) {
            out.writer.writeAll(delim) catch return error.RuntimeError;
        }
    }

    return vm.allocateStringTakeOwnership(try out.toOwnedSlice());
}

// The iterators index the receiver afresh on every step and stop at its current length:
// a block that pushes to the array it iterates (as Ruby allows) reallocates its items,
// and a slice taken once read the freed buffer.

/// Array#each { |x| ... }
pub fn arrayEach(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        switch (try callBlock(vm, closure, &.{arr.items.items[i]})) {
            .broke => |v| return v,
            .value => {},
        }
    }
    return value.Value.initObj(&arr.obj);
}

/// Array#map { |x| ... }
pub fn arrayMap(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const new_arr = try scope.array();
    try new_arr.items.ensureTotalCapacity(vm.gc.trackingAllocator(), arr.items.items.len);
    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        const mapped_val = switch (try callBlock(vm, closure, &.{arr.items.items[i]})) {
            .broke => |v| return v,
            .value => |v| v,
        };
        try new_arr.items.append(vm.gc.trackingAllocator(), mapped_val);
    }
    return value.Value.initObj(&new_arr.obj);
}

/// Array#reduce(initial_val, block) / Array#reduce(block)
pub fn arrayReduce(vm: *VM, arr: *value.ObjArray, initial_val: ?value.Value, block: ?*value.ObjClosure) !value.Value {
    const body = try arguments.requireBlock(vm, block, "reduce");

    // SAFETY: acc_val is conditionally initialized below based on `initial_val` presence or array length.
    var acc_val: value.Value = undefined;
    var start_idx: usize = 0;

    if (initial_val) |val| {
        acc_val = val;
    } else {
        if (arr.items.items.len == 0) return value.Value.initNil();
        acc_val = arr.items.items[0];
        start_idx = 1;
    }

    var i = start_idx;
    while (i < arr.items.items.len) : (i += 1) {
        acc_val = switch (try callBlock(vm, body, &.{ acc_val, arr.items.items[i] })) {
            .broke => |v| return v,
            .value => |v| v,
        };
    }
    return acc_val;
}

/// Array#filter { |x| ... }
pub fn arrayFilter(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    return keepWhere(vm, arr, closure, true);
}

/// Array#reject: the items the block is false or nil for (Array#filter's complement).
pub fn arrayReject(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    return keepWhere(vm, arr, closure, false);
}

/// A new array of the items whose block result is truthy (`truthy`) or falsey (`!truthy`).
fn keepWhere(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure, truthy: bool) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_arr = try scope.array();

    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        const item = arr.items.items[i];
        const res = switch (try callBlock(vm, closure, &.{item})) {
            .broke => |v| return v,
            .value => |v| v,
        };
        if (res.isFalsey() != truthy) {
            try new_arr.items.append(vm.gc.trackingAllocator(), item);
        }
    }
    return value.Value.initObj(&new_arr.obj);
}

/// Array#compact: a new array without the nils (false stays: it is a value).
pub fn arrayCompact(vm: *VM, arr: *value.ObjArray) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_arr = try scope.array();

    for (arr.items.items) |item| {
        if (!item.isNil()) try new_arr.items.append(vm.gc.trackingAllocator(), item);
    }
    return value.Value.initObj(&new_arr.obj);
}

/// Array#first
pub fn arrayFirst(vm: *VM, arr: *value.ObjArray) !value.Value {
    _ = vm;
    if (arr.items.items.len > 0) {
        return arr.items.items[0];
    }
    return value.Value.initNil();
}

/// Array#last
pub fn arrayLast(vm: *VM, arr: *value.ObjArray) !value.Value {
    _ = vm;
    const len = arr.items.items.len;
    if (len > 0) {
        return arr.items.items[len - 1];
    }
    return value.Value.initNil();
}

/// Array#contains?(target)
pub fn arrayContains(vm: *VM, arr: *value.ObjArray, target: value.Value) !value.Value {
    for (arr.items.items) |item| {
        if (vm.valuesEqual(item, target)) return value.Value.initBool(true);
    }
    return value.Value.initBool(false);
}

/// Array#flatten / flatten(depth): the items, each Array among them replaced by its items,
/// as deep as they nest (as Ruby's), or `depth` levels deep. Walked with a stack of its own,
/// as Arrays may nest deeper than the native stack goes; one that holds itself is refused,
/// as it would flatten forever.
pub fn arrayFlatten(vm: *VM, arr: *value.ObjArray, depth: ?f64) !value.Value {
    const levels: usize = if (depth) |d| blk: {
        if (!(d >= 0) or d != @floor(d)) return vm.fail(.ArgumentError, "flatten takes how many levels to take out, a whole number from 0, got {f}", .{value.fmtNumber(d)});
        break :blk std.math.lossyCast(usize, d);
    } else std.math.maxInt(usize);

    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const flat = try scope.array();
    // The Arrays being taken apart, outermost first, and where each is
    const Open = struct { arr: *value.ObjArray, at: usize };
    var stack: std.ArrayList(Open) = .empty;
    defer stack.deinit(vm.allocator);
    var open: std.AutoHashMapUnmanaged(*value.ObjArray, void) = .empty;
    defer open.deinit(vm.allocator);
    try stack.append(vm.allocator, .{ .arr = arr, .at = 0 });
    try open.put(vm.allocator, arr, {});
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.at == top.arr.items.items.len) {
            _ = open.remove(top.arr);
            _ = stack.pop();
            continue;
        }
        const item = top.arr.items.items[top.at];
        top.at += 1;
        if (!item.isArray() or stack.items.len > levels) {
            try flat.items.append(vm.gc.trackingAllocator(), item);
            continue;
        }
        const inner = item.asArray();
        if (open.contains(inner)) return vm.fail(.ArgumentError, "flatten: the Array holds itself, so it would flatten forever", .{});
        try open.put(vm.allocator, inner, {});
        try stack.append(vm.allocator, .{ .arr = inner, .at = 0 });
    }
    return value.Value.initObj(&flat.obj);
}

/// Array#max
pub fn arrayMax(vm: *VM, arr: *value.ObjArray) !value.Value {
    return arrayExtreme(vm, arr, "max", .gt);
}

/// Array#min
pub fn arrayMin(vm: *VM, arr: *value.ObjArray) !value.Value {
    return arrayExtreme(vm, arr, "min", .lt);
}

/// The greatest (`wanted` = .gt) or least element of an Array of Numbers, or of Strings
/// (ordered bytewise); nil for an empty one. Anything else is a TypeError, and a NaN a
/// MathError: elements that weren't Numbers used to be skipped, so `["a"].max` was
/// -Infinity and `[1, NaN].max` whatever NaN compared as.
fn arrayExtreme(vm: *VM, arr: *value.ObjArray, comptime name: []const u8, comptime wanted: std.math.Order) !value.Value {
    const items = arr.items.items;
    if (items.len == 0) return value.Value.initNil();
    try requireOrdered(vm, items, name, .items, "");
    var best = items[0];
    for (items) |item| if (orderOf(item, best) == wanted) {
        best = item;
    };
    return best;
}

/// What a native that orders values compares, as its errors say it: the Array's items, or
/// the keys its block gave them.
const Compared = enum { items, keys };

/// Checks `values` are all Numbers or all Strings, as `sort`, `min`, `max` and their `_by`s
/// order them (`orderOf`), and none NaN, which orders with nothing; `hint` follows a TypeError
/// of the items. Each value, not only the first: after a String, a nil passed and was read
/// as a String (found by the runtime fuzz test).
fn requireOrdered(vm: *VM, values: []const value.Value, comptime method: []const u8, comptime compared: Compared, comptime hint: []const u8) !void {
    for (values, 0..) |v, i| {
        if (!v.isNumber() and !v.isString()) return switch (compared) {
            .items => vm.fail(.TypeError, method ++ " needs Numbers or Strings, got {s} at index {d}" ++ hint, .{ vm.typeName(v), i }),
            .keys => vm.fail(.TypeError, method ++ ": the block gives Numbers or Strings to compare, got {s} for the item at index {d}", .{ vm.typeName(v), i }),
        };
        if (v.isNumber() != values[0].isNumber()) return switch (compared) {
            .items => vm.fail(.TypeError, method ++ " can't compare {s} with {s}" ++ hint, .{ vm.typeName(values[0]), vm.typeName(v) }),
            .keys => vm.fail(.TypeError, method ++ ": the block gave {s} and {s}, which can't be compared", .{ vm.typeName(values[0]), vm.typeName(v) }),
        };
        if (v.isNumber() and std.math.isNan(v.asNumber())) return switch (compared) {
            .items => vm.fail(.MathError, method ++ ": the Array holds NaN at index {d}", .{i}),
            .keys => vm.fail(.MathError, method ++ ": the block gave NaN for the item at index {d}", .{i}),
        };
    }
}

/// How two values `requireOrdered` passed order: Numbers by value, Strings bytewise.
fn orderOf(a: value.Value, b: value.Value) std.math.Order {
    if (a.isNumber()) return std.math.order(a.asNumber(), b.asNumber());
    return std.mem.order(u8, a.asString().chars, b.asString().chars);
}

/// Array#sum / sum { |item| ... }: the Numbers added up, the items or what the block gives
/// for each (0 for an empty Array). Anything else is a TypeError (it used to be skipped), and
/// a total beyond the Number range a RangeError.
pub fn arraySum(vm: *VM, arr: *value.ObjArray, block: ?*value.ObjClosure) !value.Value {
    var sum: f64 = 0.0;
    var all_finite = true;
    // By index: the block may change the Array
    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        const item = arr.items.items[i];
        const term = if (block) |closure| switch (try callBlock(vm, closure, &.{item})) {
            .broke => |v| return v,
            .value => |v| v,
        } else item;
        if (!term.isNumber()) {
            if (block != null) return vm.fail(.TypeError, "sum's block must give Numbers, gave {s} for index {d}", .{ vm.typeName(term), i });
            return vm.fail(.TypeError, "sum needs Numbers, got {s} at index {d}", .{ vm.typeName(term), i });
        }
        if (!std.math.isFinite(term.asNumber())) all_finite = false;
        sum += term.asNumber();
    }
    if (all_finite and !std.math.isFinite(sum)) {
        return vm.fail(.RangeError, "sum overflowed the Number range", .{});
    }
    return value.Value.initNumber(sum);
}

/// How Array#sort orders two values: natively for Numbers or Strings (`orderOf`, the items
/// checked first), else by the block, which must give a Number (its sign). The block can raise or `break`, which a sort's
/// comparator can't report, so the first such outcome is kept here and the sort finishes
/// in whatever order; the native then raises (or returns the break value).
const SortOrder = struct {
    vm: *VM,
    block: ?*value.ObjClosure,
    failed: ?anyerror = null,
    broke: ?value.Value = null,

    fn lessThan(self: *SortOrder, a: value.Value, b: value.Value) bool {
        if (self.failed != null or self.broke != null) return false;
        return self.compare(a, b) catch |err| {
            self.failed = err;
            return false;
        };
    }

    fn compare(self: *SortOrder, a: value.Value, b: value.Value) !bool {
        if (self.block) |block| {
            const res = switch (try callBlock(self.vm, block, &.{ a, b })) {
                .broke => |v| {
                    self.broke = v;
                    return false;
                },
                .value => |v| v,
            };
            if (!res.isNumber()) {
                return self.vm.fail(.TypeError, "sort block must return a Number (-1, 0, 1).", .{});
            }
            return res.asNumber() < 0;
        }
        return orderOf(a, b) == .lt;
    }
};

/// Array#sort
/// A sorted copy: Numbers or Strings natively, anything with a block. (A hand-written
/// quicksort kept its partitions in a 64-entry buffer and overran it on a few hundred
/// already-sorted numbers; std.sort.pdq is bounded whatever the input.)
pub fn arraySort(vm: *VM, arr: *value.ObjArray, block: ?*value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    if (block == null) try requireOrdered(vm, arr.items.items, "sort", .items, "; give it a block");
    const new_arr = try scope.array();
    try new_arr.items.appendSlice(vm.gc.trackingAllocator(), arr.items.items);

    var sorting = SortOrder{ .vm = vm, .block = block };
    std.sort.pdq(value.Value, new_arr.items.items, &sorting, SortOrder.lessThan);
    if (sorting.failed) |err| return err;
    if (sorting.broke) |v| return v;
    return value.Value.initObj(&new_arr.obj);
}

/// Array#to_h / to_h { |item| [key, value] }: a Map of the pairs, the items or what the
/// block makes of each. A pair is an Array of two: anything else is an ArgumentError, as in
/// Ruby (one item was a key of nil, and a third was dropped).
pub fn arrayToH(vm: *VM, arr: *value.ObjArray, block: ?*value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_map = try scope.map();

    try new_map.table.ensureTotalCapacity(vm.gc.trackingAllocator(), arr.items.items.len);

    // By index: the block may change the Array
    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        const item = arr.items.items[i];
        const pair = if (block) |closure| switch (try callBlock(vm, closure, &.{item})) {
            .broke => |v| return v,
            .value => |v| v,
        } else item;
        const got = if (block != null) "its block gave" else "got";
        if (!pair.isArray()) return vm.fail(.ArgumentError, "to_h needs [key, value] pairs; {s} {s} for index {d}", .{ got, vm.typeName(pair), i });
        const kv = pair.asArray().items.items;
        if (kv.len != 2) return vm.fail(.ArgumentError, "to_h needs [key, value] pairs; {s} an Array of {d} for index {d}", .{ got, kv.len, i });
        // A put allocates no object, so nothing collects the block's pair before it is in
        try vm.mapSet(new_map, kv[0], kv[1]);
    }

    return value.Value.initObj(&new_map.obj);
}

fn indexValue(i: usize) value.Value {
    return value.Value.initNumber(@floatFromInt(i));
}

/// Array#each_with_index { |x, i| ... }: each item with its index; the receiver. Without a
/// block, the pairs `[x, i]` as an Array (there is no Enumerator to give).
pub fn arrayEachWithIndex(vm: *VM, arr: *value.ObjArray, block: ?*value.ObjClosure) !value.Value {
    if (block) |closure| {
        var i: usize = 0;
        while (i < arr.items.items.len) : (i += 1) {
            switch (try callBlock(vm, closure, &.{ arr.items.items[i], indexValue(i) })) {
                .broke => |v| return v,
                .value => {},
            }
        }
        return value.Value.initObj(&arr.obj);
    }
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const pairs = try scope.array();
    try pairs.items.ensureTotalCapacity(vm.gc.trackingAllocator(), arr.items.items.len);
    for (arr.items.items, 0..) |item, i| {
        const pair = try vm.gc.allocateArrayOf(vm, &.{ item, indexValue(i) });
        pairs.items.appendAssumeCapacity(value.Value.initObj(&pair.obj));
    }
    return value.Value.initObj(&pairs.obj);
}

/// Array#each_cons(n) { |window| ... }: every run of `n` consecutive items, as an Array.
pub fn arrayEachCons(vm: *VM, arr: *value.ObjArray, n: f64, block: ?*value.ObjClosure) !value.Value {
    return windows(vm, arr, n, false, block, "each_cons");
}

/// Array#each_slice(n) { |slice| ... }: the items `n` at a time, the last slice the rest.
pub fn arrayEachSlice(vm: *VM, arr: *value.ObjArray, n: f64, block: ?*value.ObjClosure) !value.Value {
    return windows(vm, arr, n, true, block, "each_slice");
}

/// Windows of `n_num` items, each a new Array: every full run of consecutive items, or
/// (`slices`) the items `n` at a time with the last slice the rest. Each is given to
/// `block` (the result is the receiver), or without one they are collected into an Array.
/// The window is the block's one argument: write `|(a, b)|` to take its items apart.
fn windows(vm: *VM, arr: *value.ObjArray, n_num: f64, comptime slices: bool, block: ?*value.ObjClosure, comptime method: []const u8) !value.Value {
    if (!(n_num >= 1) or @trunc(n_num) != n_num) {
        return vm.fail(.ArgumentError, method ++ ": the size is a whole number of 1 or more, got {f}", .{value.fmtNumber(n_num)});
    }
    // Past the length, a window is the whole Array (a slice) or none (consecutive items)
    const n: usize = if (n_num > @as(f64, @floatFromInt(arr.items.items.len))) arr.items.items.len + 1 else @intFromFloat(n_num);
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    // Each window is rooted here while its block runs; without a block, they all stay
    const collected = try scope.array();
    var start: usize = 0;
    while (start < arr.items.items.len) : (start += if (slices) n else 1) {
        const len = arr.items.items.len;
        if (!slices and start + n > len) break;
        try collected.items.ensureUnusedCapacity(vm.gc.trackingAllocator(), 1);
        const window = try vm.gc.allocateArrayOf(vm, arr.items.items[start..@min(start + n, len)]);
        collected.items.appendAssumeCapacity(value.Value.initObj(&window.obj));
        const closure = block orelse continue;
        switch (try callBlock(vm, closure, &.{value.Value.initObj(&window.obj)})) {
            .broke => |v| return v,
            .value => {},
        }
        _ = collected.items.pop();
    }
    return if (block != null) value.Value.initObj(&arr.obj) else value.Value.initObj(&collected.obj);
}

/// Array#zip(*others): an Array of `[x, y, ...]`, the receiver's items with the item at the
/// same index of each of `others` (nil past one's end), as long as the receiver.
pub fn arrayZip(vm: *VM, arr: *value.ObjArray, others: []const value.Value) !value.Value {
    for (others, 1..) |other, n| {
        if (!other.isArray()) return vm.fail(.TypeError, "zip takes Arrays, got {s} as argument {d}", .{ vm.typeName(other), n });
    }
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const rows = try scope.array();
    try rows.items.ensureTotalCapacity(vm.gc.trackingAllocator(), arr.items.items.len);
    for (arr.items.items, 0..) |item, i| {
        const row = try vm.gc.allocateArray(vm);
        rows.items.appendAssumeCapacity(value.Value.initObj(&row.obj));
        try row.items.ensureTotalCapacity(vm.gc.trackingAllocator(), others.len + 1);
        row.items.appendAssumeCapacity(item);
        for (others) |other| {
            const items = other.asArray().items.items;
            row.items.appendAssumeCapacity(if (i < items.len) items[i] else value.Value.initNil());
        }
    }
    return value.Value.initObj(&rows.obj);
}

/// Array#uniq / uniq { |x| key }: the items without the ones equal (`==`) to an earlier
/// one, or whose block result is; in their order. Each is found among the earlier ones by
/// hashing it, as a Map finds its keys (value.ValueContext).
pub fn arrayUniq(vm: *VM, arr: *value.ObjArray, block: ?*value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const kept = try scope.array();
    // The keys of the kept items, rooted (a block's results): `seen` holds them, which a
    // collection mustn't free while it is read
    const keys = try scope.array();
    var seen: std.ArrayHashMapUnmanaged(value.Value, void, value.ValueContext, false) = .empty;
    defer seen.deinit(vm.allocator);
    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        const item = arr.items.items[i];
        const key = if (block) |closure| switch (try callBlock(vm, closure, &.{item})) {
            .broke => |v| return v,
            .value => |v| v,
        } else item;
        var held = HandleScope.init(vm);
        defer held.deinit();
        vm.push(key);
        if (seen.contains(key)) continue;
        try keys.items.append(vm.gc.trackingAllocator(), key);
        try seen.put(vm.allocator, key, {});
        try kept.items.append(vm.gc.trackingAllocator(), item);
    }
    return value.Value.initObj(&kept.obj);
}

/// Array#reverse: a copy, last item first.
pub fn arrayReverse(vm: *VM, arr: *value.ObjArray) !value.Value {
    const reversed = try vm.gc.allocateArrayOf(vm, arr.items.items);
    std.mem.reverse(value.Value, reversed.items.items);
    return value.Value.initObj(&reversed.obj);
}

/// Array#any? / any? { |x| ... }: whether an item is truthy, or makes the block truthy.
pub fn arrayAny(vm: *VM, arr: *value.ObjArray, block: ?*value.ObjClosure) !value.Value {
    return truthyCount(vm, arr, block, .any);
}

/// Array#all? / all? { |x| ... }: whether every item is truthy, or makes the block truthy
/// (true for an empty Array).
pub fn arrayAll(vm: *VM, arr: *value.ObjArray, block: ?*value.ObjClosure) !value.Value {
    return truthyCount(vm, arr, block, .all);
}

/// Array#none? / none? { |x| ... }: whether no item is truthy, or makes the block truthy.
pub fn arrayNone(vm: *VM, arr: *value.ObjArray, block: ?*value.ObjClosure) !value.Value {
    return truthyCount(vm, arr, block, .none);
}

/// any?, all? and none?, which stop at the first item that settles the answer.
fn truthyCount(vm: *VM, arr: *value.ObjArray, block: ?*value.ObjClosure, comptime want: enum { any, all, none }) !value.Value {
    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        const item = arr.items.items[i];
        const truthy = if (block) |closure| switch (try callBlock(vm, closure, &.{item})) {
            .broke => |v| return v,
            .value => |v| !v.isFalsey(),
        } else !item.isFalsey();
        switch (want) {
            .any => if (truthy) return value.Value.initBool(true),
            .all => if (!truthy) return value.Value.initBool(false),
            .none => if (truthy) return value.Value.initBool(false),
        }
    }
    return value.Value.initBool(want != .any);
}

/// Array#find { |x| ... }: the first item the block is truthy for, or nil.
pub fn arrayFind(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        const item = arr.items.items[i];
        switch (try callBlock(vm, closure, &.{item})) {
            .broke => |v| return v,
            .value => |v| if (!v.isFalsey()) return item,
        }
    }
    return value.Value.initNil();
}

/// Array#count / count(x) / count { |x| ... }: how many items there are, equal `x` (`==`),
/// or make the block truthy.
pub fn arrayCount(vm: *VM, arr: *value.ObjArray, target: ?value.Value, block: ?*value.ObjClosure) !value.Value {
    var count: usize = 0;
    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        const item = arr.items.items[i];
        const counted = if (target) |t| vm.valuesEqual(item, t) else if (block) |closure| switch (try callBlock(vm, closure, &.{item})) {
            .broke => |v| return v,
            .value => |v| !v.isFalsey(),
        } else true;
        if (counted) count += 1;
    }
    return indexValue(count);
}

/// Array#take(n): the first `n` items (all of them past the length).
pub fn arrayTake(vm: *VM, arr: *value.ObjArray, n: f64) !value.Value {
    const count = try countArg(vm, n, arr.items.items.len, "take");
    return value.Value.initObj(&(try vm.gc.allocateArrayOf(vm, arr.items.items[0..count])).obj);
}

/// Array#drop(n): the items after the first `n` (none past the length).
pub fn arrayDrop(vm: *VM, arr: *value.ObjArray, n: f64) !value.Value {
    const count = try countArg(vm, n, arr.items.items.len, "drop");
    return value.Value.initObj(&(try vm.gc.allocateArrayOf(vm, arr.items.items[count..])).obj);
}

/// A count of items `take` and `drop` are given: a whole number of 0 or more, at most `len`.
fn countArg(vm: *VM, n: f64, len: usize, comptime method: []const u8) !usize {
    if (!(n >= 0) or @trunc(n) != n) {
        return vm.fail(.ArgumentError, method ++ ": the count is a whole number of 0 or more, got {f}", .{value.fmtNumber(n)});
    }
    return if (n >= @as(f64, @floatFromInt(len))) len else @intFromFloat(n);
}

/// Array#flat_map { |x| ... }: the block's results in one Array, an Array result's items
/// in place of it (one level, as Ruby's).
pub fn arrayFlatMap(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const out = try scope.array();
    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        const result = switch (try callBlock(vm, closure, &.{arr.items.items[i]})) {
            .broke => |v| return v,
            .value => |v| v,
        };
        var held = HandleScope.init(vm);
        defer held.deinit();
        vm.push(result);
        if (result.isArray()) {
            try out.items.appendSlice(vm.gc.trackingAllocator(), result.asArray().items.items);
        } else {
            try out.items.append(vm.gc.trackingAllocator(), result);
        }
    }
    return value.Value.initObj(&out.obj);
}

/// The items of an Array and the block's result for each (its key), rooted in two Arrays;
/// `broke` is the value of a `break` in the block, which ends it there.
const Keyed = struct { items: *value.ObjArray, keys: *value.ObjArray, broke: ?value.Value = null };

/// `arr`'s items and their keys (Keyed) in Arrays rooted in `scope`: the items as each was
/// given, since the block may change the receiver.
fn keyed(vm: *VM, scope: HandleScope, arr: *value.ObjArray, closure: *value.ObjClosure) !Keyed {
    const items = try scope.array();
    const keys = try scope.array();
    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        const item = arr.items.items[i];
        try items.items.append(vm.gc.trackingAllocator(), item);
        try keys.items.ensureUnusedCapacity(vm.gc.trackingAllocator(), 1);
        switch (try callBlock(vm, closure, &.{item})) {
            .broke => |v| return .{ .items = items, .keys = keys, .broke = v },
            .value => |v| keys.items.appendAssumeCapacity(v),
        }
    }
    return .{ .items = items, .keys = keys };
}

/// Array#sort_by { |x| key }: a copy ordered by each item's key (Numbers or Strings), the
/// block called once per item; items with equal keys keep their order.
pub fn arraySortBy(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const by = try keyed(vm, scope, arr, closure);
    if (by.broke) |v| return v;
    const keys = by.keys.items.items;
    try requireOrdered(vm, keys, "sort_by", .keys, "");
    const order = try vm.allocator.alloc(usize, keys.len);
    defer vm.allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, keys, struct {
        fn lessThan(ks: []const value.Value, a: usize, b: usize) bool {
            return orderOf(ks[a], ks[b]) == .lt;
        }
    }.lessThan);
    const sorted = try vm.gc.allocateArrayOf(vm, by.items.items.items);
    for (sorted.items.items, order) |*slot, from| slot.* = by.items.items.items[from];
    return value.Value.initObj(&sorted.obj);
}

/// Array#min_by { |x| key }: the item with the least key (the first of equal ones), or nil.
pub fn arrayMinBy(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    return extremeBy(vm, arr, closure, .lt, "min_by");
}

/// Array#max_by { |x| key }: the item with the greatest key (the first of equal ones), or nil.
pub fn arrayMaxBy(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    return extremeBy(vm, arr, closure, .gt, "max_by");
}

fn extremeBy(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure, comptime wanted: std.math.Order, comptime method: []const u8) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const by = try keyed(vm, scope, arr, closure);
    if (by.broke) |v| return v;
    const keys = by.keys.items.items;
    if (keys.len == 0) return value.Value.initNil();
    try requireOrdered(vm, keys, method, .keys, "");
    var best: usize = 0;
    for (keys, 0..) |key, i| {
        if (orderOf(key, keys[best]) == wanted) best = i;
    }
    return by.items.items.items[best];
}

/// Array#group_by { |x| key }: a Map from each key the block gives to the items that gave
/// it, in their order; the keys are a Map's (`map[key]` finds a group).
pub fn arrayGroupBy(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const groups = try scope.map();
    var i: usize = 0;
    while (i < arr.items.items.len) : (i += 1) {
        const item = arr.items.items[i];
        const key = switch (try callBlock(vm, closure, &.{item})) {
            .broke => |v| return v,
            .value => |v| v,
        };
        var held = HandleScope.init(vm);
        defer held.deinit();
        vm.push(key);
        if (groups.table.get(key)) |group| {
            try group.asArray().items.append(vm.gc.trackingAllocator(), item);
            continue;
        }
        const group = try vm.gc.allocateArrayOf(vm, &.{item});
        vm.push(value.Value.initObj(&group.obj));
        try groups.table.put(vm.gc.trackingAllocator(), key, value.Value.initObj(&group.obj));
    }
    return value.Value.initObj(&groups.obj);
}

/// Array class method dispatch table
pub const methods = [_]common.MethodDef{
    .{ .name = "length", .func = common.wrapMethod(arrayLength) },
    .{ .name = "size", .func = common.wrapMethod(arrayLength) },
    .{ .name = "push", .func = common.wrapMethod(arrayPush) },
    .{ .name = "pop", .func = common.wrapMethod(arrayPop) },
    .{ .name = "shift", .func = common.wrapMethod(arrayShift) },
    .{ .name = "unshift", .func = common.wrapMethod(arrayUnshift) },
    .{ .name = "slice", .func = common.wrapMethod(arraySlice) },
    .{ .name = "join", .func = common.wrapMethod(arrayJoin) },
    .{ .name = "each", .func = common.wrapMethod(arrayEach) },
    .{ .name = "map", .func = common.wrapMethod(arrayMap) },
    .{ .name = "filter", .func = common.wrapMethod(arrayFilter) },
    .{ .name = "reject", .func = common.wrapMethod(arrayReject) },
    .{ .name = "compact", .func = common.wrapMethod(arrayCompact) },
    .{ .name = "reduce", .func = common.wrapMethod(arrayReduce) },
    .{ .name = "first", .func = common.wrapMethod(arrayFirst) },
    .{ .name = "last", .func = common.wrapMethod(arrayLast) },
    .{ .name = "contains?", .func = common.wrapMethod(arrayContains) },
    .{ .name = "include?", .func = common.wrapMethod(arrayContains) },
    .{ .name = "flatten", .func = common.wrapMethod(arrayFlatten) },
    .{ .name = "max", .func = common.wrapMethod(arrayMax) },
    .{ .name = "min", .func = common.wrapMethod(arrayMin) },
    .{ .name = "sum", .func = common.wrapMethod(arraySum) },
    .{ .name = "sort", .func = common.wrapMethod(arraySort) },
    .{ .name = "to_h", .func = common.wrapMethod(arrayToH) },
    .{ .name = "each_with_index", .func = common.wrapMethod(arrayEachWithIndex) },
    .{ .name = "each_cons", .func = common.wrapMethod(arrayEachCons) },
    .{ .name = "each_slice", .func = common.wrapMethod(arrayEachSlice) },
    .{ .name = "zip", .func = common.wrapMethod(arrayZip) },
    .{ .name = "uniq", .func = common.wrapMethod(arrayUniq) },
    .{ .name = "reverse", .func = common.wrapMethod(arrayReverse) },
    .{ .name = "any?", .func = common.wrapMethod(arrayAny) },
    .{ .name = "all?", .func = common.wrapMethod(arrayAll) },
    .{ .name = "none?", .func = common.wrapMethod(arrayNone) },
    .{ .name = "find", .func = common.wrapMethod(arrayFind) },
    .{ .name = "count", .func = common.wrapMethod(arrayCount) },
    .{ .name = "take", .func = common.wrapMethod(arrayTake) },
    .{ .name = "drop", .func = common.wrapMethod(arrayDrop) },
    .{ .name = "flat_map", .func = common.wrapMethod(arrayFlatMap) },
    .{ .name = "sort_by", .func = common.wrapMethod(arraySortBy) },
    .{ .name = "min_by", .func = common.wrapMethod(arrayMinBy) },
    .{ .name = "max_by", .func = common.wrapMethod(arrayMaxBy) },
    .{ .name = "group_by", .func = common.wrapMethod(arrayGroupBy) },
};
