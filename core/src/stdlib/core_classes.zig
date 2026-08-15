const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

// --- Unboxing Helpers ---

fn unwrapArray(vm_opaque: *anyopaque, arg_count: u8, expected_args: u8, args: [*]value.Value) !struct { vm: *VM, receiver: value.Value, arr: *value.ObjArray } {
    if (arg_count != expected_args) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .arr = arr };
}

fn unwrapMap(vm_opaque: *anyopaque, arg_count: u8, expected_args: u8, args: [*]value.Value) !struct { vm: *VM, receiver: value.Value, map: *value.ObjMap } {
    if (arg_count != expected_args) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .map = map };
}

fn unwrapString(vm_opaque: *anyopaque, arg_count: u8, expected_args: u8, args: [*]value.Value) !struct { vm: *VM, receiver: value.Value, str: *value.ObjString } {
    if (arg_count != expected_args) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .str = str };
}

fn unwrapSymbol(vm_opaque: *anyopaque, arg_count: u8, expected_args: u8, args: [*]value.Value) !struct { vm: *VM, receiver: value.Value, sym: *value.ObjSymbol } {
    if (arg_count != expected_args) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const sym = @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .sym = sym };
}

// --- Array Methods ---

pub fn arrayLength(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapArray(vm_opaque, arg_count, 0, args);
    return value.Value.initNumber(@floatFromInt(ctx.arr.items.items.len));
}

pub fn arrayPush(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapArray(vm_opaque, arg_count, 1, args);
    ctx.vm.retainValue(args[0]);
    try ctx.arr.items.append(ctx.vm.allocator, args[0]);
    return ctx.receiver;
}

pub fn arrayPop(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapArray(vm_opaque, arg_count, 0, args);
    if (ctx.arr.items.items.len > 0) {
        const val = ctx.arr.items.items[ctx.arr.items.items.len - 1];
        ctx.arr.items.shrinkRetainingCapacity(ctx.arr.items.items.len - 1);
        return val;
    }
    return value.Value.initNil();
}

pub fn arrayShift(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapArray(vm_opaque, arg_count, 0, args);
    if (ctx.arr.items.items.len > 0) {
        return ctx.arr.items.orderedRemove(0);
    }
    return value.Value.initNil();
}

pub fn arrayUnshift(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapArray(vm_opaque, arg_count, 1, args);
    ctx.vm.retainValue(args[0]);
    try ctx.arr.items.insert(ctx.vm.allocator, 0, args[0]);
    return ctx.receiver;
}

pub fn arraySlice(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapArray(vm_opaque, arg_count, 2, args);
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
    const ctx = try unwrapArray(vm_opaque, arg_count, 1, args);
    if (!args[0].isObject() or args[0].asObj().obj_type != .string) return error.RuntimeError;
    const delim = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", args[0].asObj()))).chars;

    var out: std.Io.Writer.Allocating = .init(ctx.vm.allocator);
    defer out.deinit();
    for (ctx.arr.items.items, 0..) |item, idx| {
        try item.stringify(false, &out.writer);
        if (idx < ctx.arr.items.items.len - 1) try out.writer.writeAll(delim);
    }
    return try ctx.vm.allocateString(out.written());
}

pub fn arrayEach(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapArray(vm_opaque, arg_count, 1, args);
    const closure_val = args[0];
    if (!closure_val.isClosure()) return error.RuntimeError;
    const closure = closure_val.asClosure();

    for (ctx.arr.items.items) |item| {
        _ = try ctx.vm.callClosureSync(closure, &.{item});
    }
    return ctx.receiver;
}

pub fn arrayMap(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapArray(vm_opaque, arg_count, 1, args);
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
    const ctx = try unwrapArray(vm_opaque, arg_count, 1, args);
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
    const ctx = try unwrapArray(vm_opaque, arg_count, 0, args);
    if (ctx.arr.items.items.len > 0) return ctx.arr.items.items[0];
    return value.Value.initNil();
}

pub fn arrayLast(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapArray(vm_opaque, arg_count, 0, args);
    const len = ctx.arr.items.items.len;
    if (len > 0) return ctx.arr.items.items[len - 1];
    return value.Value.initNil();
}

pub fn arrayContains(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapArray(vm_opaque, arg_count, 1, args);
    for (ctx.arr.items.items) |item| {
        if (ctx.vm.valuesEqual(item, args[0])) return value.Value.initBool(true);
    }
    return value.Value.initBool(false);
}

pub fn arrayFlatten(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapArray(vm_opaque, arg_count, 0, args);
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
    const ctx = try unwrapArray(vm_opaque, arg_count, 0, args);
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
    const ctx = try unwrapArray(vm_opaque, arg_count, 0, args);
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
    const ctx = try unwrapArray(vm_opaque, arg_count, 0, args);
    var sum: f64 = 0.0;

    for (ctx.arr.items.items) |item| {
        if (item.isNumber()) sum += item.asNumber();
    }
    return value.Value.initNumber(sum);
}

// --- Map Methods ---

pub fn mapKeys(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapMap(vm_opaque, arg_count, 0, args);
    const new_arr = try ctx.vm.gc.allocateArray(ctx.vm);
    ctx.vm.push(value.Value.initObj(&new_arr.obj));
    defer _ = ctx.vm.pop();
    try new_arr.items.ensureTotalCapacity(ctx.vm.allocator, ctx.map.keys.items.len);
    for (ctx.map.keys.items) |k| {
        ctx.vm.retainValue(k);
        new_arr.items.appendAssumeCapacity(k);
    }
    return value.Value.initObj(&new_arr.obj);
}

pub fn mapValues(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapMap(vm_opaque, arg_count, 0, args);
    const new_arr = try ctx.vm.gc.allocateArray(ctx.vm);
    ctx.vm.push(value.Value.initObj(&new_arr.obj));
    defer _ = ctx.vm.pop();
    try new_arr.items.ensureTotalCapacity(ctx.vm.allocator, ctx.map.values.items.len);
    for (ctx.map.values.items) |v| {
        ctx.vm.retainValue(v);
        new_arr.items.appendAssumeCapacity(v);
    }
    return value.Value.initObj(&new_arr.obj);
}

pub fn mapHasKey(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapMap(vm_opaque, arg_count, 1, args);
    const found = ctx.vm.findMapKey(ctx.map, args[0]) != null;
    return value.Value.initBool(found);
}

pub fn mapDelete(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapMap(vm_opaque, arg_count, 1, args);
    if (ctx.vm.findMapKey(ctx.map, args[0])) |idx| {
        const removed_key = ctx.map.keys.orderedRemove(idx);
        ctx.vm.releaseValue(removed_key);
        return ctx.map.values.orderedRemove(idx);
    }
    return value.Value.initNil();
}

pub fn mapEach(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapMap(vm_opaque, arg_count, 1, args);
    const closure_val = args[0];
    if (!closure_val.isClosure()) return error.RuntimeError;
    const closure = closure_val.asClosure();

    for (ctx.map.keys.items, 0..) |k, i| {
        const v = ctx.map.values.items[i];
        _ = try ctx.vm.callClosureSync(closure, &.{ k, v });
    }
    return ctx.receiver;
}

pub fn mapEmpty(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapMap(vm_opaque, arg_count, 0, args);
    return value.Value.initBool(ctx.map.keys.items.len == 0);
}

pub fn mapGet(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapMap(vm_opaque, arg_count, 2, args);
    if (ctx.vm.findMapKey(ctx.map, args[0])) |idx| {
        return ctx.map.values.items[idx];
    }
    return args[1]; // Return default value
}

pub fn mapMerge(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapMap(vm_opaque, arg_count, 1, args);
    if (!args[0].isObject() or args[0].asObj().obj_type != .map) return error.RuntimeError;
    const other_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[0].asObj())));

    const new_map = try ctx.vm.gc.allocateMap(ctx.vm);
    ctx.vm.push(value.Value.initObj(&new_map.obj));
    defer _ = ctx.vm.pop();

    // Copy self
    for (ctx.map.keys.items, 0..) |k, i| {
        ctx.vm.retainValue(k);
        ctx.vm.retainValue(ctx.map.values.items[i]);
        try new_map.keys.append(ctx.vm.allocator, k);
        try new_map.values.append(ctx.vm.allocator, ctx.map.values.items[i]);
    }

    // Merge other
    for (other_map.keys.items, 0..) |k, i| {
        const v = other_map.values.items[i];
        if (ctx.vm.findMapKey(new_map, k)) |existing_idx| {
            ctx.vm.releaseValue(new_map.values.items[existing_idx]);
            ctx.vm.retainValue(v);
            new_map.values.items[existing_idx] = v;
        } else {
            ctx.vm.retainValue(k);
            ctx.vm.retainValue(v);
            try new_map.keys.append(ctx.vm.allocator, k);
            try new_map.values.append(ctx.vm.allocator, v);
        }
    }
    return value.Value.initObj(&new_map.obj);
}

pub fn mapSymbolizeKeys(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapMap(vm_opaque, arg_count, 0, args);
    const new_map = try ctx.vm.gc.allocateMap(ctx.vm);
    ctx.vm.push(value.Value.initObj(&new_map.obj));
    defer _ = ctx.vm.pop();

    for (ctx.map.keys.items, 0..) |k, i| {
        const v = ctx.map.values.items[i];
        var new_k = k;
        if (k.isObject() and k.asObj().obj_type == .string) {
            const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj())));
            new_k = try ctx.vm.allocateSymbol(str.chars);
        }
        ctx.vm.retainValue(new_k);
        ctx.vm.retainValue(v);
        try new_map.keys.append(ctx.vm.allocator, new_k);
        try new_map.values.append(ctx.vm.allocator, v);
    }
    return value.Value.initObj(&new_map.obj);
}

pub fn mapStringifyKeys(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapMap(vm_opaque, arg_count, 0, args);
    const new_map = try ctx.vm.gc.allocateMap(ctx.vm);
    ctx.vm.push(value.Value.initObj(&new_map.obj));
    defer _ = ctx.vm.pop();

    for (ctx.map.keys.items, 0..) |k, i| {
        const v = ctx.map.values.items[i];
        var new_k = k;
        if (k.isObject() and k.asObj().obj_type == .symbol) {
            const sym = @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj())));
            new_k = try ctx.vm.allocateString(sym.chars);
        }
        ctx.vm.retainValue(new_k);
        ctx.vm.retainValue(v);
        try new_map.keys.append(ctx.vm.allocator, new_k);
        try new_map.values.append(ctx.vm.allocator, v);
    }
    return value.Value.initObj(&new_map.obj);
}

// --- Number Methods ---

pub fn numberRound(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;

    if (arg_count > 1) return error.RuntimeError; // Takes 0 or 1 args

    const receiver = (args - 1)[0];
    if (!receiver.isNumber()) return error.RuntimeError;

    const num = receiver.asNumber();
    var decimals: f64 = 0.0;

    if (arg_count == 1) {
        if (!args[0].isNumber()) return error.RuntimeError;
        decimals = args[0].asNumber();
    }

    if (decimals == 0.0) {
        return value.Value.initNumber(@round(num));
    } else {
        const multiplier = std.math.pow(f64, 10.0, decimals);
        return value.Value.initNumber(@round(num * multiplier) / multiplier);
    }
}

pub fn numberCeil(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 0) return error.RuntimeError;
    const receiver = (args - 1)[0];
    if (!receiver.isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@ceil(receiver.asNumber()));
}

pub fn numberFloor(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 0) return error.RuntimeError;
    const receiver = (args - 1)[0];
    if (!receiver.isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@floor(receiver.asNumber()));
}

pub fn numberAbs(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 0) return error.RuntimeError;
    const receiver = (args - 1)[0];
    if (!receiver.isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@abs(receiver.asNumber()));
}

pub fn numberToI(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 0) return error.RuntimeError;
    const receiver = (args - 1)[0];
    if (!receiver.isNumber()) return error.RuntimeError;
    // Truncates decimal portion
    return value.Value.initNumber(@trunc(receiver.asNumber()));
}

pub fn numberToF(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 0) return error.RuntimeError;
    const receiver = (args - 1)[0];
    // Number is already a float internally, just return it
    return receiver;
}

// Number to String
pub fn numberToS(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    if (!receiver.isNumber()) return error.RuntimeError;

    var buf: [64]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{d}", .{receiver.asNumber()});
    return try vm.allocateString(str);
}

// --- String Methods ---

pub fn stringLength(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 0, args);
    // Safely count actual Unicode characters, fallback to raw byte length if invalid UTF-8
    const len = std.unicode.utf8CountCodepoints(ctx.str.chars) catch ctx.str.chars.len;
    return value.Value.initNumber(@floatFromInt(len));
}

pub fn stringUpcase(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 0, args);
    const new_str = try ctx.vm.allocator.alloc(u8, ctx.str.chars.len);
    defer ctx.vm.allocator.free(new_str);
    for (ctx.str.chars, 0..) |c, i| new_str[i] = std.ascii.toUpper(c);
    return try ctx.vm.allocateString(new_str);
}

pub fn stringDowncase(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 0, args);
    const new_str = try ctx.vm.allocator.alloc(u8, ctx.str.chars.len);
    defer ctx.vm.allocator.free(new_str);
    for (ctx.str.chars, 0..) |c, i| new_str[i] = std.ascii.toLower(c);
    return try ctx.vm.allocateString(new_str);
}

pub fn stringSplit(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 1, args);
    const delim_val = args[0];
    if (!delim_val.isObject() or delim_val.asObj().obj_type != .string) return error.RuntimeError;
    const delim_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", delim_val.asObj()))).chars;

    const arr_obj = try ctx.vm.gc.allocateArray(ctx.vm);
    ctx.vm.push(value.Value.initObj(&arr_obj.obj));
    defer _ = ctx.vm.pop();

    var iter = std.mem.splitSequence(u8, ctx.str.chars, delim_str);
    while (iter.next()) |part| {
        const part_val = try ctx.vm.allocateString(part);
        ctx.vm.retainValue(part_val);
        try arr_obj.items.append(ctx.vm.allocator, part_val);
    }
    return value.Value.initObj(&arr_obj.obj);
}

pub fn stringReplace(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 2, args);
    const target_val = args[0];
    const replace_val = args[1];
    if (!target_val.isObject() or target_val.asObj().obj_type != .string) return error.RuntimeError;
    if (!replace_val.isObject() or replace_val.asObj().obj_type != .string) return error.RuntimeError;

    const t_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", target_val.asObj()))).chars;
    const r_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", replace_val.asObj()))).chars;

    const replaced = try std.mem.replaceOwned(u8, ctx.vm.allocator, ctx.str.chars, t_str, r_str);
    defer ctx.vm.allocator.free(replaced);
    return try ctx.vm.allocateString(replaced);
}

pub fn stringToF(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 0, args);
    const float_val = std.fmt.parseFloat(f64, ctx.str.chars) catch return value.Value.initNil();
    return value.Value.initNumber(float_val);
}

pub fn stringToI(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 0, args);
    const int_val = std.fmt.parseInt(i64, ctx.str.chars, 10) catch return value.Value.initNil();
    return value.Value.initNumber(@floatFromInt(int_val));
}

pub fn stringTrim(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 0, args);
    const trimmed = std.mem.trim(u8, ctx.str.chars, " \t\r\n");
    return try ctx.vm.allocateString(trimmed);
}

pub fn stringStartsWith(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 1, args);
    if (!args[0].isObject() or args[0].asObj().obj_type != .string) return error.RuntimeError;
    const prefix = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", args[0].asObj()))).chars;
    return value.Value.initBool(std.mem.startsWith(u8, ctx.str.chars, prefix));
}

pub fn stringEndsWith(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 1, args);
    if (!args[0].isObject() or args[0].asObj().obj_type != .string) return error.RuntimeError;
    const suffix = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", args[0].asObj()))).chars;
    return value.Value.initBool(std.mem.endsWith(u8, ctx.str.chars, suffix));
}

// String to Symbol
pub fn stringToSym(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 0, args);
    return try ctx.vm.allocateSymbol(ctx.str.chars);
}

// String to String (Identity)
pub fn stringToS(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapString(vm_opaque, arg_count, 0, args);
    return ctx.receiver;
}

// Symbol to String
pub fn symbolToS(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapSymbol(vm_opaque, arg_count, 0, args);
    return try ctx.vm.allocateString(ctx.sym.chars);
}

// Symbol to Symbol (Identity)
pub fn symbolToSym(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try unwrapSymbol(vm_opaque, arg_count, 0, args);
    return ctx.receiver;
}

// --- Math Methods ---

pub fn mathSin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.sin(args[0].asNumber()));
}

pub fn mathCos(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.cos(args[0].asNumber()));
}

pub fn mathTan(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.tan(args[0].asNumber()));
}

pub fn mathSqrt(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.sqrt(args[0].asNumber()));
}

pub fn mathAbs(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@abs(args[0].asNumber()));
}

pub fn mathAsin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.asin(args[0].asNumber()));
}

pub fn mathAcos(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.acos(args[0].asNumber()));
}

pub fn mathAtan2(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 2 or !args[0].isNumber() or !args[1].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(std.math.atan2(args[0].asNumber(), args[1].asNumber()));
}

pub fn mathRound(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@round(args[0].asNumber()));
}

pub fn mathCeil(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@ceil(args[0].asNumber()));
}

pub fn mathFloor(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@floor(args[0].asNumber()));
}

pub fn mathDeg2Rad(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(args[0].asNumber() * std.math.pi / 180.0);
}

pub fn mathRad2Deg(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 1 or !args[0].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(args[0].asNumber() * 180.0 / std.math.pi);
}

pub fn mathMin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 2 or !args[0].isNumber() or !args[1].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@min(args[0].asNumber(), args[1].asNumber()));
}

pub fn mathMax(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 2 or !args[0].isNumber() or !args[1].isNumber()) return error.RuntimeError;
    return value.Value.initNumber(@max(args[0].asNumber(), args[1].asNumber()));
}

// --- Registration ---

fn bindNativeMethod(vm: *VM, class: *value.ObjClass, name: []const u8, func: value.NativeFn) !void {
    const native_obj = try vm.gc.allocateNative(vm, func);
    const native_val = value.Value.initObj(&native_obj.obj);
    try class.methods.put(vm.allocator, name, native_val);
}

const MethodDef = struct {
    name: []const u8,
    func: value.NativeFn,
};

const array_methods = [_]MethodDef{
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

const map_methods = [_]MethodDef{
    .{ .name = "keys", .func = mapKeys },
    .{ .name = "values", .func = mapValues },
    .{ .name = "has_key?", .func = mapHasKey },
    .{ .name = "delete", .func = mapDelete },
    .{ .name = "each", .func = mapEach },
    .{ .name = "empty?", .func = mapEmpty },
    .{ .name = "get", .func = mapGet },
    .{ .name = "merge", .func = mapMerge },
    .{ .name = "symbolize_keys", .func = mapSymbolizeKeys },
    .{ .name = "stringify_keys", .func = mapStringifyKeys },
};

const string_methods = [_]MethodDef{
    .{ .name = "upcase", .func = stringUpcase },
    .{ .name = "downcase", .func = stringDowncase },
    .{ .name = "split", .func = stringSplit },
    .{ .name = "replace", .func = stringReplace },
    .{ .name = "to_f", .func = stringToF },
    .{ .name = "to_i", .func = stringToI },
    .{ .name = "trim", .func = stringTrim },
    .{ .name = "starts_with?", .func = stringStartsWith },
    .{ .name = "ends_with?", .func = stringEndsWith },
    .{ .name = "to_sym", .func = stringToSym },
    .{ .name = "to_s", .func = stringToS },
};

const symbol_methods = [_]MethodDef{
    .{ .name = "to_s", .func = symbolToS },
    .{ .name = "to_sym", .func = symbolToSym },
};

const number_methods = [_]MethodDef{
    .{ .name = "to_s", .func = numberToS },
    .{ .name = "to_i", .func = numberToI },
    .{ .name = "to_f", .func = numberToF },
    .{ .name = "round", .func = numberRound },
    .{ .name = "ceil", .func = numberCeil },
    .{ .name = "floor", .func = numberFloor },
    .{ .name = "abs", .func = numberAbs },
};

const math_methods = [_]MethodDef{
    .{ .name = "sin", .func = mathSin },
    .{ .name = "cos", .func = mathCos },
    .{ .name = "tan", .func = mathTan },
    .{ .name = "asin", .func = mathAsin },
    .{ .name = "acos", .func = mathAcos },
    .{ .name = "atan2", .func = mathAtan2 },
    .{ .name = "sqrt", .func = mathSqrt },
    .{ .name = "abs", .func = mathAbs },
    .{ .name = "round", .func = mathRound },
    .{ .name = "ceil", .func = mathCeil },
    .{ .name = "floor", .func = mathFloor },
    .{ .name = "deg2rad", .func = mathDeg2Rad },
    .{ .name = "rad2deg", .func = mathRad2Deg },
    .{ .name = "min", .func = mathMin },
    .{ .name = "max", .func = mathMax },
};

pub fn registerCoreClasses(vm: *VM) !void {
    if (vm.array_class) |cls| {
        for (array_methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }

    if (vm.map_class) |cls| {
        for (map_methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }

    if (vm.string_class) |cls| {
        for (string_methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }

    if (vm.number_class) |cls| {
        for (number_methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }

    if (vm.symbol_class) |cls| {
        for (symbol_methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }

    if (vm.globals.get("Math")) |v| {
        const math_cls = v.asInstance().class;
        for (math_methods) |def| try bindNativeMethod(vm, math_cls, def.name, def.func);
    }
}
