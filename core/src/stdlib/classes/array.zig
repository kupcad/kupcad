const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const HandleScope = @import("../../vm/scope.zig").HandleScope;
const common = @import("common.zig");

/// Array#length / Array#size
pub fn arrayLength(vm: *VM, arr: *value.ObjArray) !value.Value {
    _ = vm;
    return value.Value.initNumber(@floatFromInt(arr.items.items.len));
}

/// Array#push(val)
pub fn arrayPush(vm: *VM, arr: *value.ObjArray, val: value.Value) !value.Value {
    try arr.items.append(vm.allocator, val);
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
    try arr.items.insert(vm.allocator, 0, val);
    return value.Value.initObj(&arr.obj);
}

/// Array#slice(start, len)
pub fn arraySlice(vm: *VM, arr: *value.ObjArray, start_num: f64, len_num: f64) !value.Value {
    const start_idx = @as(usize, @intFromFloat(start_num));
    const length = @as(usize, @intFromFloat(len_num));

    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));
    try new_arr.items.ensureTotalCapacity(vm.allocator, length);

    var idx: usize = 0;
    while (idx < length and start_idx + idx < arr.items.items.len) : (idx += 1) {
        const item = arr.items.items[start_idx + idx];
        new_arr.items.appendAssumeCapacity(item);
    }
    return value.Value.initObj(&new_arr.obj);
}

/// Array#join(delim)
pub fn arrayJoin(vm: *VM, arr: *value.ObjArray, delim_obj: *value.ObjString) !value.Value {
    const delim = delim_obj.chars;

    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    errdefer out.deinit();

    for (arr.items.items, 0..) |item, idx| {
        item.stringify(false, &out.writer) catch return error.RuntimeError;
        if (idx < arr.items.items.len - 1) {
            out.writer.writeAll(delim) catch return error.RuntimeError;
        }
    }

    const merged_bytes = try vm.allocator.dupe(u8, out.written());
    out.deinit();

    errdefer vm.allocator.free(merged_bytes);
    return try vm.allocateStringTakeOwnership(merged_bytes);
}

/// Array#each { |x| ... }
pub fn arrayEach(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    for (arr.items.items) |item| {
        _ = vm.callClosureSync(closure, &.{item}) catch |err| {
            if (err == error.BlockBreak) return vm.stack[vm.stack_top - 1];
            return err;
        };
    }
    return value.Value.initObj(&arr.obj);
}

/// Array#map { |x| ... }
pub fn arrayMap(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));
    try new_arr.items.ensureTotalCapacity(vm.allocator, arr.items.items.len);
    for (arr.items.items) |item| {
        const mapped_val = vm.callClosureSync(closure, &.{item}) catch |err| {
            if (err == error.BlockBreak) return vm.stack[vm.stack_top - 1];
            return err;
        };
        new_arr.items.appendAssumeCapacity(mapped_val);
    }
    return value.Value.initObj(&new_arr.obj);
}

/// Array#reduce(initial_val, block) / Array#reduce(block)
pub fn arrayReduce(vm: *VM, arr: *value.ObjArray, initial_val: ?value.Value, block: ?*value.ObjClosure) !value.Value {
    if (block == null) {
        _ = vm.throwDynamicError("Runtime Error: reduce requires a block.\n", .{});
        return error.RuntimeError;
    }

    var acc_val: value.Value = undefined;
    var start_idx: usize = 0;

    if (initial_val) |val| {
        acc_val = val;
    } else {
        if (arr.items.items.len == 0) return value.Value.initNil();
        acc_val = arr.items.items[0];
        start_idx = 1;
    }

    for (arr.items.items[start_idx..]) |item| {
        acc_val = try vm.callClosureSync(block.?, &.{ acc_val, item });
    }
    return acc_val;
}

/// Array#filter { |x| ... }
pub fn arrayFilter(vm: *VM, arr: *value.ObjArray, closure: *value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));

    for (arr.items.items) |item| {
        const res = try vm.callClosureSync(closure, &.{item});
        const is_truthy = !res.isNil() and !(res.isBool() and !res.asBool());
        if (is_truthy) {
            try new_arr.items.append(vm.allocator, item);
        }
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
        if (item.isObject() and item.asObj().obj_type == .array) {
            const inner_arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", item.asObj())));
            for (inner_arr.items.items) |inner_item| {
                try new_arr.items.append(vm.allocator, inner_item);
            }
        } else {
            try new_arr.items.append(vm.allocator, item);
        }
    }
    return value.Value.initObj(&new_arr.obj);
}

/// Array#max
pub fn arrayMax(vm: *VM, arr: *value.ObjArray) !value.Value {
    _ = vm;
    if (arr.items.items.len == 0) return value.Value.initNil();

    var max_val = if (arr.items.items[0].isNumber()) arr.items.items[0].asNumber() else -std.math.inf(f64);

    for (arr.items.items[1..]) |item| {
        if (item.isNumber() and item.asNumber() > max_val) {
            max_val = item.asNumber();
        }
    }
    return value.Value.initNumber(max_val);
}

/// Array#min
pub fn arrayMin(vm: *VM, arr: *value.ObjArray) !value.Value {
    _ = vm;
    if (arr.items.items.len == 0) return value.Value.initNil();

    var min_val = if (arr.items.items[0].isNumber()) arr.items.items[0].asNumber() else std.math.inf(f64);

    for (arr.items.items[1..]) |item| {
        if (item.isNumber() and item.asNumber() < min_val) {
            min_val = item.asNumber();
        }
    }
    return value.Value.initNumber(min_val);
}

/// Array#sum
pub fn arraySum(vm: *VM, arr: *value.ObjArray) !value.Value {
    _ = vm;
    var sum: f64 = 0.0;

    for (arr.items.items) |item| {
        if (item.isNumber()) sum += item.asNumber();
    }
    return value.Value.initNumber(sum);
}

/// Array#sort
/// Sorts natively for Strings/Numbers, or uses a custom block
pub fn arraySort(vm: *VM, arr: *value.ObjArray, block: ?*value.ObjClosure) !value.Value {
    const items = arr.items.items;

    // Allocate a NEW array to prevent in-place mutation
    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj)); // Protect from GC
    try new_arr.items.appendSlice(vm.allocator, items);

    const new_items = new_arr.items.items;

    if (new_items.len <= 1) {
        _ = vm.pop();
        return value.Value.initObj(&new_arr.obj);
    }

    // Iterative QuickSort
    var stack: [64]usize = undefined;
    var top: usize = 0;

    stack[top] = 0;
    top += 1;
    stack[top] = new_items.len - 1;
    top += 1;

    while (top > 0) {
        top -= 1;
        const high = stack[top];
        top -= 1;
        const low = stack[top];

        // Partitioning phase
        const pivot = new_items[high];
        var i = low;

        var j = low;
        while (j < high) : (j += 1) {
            var cmp_val: f64 = 0;

            if (block) |b| {
                const res = try vm.callClosureSync(b, &.{ new_items[j], pivot });
                if (!res.isNumber()) {
                    _ = vm.throwDynamicError("TypeError: sort block must return a Number (-1, 0, 1).\n", .{});
                    return error.RuntimeError;
                }
                cmp_val = res.asNumber();
            } else {
                const a_val = new_items[j];
                if (a_val.isNumber() and pivot.isNumber()) {
                    const an = a_val.asNumber();
                    const pn = pivot.asNumber();
                    cmp_val = if (an < pn) -1.0 else if (an > pn) 1.0 else 0.0;
                } else if (a_val.isString() and pivot.isString()) {
                    const order = std.mem.order(u8, a_val.asString().chars, pivot.asString().chars);
                    cmp_val = switch (order) {
                        .lt => -1.0,
                        .gt => 1.0,
                        .eq => 0.0,
                    };
                } else {
                    _ = vm.throwDynamicError("ArgumentError: Cannot natively sort disparate types. Provide a block.\n", .{});
                    return error.RuntimeError;
                }
            }

            // If current element is smaller than or equal to pivot
            if (cmp_val <= 0) {
                const temp = new_items[i];
                new_items[i] = new_items[j];
                new_items[j] = temp;
                i += 1;
            }
        }

        // Swap pivot to its final correct position
        const temp = new_items[i];
        new_items[i] = new_items[high];
        new_items[high] = temp;

        const p = i;

        // Push left side to stack
        if (p > 0 and p - 1 > low) {
            stack[top] = low;
            top += 1;
            stack[top] = p - 1;
            top += 1;
        }

        // Push right side to stack
        if (p + 1 < high) {
            stack[top] = p + 1;
            top += 1;
            stack[top] = high;
            top += 1;
        }
    }

    _ = vm.pop(); // Pop new_arr
    return value.Value.initObj(&new_arr.obj);
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
    .{ .name = "reduce", .func = common.wrapMethod(arrayReduce) },
    .{ .name = "first", .func = common.wrapMethod(arrayFirst) },
    .{ .name = "last", .func = common.wrapMethod(arrayLast) },
    .{ .name = "contains?", .func = common.wrapMethod(arrayContains) },
    .{ .name = "flatten", .func = common.wrapMethod(arrayFlatten) },
    .{ .name = "max", .func = common.wrapMethod(arrayMax) },
    .{ .name = "min", .func = common.wrapMethod(arrayMin) },
    .{ .name = "sum", .func = common.wrapMethod(arraySum) },
    .{ .name = "sort", .func = common.wrapMethod(arraySort) },
};
