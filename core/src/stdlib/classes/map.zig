const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

pub fn mapKeys(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapMap(vm_opaque, arg_count, 0, args);
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
    const ctx = try common.unwrapMap(vm_opaque, arg_count, 0, args);
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
    const ctx = try common.unwrapMap(vm_opaque, arg_count, 1, args);
    const found = ctx.vm.findMapKey(ctx.map, args[0]) != null;
    return value.Value.initBool(found);
}

pub fn mapDelete(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapMap(vm_opaque, arg_count, 1, args);
    if (ctx.vm.findMapKey(ctx.map, args[0])) |idx| {
        const removed_key = ctx.map.keys.orderedRemove(idx);
        ctx.vm.releaseValue(removed_key);
        return ctx.map.values.orderedRemove(idx);
    }
    return value.Value.initNil();
}

pub fn mapEach(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapMap(vm_opaque, arg_count, 1, args);
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
    const ctx = try common.unwrapMap(vm_opaque, arg_count, 0, args);
    return value.Value.initBool(ctx.map.keys.items.len == 0);
}

pub fn mapGet(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapMap(vm_opaque, arg_count, 2, args);
    //Ensure the parallel arrays have not desynced
    std.debug.assert(ctx.map.keys.items.len == ctx.map.values.items.len);

    if (ctx.vm.findMapKey(ctx.map, args[0])) |idx| {
        // Ensure the found index is safe for the values array
        std.debug.assert(idx < ctx.map.values.items.len);
        return ctx.map.values.items[idx];
    }
    return args[1]; // Return default value
}

pub fn mapMerge(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapMap(vm_opaque, arg_count, 1, args);
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
    const ctx = try common.unwrapMap(vm_opaque, arg_count, 0, args);
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
    const ctx = try common.unwrapMap(vm_opaque, arg_count, 0, args);
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

pub const methods = [_]common.MethodDef{
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
