//! The natives of Array (`Array.new`, `push`, `map`, `reduce`, `slice`, `sort`, ...) and
//! their dispatch table, `methods`.

const std = @import("std");
const value = @import("../../core/value.zig");
const limits = @import("../../core/limits.zig");
const VM = @import("../../vm/vm.zig").VM;
const HandleScope = @import("../../vm/scope.zig").HandleScope;
const common = @import("common.zig");
const callBlock = @import("iteration.zig").callBlock;

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

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));
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
    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));
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
    if (block == null) {
        return vm.fail(.ArgumentError, "reduce requires a block.", .{});
    }

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
        acc_val = switch (try callBlock(vm, block.?, &.{ acc_val, arr.items.items[i] })) {
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

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));

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

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));

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

/// Array#flatten
pub fn arrayFlatten(vm: *VM, arr: *value.ObjArray) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));

    for (arr.items.items) |item| {
        if (item.isArray()) {
            const inner_arr = item.asArray();
            for (inner_arr.items.items) |inner_item| {
                try new_arr.items.append(vm.gc.trackingAllocator(), inner_item);
            }
        } else {
            try new_arr.items.append(vm.gc.trackingAllocator(), item);
        }
    }
    return value.Value.initObj(&new_arr.obj);
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
    var best = items[0];
    for (items, 0..) |item, i| {
        // Each element, not only the first: after a String, a nil passed the check below
        // and was read as a String (found by the runtime fuzz test)
        if (!item.isNumber() and !item.isString()) return vm.fail(.TypeError, name ++ " needs Numbers or Strings, got {s} at index {d}", .{ vm.typeName(item), i });
        if (item.isNumber() != best.isNumber()) return vm.fail(.TypeError, name ++ " can't compare {s} with {s}", .{ vm.typeName(best), vm.typeName(item) });
        if (item.isNumber() and std.math.isNan(item.asNumber())) {
            return vm.fail(.MathError, name ++ ": the Array holds NaN at index {d}", .{i});
        }
        const order = if (item.isNumber()) std.math.order(item.asNumber(), best.asNumber()) else std.mem.order(u8, item.asString().chars, best.asString().chars);
        if (order == wanted) best = item;
    }
    return best;
}

/// Array#sum: the Numbers added up (0 for an empty Array). Anything else is a TypeError
/// (it used to be skipped), and a total beyond the Number range a RangeError.
pub fn arraySum(vm: *VM, arr: *value.ObjArray) !value.Value {
    var sum: f64 = 0.0;
    var all_finite = true;
    for (arr.items.items, 0..) |item, i| {
        if (!item.isNumber()) return vm.fail(.TypeError, "sum needs Numbers, got {s} at index {d}", .{ vm.typeName(item), i });
        if (!std.math.isFinite(item.asNumber())) all_finite = false;
        sum += item.asNumber();
    }
    if (all_finite and !std.math.isFinite(sum)) {
        return vm.fail(.RangeError, "sum overflowed the Number range", .{});
    }
    return value.Value.initNumber(sum);
}

/// How Array#sort orders two values: natively for Numbers or Strings, else by the block,
/// which must give a Number (its sign). The block can raise or `break`, which a sort's
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
        if (a.isNumber() and b.isNumber()) return a.asNumber() < b.asNumber();
        if (a.isString() and b.isString()) return std.mem.order(u8, a.asString().chars, b.asString().chars) == .lt;
        return self.vm.fail(.ArgumentError, "sort can't compare {s} with {s}; give it a block", .{ self.vm.typeName(a), self.vm.typeName(b) });
    }
};

/// Array#sort
/// A sorted copy: Numbers or Strings natively, anything with a block. (A hand-written
/// quicksort kept its partitions in a 64-entry buffer and overran it on a few hundred
/// already-sorted numbers; std.sort.pdq is bounded whatever the input.)
pub fn arraySort(vm: *VM, arr: *value.ObjArray, block: ?*value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj)); // Rooted while the block runs
    try new_arr.items.appendSlice(vm.gc.trackingAllocator(), arr.items.items);

    var order = SortOrder{ .vm = vm, .block = block };
    std.sort.pdq(value.Value, new_arr.items.items, &order, SortOrder.lessThan);
    if (order.failed) |err| return err;
    if (order.broke) |v| return v;
    return value.Value.initObj(&new_arr.obj);
}

/// Array#to_h
/// Converts an array of pair arrays [[k, v], [k, v]] into a Map
pub fn arrayToH(vm: *VM, arr: *value.ObjArray) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_map = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&new_map.obj));

    try new_map.map.ensureTotalCapacity(vm.gc.trackingAllocator(), arr.items.items.len);

    for (arr.items.items) |item| {
        if (item.isArray()) {
            const inner_arr = item.asArray();
            const inner_items = inner_arr.items.items;
            if (inner_items.len >= 2) {
                try new_map.map.put(vm.gc.trackingAllocator(), inner_items[0], inner_items[1]);
            } else if (inner_items.len == 1) {
                try new_map.map.put(vm.gc.trackingAllocator(), inner_items[0], value.Value.initNil());
            } else {
                return vm.fail(.ArgumentError, "empty array cannot be converted to key-value pair.", .{});
            }
        } else {
            return vm.fail(.ArgumentError, "wrong element type (expected array).", .{});
        }
    }

    return value.Value.initObj(&new_map.obj);
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
    .{ .name = "flatten", .func = common.wrapMethod(arrayFlatten) },
    .{ .name = "max", .func = common.wrapMethod(arrayMax) },
    .{ .name = "min", .func = common.wrapMethod(arrayMin) },
    .{ .name = "sum", .func = common.wrapMethod(arraySum) },
    .{ .name = "sort", .func = common.wrapMethod(arraySort) },
    .{ .name = "to_h", .func = common.wrapMethod(arrayToH) },
};
