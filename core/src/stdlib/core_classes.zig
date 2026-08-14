const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

// --- Array Methods ---
pub fn arrayLength(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;

    if (arg_count != 0) return error.RuntimeError;
    const receiver = (args - 1)[0];
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return value.Value.initNumber(@floatFromInt(arr.items.items.len));
}

pub fn arrayPush(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 1) return error.RuntimeError;

    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    vm.retainValue(args[0]);
    try arr.items.append(vm.allocator, args[0]);
    return receiver;
}

pub fn arrayPop(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 0) return error.RuntimeError;

    const receiver = (args - 1)[0];
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    if (arr.items.items.len > 0) {
        const val = arr.items.items[arr.items.items.len - 1];
        arr.items.shrinkRetainingCapacity(arr.items.items.len - 1);
        return val;
    }
    return value.Value.initNil();
}

pub fn arrayShift(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    if (arg_count != 0) return error.RuntimeError;

    const receiver = (args - 1)[0];
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    if (arr.items.items.len > 0) {
        return arr.items.orderedRemove(0);
    }
    return value.Value.initNil();
}

pub fn arrayUnshift(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 1) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    vm.retainValue(args[0]);
    try arr.items.insert(vm.allocator, 0, args[0]);
    return receiver;
}

pub fn arraySlice(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 2) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    const start_val = args[0];
    const len_val = args[1];
    if (!start_val.isNumber() or !len_val.isNumber()) return error.RuntimeError;

    const start_idx = @as(usize, @intFromFloat(start_val.asNumber()));
    const length = @as(usize, @intFromFloat(len_val.asNumber()));

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));
    defer _ = vm.pop();

    try new_arr.items.ensureTotalCapacity(vm.allocator, length);
    var idx: usize = 0;
    while (idx < length and start_idx + idx < arr.items.items.len) : (idx += 1) {
        const item = arr.items.items[start_idx + idx];
        vm.retainValue(item);
        new_arr.items.appendAssumeCapacity(item);
    }
    return value.Value.initObj(&new_arr.obj);
}

pub fn arrayJoin(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 1) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    if (!args[0].isObject() or args[0].asObj().obj_type != .string) return error.RuntimeError;

    const delim = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", args[0].asObj()))).chars;
    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();

    for (arr.items.items, 0..) |item, idx| {
        try item.stringify(false, &out.writer);
        if (idx < arr.items.items.len - 1) try out.writer.writeAll(delim);
    }
    return try vm.allocateString(out.written());
}

pub fn arrayEach(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 1) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    const closure_val = args[0];
    if (!closure_val.isClosure()) return error.RuntimeError;

    const closure = closure_val.asClosure();
    for (arr.items.items) |item| {
        _ = try vm.callClosureSync(closure, &.{item});
    }
    return receiver;
}

pub fn arrayMap(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 1) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    const closure_val = args[0];
    if (!closure_val.isClosure()) return error.RuntimeError;
    const closure = closure_val.asClosure();

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));
    defer _ = vm.pop();

    try new_arr.items.ensureTotalCapacity(vm.allocator, arr.items.items.len);
    for (arr.items.items) |item| {
        const mapped_val = try vm.callClosureSync(closure, &.{item});
        vm.retainValue(mapped_val);
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
    if (arg_count != 0) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", receiver.asObj())));

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));
    defer _ = vm.pop();

    try new_arr.items.ensureTotalCapacity(vm.allocator, map.keys.items.len);
    for (map.keys.items) |k| {
        vm.retainValue(k);
        new_arr.items.appendAssumeCapacity(k);
    }
    return value.Value.initObj(&new_arr.obj);
}

pub fn mapValues(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", receiver.asObj())));

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));
    defer _ = vm.pop();

    try new_arr.items.ensureTotalCapacity(vm.allocator, map.values.items.len);
    for (map.values.items) |v| {
        vm.retainValue(v);
        new_arr.items.appendAssumeCapacity(v);
    }
    return value.Value.initObj(&new_arr.obj);
}

pub fn mapHasKey(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 1) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    const found = vm.findMapKey(map, args[0]) != null;
    return value.Value.initBool(found);
}

pub fn mapDelete(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 1) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", receiver.asObj())));

    if (vm.findMapKey(map, args[0])) |idx| {
        const removed_key = map.keys.orderedRemove(idx);
        vm.releaseValue(removed_key);
        return map.values.orderedRemove(idx);
    }
    return value.Value.initNil();
}

pub fn mapEach(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 1) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    const closure_val = args[0];
    if (!closure_val.isClosure()) return error.RuntimeError;

    const closure = closure_val.asClosure();
    for (map.keys.items, 0..) |k, i| {
        const v = map.values.items[i];
        _ = try vm.callClosureSync(closure, &.{ k, v });
    }
    return receiver;
}

// --- String Methods ---
pub fn stringUpcase(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", receiver.asObj())));

    const new_str = try vm.allocator.alloc(u8, str_obj.chars.len);
    defer vm.allocator.free(new_str);
    for (str_obj.chars, 0..) |c, i| new_str[i] = std.ascii.toUpper(c);
    return try vm.allocateString(new_str);
}

pub fn stringDowncase(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 0) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", receiver.asObj())));

    const new_str = try vm.allocator.alloc(u8, str_obj.chars.len);
    defer vm.allocator.free(new_str);
    for (str_obj.chars, 0..) |c, i| new_str[i] = std.ascii.toLower(c);
    return try vm.allocateString(new_str);
}

pub fn stringSplit(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 1) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", receiver.asObj())));

    const delim_val = args[0];
    if (!delim_val.isObject() or delim_val.asObj().obj_type != .string) return error.RuntimeError;
    const delim_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", delim_val.asObj()))).chars;

    const arr_obj = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&arr_obj.obj));
    defer _ = vm.pop();

    var iter = std.mem.splitSequence(u8, str_obj.chars, delim_str);
    while (iter.next()) |part| {
        const part_val = try vm.allocateString(part);
        vm.retainValue(part_val);
        try arr_obj.items.append(vm.allocator, part_val);
    }
    return value.Value.initObj(&arr_obj.obj);
}

pub fn stringReplace(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 2) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", receiver.asObj())));

    const target_val = args[0];
    const replace_val = args[1];
    if (!target_val.isObject() or target_val.asObj().obj_type != .string) return error.RuntimeError;
    if (!replace_val.isObject() or replace_val.asObj().obj_type != .string) return error.RuntimeError;

    const t_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", target_val.asObj()))).chars;
    const r_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", replace_val.asObj()))).chars;

    const replaced = try std.mem.replaceOwned(u8, vm.allocator, str_obj.chars, t_str, r_str);
    defer vm.allocator.free(replaced);
    return try vm.allocateString(replaced);
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

pub fn registerCoreClasses(vm: *VM) !void {
    if (vm.array_class) |cls| {
        try bindNativeMethod(vm, cls, "length", arrayLength);
        try bindNativeMethod(vm, cls, "push", arrayPush);
        try bindNativeMethod(vm, cls, "pop", arrayPop);
        try bindNativeMethod(vm, cls, "shift", arrayShift);
        try bindNativeMethod(vm, cls, "unshift", arrayUnshift);
        try bindNativeMethod(vm, cls, "slice", arraySlice);
        try bindNativeMethod(vm, cls, "join", arrayJoin);
        try bindNativeMethod(vm, cls, "each", arrayEach);
        try bindNativeMethod(vm, cls, "map", arrayMap);
        try bindNativeMethod(vm, cls, "reduce", arrayReduce);
    }
    if (vm.map_class) |cls| {
        try bindNativeMethod(vm, cls, "keys", mapKeys);
        try bindNativeMethod(vm, cls, "values", mapValues);
        try bindNativeMethod(vm, cls, "has_key?", mapHasKey);
        try bindNativeMethod(vm, cls, "delete", mapDelete);
        try bindNativeMethod(vm, cls, "each", mapEach);
    }
    if (vm.string_class) |cls| {
        try bindNativeMethod(vm, cls, "upcase", stringUpcase);
        try bindNativeMethod(vm, cls, "downcase", stringDowncase);
        try bindNativeMethod(vm, cls, "split", stringSplit);
        try bindNativeMethod(vm, cls, "replace", stringReplace);
    }
    if (vm.globals.get("Math")) |v| {
        const math_cls = v.asInstance().class;
        try bindNativeMethod(vm, math_cls, "sin", mathSin);
        try bindNativeMethod(vm, math_cls, "cos", mathCos);
        try bindNativeMethod(vm, math_cls, "tan", mathTan);
        try bindNativeMethod(vm, math_cls, "sqrt", mathSqrt);
        try bindNativeMethod(vm, math_cls, "abs", mathAbs);
    }
}
