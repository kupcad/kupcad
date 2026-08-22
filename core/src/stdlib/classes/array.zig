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
/// (Keeps NativeFn signature due to variable arity 1 or 2)
pub fn arrayReduce(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);

    std.debug.assert(receiver.isObject() and receiver.asObj().obj_type == .array);
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));

    var closure_val: value.Value = undefined;
    var acc_val: value.Value = undefined;
    var start_idx: usize = 0;

    if (arg_count == 2) {
        acc_val = args[0];
        closure_val = args[1];
    } else if (arg_count == 1) {
        closure_val = args[0];
        if (arr.items.items.len == 0) return value.Value.initNil();
        acc_val = arr.items.items[0];
        start_idx = 1;
    } else return error.RuntimeError;

    if (!closure_val.isClosure()) return error.RuntimeError;
    const closure = closure_val.asClosure();

    for (arr.items.items[start_idx..]) |item| {
        acc_val = try vm.callClosureSync(closure, &.{ acc_val, item });
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

/// Array class method dispatch table
pub const methods = [_]common.MethodDef{
    .{ .name = "length", .func = common.wrapNative(arrayLength) },
    .{ .name = "size", .func = common.wrapNative(arrayLength) },
    .{ .name = "push", .func = common.wrapNative(arrayPush) },
    .{ .name = "pop", .func = common.wrapNative(arrayPop) },
    .{ .name = "shift", .func = common.wrapNative(arrayShift) },
    .{ .name = "unshift", .func = common.wrapNative(arrayUnshift) },
    .{ .name = "slice", .func = common.wrapNative(arraySlice) },
    .{ .name = "join", .func = common.wrapNative(arrayJoin) },
    .{ .name = "each", .func = common.wrapNative(arrayEach) },
    .{ .name = "map", .func = common.wrapNative(arrayMap) },
    .{ .name = "filter", .func = common.wrapNative(arrayFilter) },
    .{ .name = "reduce", .func = arrayReduce },
    .{ .name = "first", .func = common.wrapNative(arrayFirst) },
    .{ .name = "last", .func = common.wrapNative(arrayLast) },
    .{ .name = "contains?", .func = common.wrapNative(arrayContains) },
    .{ .name = "flatten", .func = common.wrapNative(arrayFlatten) },
    .{ .name = "max", .func = common.wrapNative(arrayMax) },
    .{ .name = "min", .func = common.wrapNative(arrayMin) },
    .{ .name = "sum", .func = common.wrapNative(arraySum) },
};
