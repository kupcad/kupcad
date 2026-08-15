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

// --- String Methods ---

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
    .{ .name = "push", .func = arrayPush },
    .{ .name = "pop", .func = arrayPop },
    .{ .name = "shift", .func = arrayShift },
    .{ .name = "unshift", .func = arrayUnshift },
    .{ .name = "slice", .func = arraySlice },
    .{ .name = "join", .func = arrayJoin },
    .{ .name = "each", .func = arrayEach },
    .{ .name = "map", .func = arrayMap },
    .{ .name = "reduce", .func = arrayReduce },
};

const map_methods = [_]MethodDef{
    .{ .name = "keys", .func = mapKeys },
    .{ .name = "values", .func = mapValues },
    .{ .name = "has_key?", .func = mapHasKey },
    .{ .name = "delete", .func = mapDelete },
    .{ .name = "each", .func = mapEach },
};

const string_methods = [_]MethodDef{
    .{ .name = "upcase", .func = stringUpcase },
    .{ .name = "downcase", .func = stringDowncase },
    .{ .name = "split", .func = stringSplit },
    .{ .name = "replace", .func = stringReplace },
};

const math_methods = [_]MethodDef{
    .{ .name = "sin", .func = mathSin },
    .{ .name = "cos", .func = mathCos },
    .{ .name = "tan", .func = mathTan },
    .{ .name = "sqrt", .func = mathSqrt },
    .{ .name = "abs", .func = mathAbs },
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

    if (vm.globals.get("Math")) |v| {
        const math_cls = v.asInstance().class;
        for (math_methods) |def| try bindNativeMethod(vm, math_cls, def.name, def.func);
    }
}
