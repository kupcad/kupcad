const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

pub fn arrayLength(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 0, args);
    return value.Value.initNumber(@floatFromInt(ctx.arr.items.items.len));
}

pub fn arrayPush(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 1, args);
    ctx.vm.retainValue(args[0]);
    try ctx.arr.items.append(ctx.vm.allocator, args[0]);
    return ctx.receiver;
}

pub fn arrayPop(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 0, args);
    if (ctx.arr.items.items.len > 0) {
        const val = ctx.arr.items.items[ctx.arr.items.items.len - 1];
        ctx.arr.items.shrinkRetainingCapacity(ctx.arr.items.items.len - 1);
        return val;
    }
    return value.Value.initNil();
}

pub fn arrayShift(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 0, args);
    if (ctx.arr.items.items.len > 0) {
        return ctx.arr.items.orderedRemove(0);
    }
    return value.Value.initNil();
}

pub fn arrayUnshift(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 1, args);
    ctx.vm.retainValue(args[0]);
    try ctx.arr.items.insert(ctx.vm.allocator, 0, args[0]);
    return ctx.receiver;
}

pub fn arraySlice(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 2, args);
    const start_val = args[0];
    const len_val = args[1];
    if (!start_val.isNumber() or !len_val.isNumber()) return error.RuntimeError;

    const start_idx = @as(usize, @intFromFloat(start_val.asNumber()));
    const length = @as(usize, @intFromFloat(len_val.asNumber()));

    const new_arr = try ctx.vm.gc.allocateArray(ctx.vm);
    ctx.vm.push(value.Value.initObj(&new_arr.obj));
    defer _ = ctx.vm.pop();
    try new_arr.items.ensureTotalCapacity(ctx.vm.allocator, length);

    var idx: usize = 0;
    while (idx < length and start_idx + idx < ctx.arr.items.items.len) : (idx += 1) {
        const item = ctx.arr.items.items[start_idx + idx];
        ctx.vm.retainValue(item);
        new_arr.items.appendAssumeCapacity(item);
    }
    return value.Value.initObj(&new_arr.obj);
}

pub fn arrayJoin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 1, args);

    if (!args[0].isObject() or args[0].asObj().obj_type != .string) return error.RuntimeError;
    const delim = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", args[0].asObj()))).chars;

    var out: std.Io.Writer.Allocating = .init(ctx.vm.allocator);
    errdefer out.deinit();

    for (ctx.arr.items.items, 0..) |item, idx| {
        item.stringify(false, &out.writer) catch return error.RuntimeError;
        if (idx < ctx.arr.items.items.len - 1) {
            out.writer.writeAll(delim) catch return error.RuntimeError;
        }
    }

    const merged_bytes = try ctx.vm.allocator.dupe(u8, out.written());
    out.deinit();

    // The critical memory leak patch!
    errdefer ctx.vm.allocator.free(merged_bytes);

    return try ctx.vm.allocateStringTakeOwnership(merged_bytes);
}

pub fn arrayEach(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 1, args);
    const closure_val = args[0];
    if (!closure_val.isClosure()) return error.RuntimeError;
    const closure = closure_val.asClosure();

    for (ctx.arr.items.items) |item| {
        _ = try ctx.vm.callClosureSync(closure, &.{item});
    }
    return ctx.receiver;
}

pub fn arrayMap(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 1, args);
    const closure_val = args[0];
    if (!closure_val.isClosure()) return error.RuntimeError;
    const closure = closure_val.asClosure();

    const new_arr = try ctx.vm.gc.allocateArray(ctx.vm);
    ctx.vm.push(value.Value.initObj(&new_arr.obj));
    defer _ = ctx.vm.pop();
    try new_arr.items.ensureTotalCapacity(ctx.vm.allocator, ctx.arr.items.items.len);

    for (ctx.arr.items.items) |item| {
        const mapped_val = try ctx.vm.callClosureSync(closure, &.{item});
        ctx.vm.retainValue(mapped_val);
        new_arr.items.appendAssumeCapacity(mapped_val);
    }
    return value.Value.initObj(&new_arr.obj);
}

pub fn arrayReduce(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
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

pub fn arrayFilter(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 1, args);
    const closure_val = args[0];
    if (!closure_val.isClosure()) return error.RuntimeError;
    const closure = closure_val.asClosure();

    const new_arr = try ctx.vm.gc.allocateArray(ctx.vm);
    ctx.vm.push(value.Value.initObj(&new_arr.obj));
    defer _ = ctx.vm.pop();

    for (ctx.arr.items.items) |item| {
        const res = try ctx.vm.callClosureSync(closure, &.{item});
        const is_truthy = !res.isNil() and !(res.isBool() and !res.asBool());
        if (is_truthy) {
            ctx.vm.retainValue(item);
            try new_arr.items.append(ctx.vm.allocator, item);
        }
    }
    return value.Value.initObj(&new_arr.obj);
}

pub fn arrayFirst(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 0, args);
    if (ctx.arr.items.items.len > 0) return ctx.arr.items.items[0];
    return value.Value.initNil();
}

pub fn arrayLast(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 0, args);
    const len = ctx.arr.items.items.len;
    if (len > 0) return ctx.arr.items.items[len - 1];
    return value.Value.initNil();
}

pub fn arrayContains(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 1, args);
    for (ctx.arr.items.items) |item| {
        if (ctx.vm.valuesEqual(item, args[0])) return value.Value.initBool(true);
    }
    return value.Value.initBool(false);
}

pub fn arrayFlatten(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 0, args);
    const new_arr = try ctx.vm.gc.allocateArray(ctx.vm);
    ctx.vm.push(value.Value.initObj(&new_arr.obj));
    defer _ = ctx.vm.pop();

    for (ctx.arr.items.items) |item| {
        if (item.isObject() and item.asObj().obj_type == .array) {
            const inner_arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", item.asObj())));
            for (inner_arr.items.items) |inner_item| {
                ctx.vm.retainValue(inner_item);
                try new_arr.items.append(ctx.vm.allocator, inner_item);
            }
        } else {
            ctx.vm.retainValue(item);
            try new_arr.items.append(ctx.vm.allocator, item);
        }
    }
    return value.Value.initObj(&new_arr.obj);
}

pub fn arrayMax(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 0, args);
    if (ctx.arr.items.items.len == 0) return value.Value.initNil();

    // Assume the first element is the baseline max
    var max_val = if (ctx.arr.items.items[0].isNumber()) ctx.arr.items.items[0].asNumber() else -std.math.inf(f64);

    for (ctx.arr.items.items[1..]) |item| {
        if (item.isNumber() and item.asNumber() > max_val) {
            max_val = item.asNumber();
        }
    }
    return value.Value.initNumber(max_val);
}

pub fn arrayMin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 0, args);
    if (ctx.arr.items.items.len == 0) return value.Value.initNil();

    var min_val = if (ctx.arr.items.items[0].isNumber()) ctx.arr.items.items[0].asNumber() else std.math.inf(f64);

    for (ctx.arr.items.items[1..]) |item| {
        if (item.isNumber() and item.asNumber() < min_val) {
            min_val = item.asNumber();
        }
    }
    return value.Value.initNumber(min_val);
}

pub fn arraySum(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapArray(vm_opaque, arg_count, 0, args);
    var sum: f64 = 0.0;

    for (ctx.arr.items.items) |item| {
        if (item.isNumber()) sum += item.asNumber();
    }
    return value.Value.initNumber(sum);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "length", .func = arrayLength },
    .{ .name = "size", .func = arrayLength },
    .{ .name = "push", .func = arrayPush },
    .{ .name = "pop", .func = arrayPop },
    .{ .name = "shift", .func = arrayShift },
    .{ .name = "unshift", .func = arrayUnshift },
    .{ .name = "slice", .func = arraySlice },
    .{ .name = "join", .func = arrayJoin },
    .{ .name = "each", .func = arrayEach },
    .{ .name = "map", .func = arrayMap },
    .{ .name = "filter", .func = arrayFilter },
    .{ .name = "reduce", .func = arrayReduce },
    .{ .name = "first", .func = arrayFirst },
    .{ .name = "last", .func = arrayLast },
    .{ .name = "contains?", .func = arrayContains },
    .{ .name = "flatten", .func = arrayFlatten },
    .{ .name = "max", .func = arrayMax },
    .{ .name = "min", .func = arrayMin },
    .{ .name = "sum", .func = arraySum },
};
