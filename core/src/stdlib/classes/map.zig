const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const HandleScope = @import("../../vm/scope.zig").HandleScope;
const common = @import("common.zig");

/// Map#keys
pub fn mapKeys(vm: *VM, map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));

    try new_arr.items.ensureTotalCapacity(vm.allocator, map.keys.items.len);
    for (map.keys.items) |k| {
        new_arr.items.appendAssumeCapacity(k);
    }
    return value.Value.initObj(&new_arr.obj);
}

/// Map#values
pub fn mapValues(vm: *VM, map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));

    try new_arr.items.ensureTotalCapacity(vm.allocator, map.values.items.len);
    for (map.values.items) |v| {
        new_arr.items.appendAssumeCapacity(v);
    }
    return value.Value.initObj(&new_arr.obj);
}

/// Map#has_key?(key)
pub fn mapHasKey(vm: *VM, map: *value.ObjMap, key: value.Value) !value.Value {
    const found = vm.findMapKey(map, key) != null;
    return value.Value.initBool(found);
}

/// Map#delete(key)
pub fn mapDelete(vm: *VM, map: *value.ObjMap, key: value.Value) !value.Value {
    if (vm.findMapKey(map, key)) |idx| {
        _ = map.keys.orderedRemove(idx);
        return map.values.orderedRemove(idx);
    }
    return value.Value.initNil();
}

/// Map#each { |k, v| ... }
pub fn mapEach(vm: *VM, map: *value.ObjMap, closure: *value.ObjClosure) !value.Value {
    for (map.keys.items, 0..) |k, i| {
        const v = map.values.items[i];
        _ = try vm.callClosureSync(closure, &.{ k, v });
    }
    return value.Value.initObj(&map.obj);
}

/// Map#empty?
pub fn mapEmpty(vm: *VM, map: *value.ObjMap) !value.Value {
    _ = vm;
    return value.Value.initBool(map.keys.items.len == 0);
}

/// Map#get(key, default)
pub fn mapGet(vm: *VM, map: *value.ObjMap, key: value.Value, default_val: value.Value) !value.Value {
    std.debug.assert(map.keys.items.len == map.values.items.len);

    if (vm.findMapKey(map, key)) |idx| {
        std.debug.assert(idx < map.values.items.len);
        return map.values.items[idx];
    }
    return default_val;
}

/// Map#merge(other_map)
pub fn mapMerge(vm: *VM, map: *value.ObjMap, other_map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_map = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&new_map.obj));

    // Copy self
    for (map.keys.items, 0..) |k, i| {
        try new_map.keys.append(vm.allocator, k);
        try new_map.values.append(vm.allocator, map.values.items[i]);
    }

    // Merge other
    for (other_map.keys.items, 0..) |k, i| {
        const v = other_map.values.items[i];
        if (vm.findMapKey(new_map, k)) |existing_idx| {
            new_map.values.items[existing_idx] = v;
        } else {
            try new_map.keys.append(vm.allocator, k);
            try new_map.values.append(vm.allocator, v);
        }
    }
    return value.Value.initObj(&new_map.obj);
}

/// Map#symbolize_keys
pub fn mapSymbolizeKeys(vm: *VM, map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_map = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&new_map.obj));

    for (map.keys.items, 0..) |k, i| {
        const v = map.values.items[i];
        var new_k = k;
        if (k.isObject() and k.asObj().obj_type == .string) {
            const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj())));
            new_k = try vm.allocateSymbol(str.chars);
        }
        try new_map.keys.append(vm.allocator, new_k);
        try new_map.values.append(vm.allocator, v);
    }
    return value.Value.initObj(&new_map.obj);
}

/// Map#stringify_keys
pub fn mapStringifyKeys(vm: *VM, map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_map = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&new_map.obj));

    for (map.keys.items, 0..) |k, i| {
        const v = map.values.items[i];
        var new_k = k;
        if (k.isObject() and k.asObj().obj_type == .symbol) {
            const sym = @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj())));
            new_k = try vm.allocateString(sym.chars);
        }
        try new_map.keys.append(vm.allocator, new_k);
        try new_map.values.append(vm.allocator, v);
    }
    return value.Value.initObj(&new_map.obj);
}

/// Map class method dispatch table
pub const methods = [_]common.MethodDef{
    .{ .name = "keys", .func = common.wrapMethod(mapKeys) },
    .{ .name = "values", .func = common.wrapMethod(mapValues) },
    .{ .name = "has_key?", .func = common.wrapMethod(mapHasKey) },
    .{ .name = "delete", .func = common.wrapMethod(mapDelete) },
    .{ .name = "each", .func = common.wrapMethod(mapEach) },
    .{ .name = "empty?", .func = common.wrapMethod(mapEmpty) },
    .{ .name = "get", .func = common.wrapMethod(mapGet) },
    .{ .name = "merge", .func = common.wrapMethod(mapMerge) },
    .{ .name = "symbolize_keys", .func = common.wrapMethod(mapSymbolizeKeys) },
    .{ .name = "stringify_keys", .func = common.wrapMethod(mapStringifyKeys) },
};
