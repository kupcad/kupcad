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

    try new_arr.items.ensureTotalCapacity(vm.allocator, map.map.count());
    for (map.map.keys()) |k| {
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

    try new_arr.items.ensureTotalCapacity(vm.allocator, map.map.count());
    for (map.map.values()) |v| {
        new_arr.items.appendAssumeCapacity(v);
    }
    return value.Value.initObj(&new_arr.obj);
}

/// Map#has_key?(key)
pub fn mapHasKey(vm: *VM, map: *value.ObjMap, key: value.Value) !value.Value {
    _ = vm;
    return value.Value.initBool(map.map.contains(key));
}

/// Map#delete(key)
pub fn mapDelete(vm: *VM, map: *value.ObjMap, key: value.Value) !value.Value {
    _ = vm;
    if (map.map.fetchSwapRemove(key)) |kv| {
        return kv.value;
    }
    return value.Value.initNil();
}

/// Map#each { |k, v| ... }
pub fn mapEach(vm: *VM, map: *value.ObjMap, closure: *value.ObjClosure) !value.Value {
    const keys = map.map.keys();
    const values = map.map.values();
    for (keys, 0..) |k, i| {
        _ = try vm.callClosureSync(closure, &.{ k, values[i] });
    }
    return value.Value.initObj(&map.obj);
}

/// Map#empty?
pub fn mapEmpty(vm: *VM, map: *value.ObjMap) !value.Value {
    _ = vm;
    return value.Value.initBool(map.map.count() == 0);
}

/// Map#get(key, default)
pub fn mapGet(vm: *VM, map: *value.ObjMap, key: value.Value, default_val: value.Value) !value.Value {
    _ = vm;
    return map.map.get(key) orelse default_val;
}

/// Map#merge(other_map)
pub fn mapMerge(vm: *VM, map: *value.ObjMap, other_map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const new_map = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&new_map.obj));

    // Fast O(1) hash map merging
    var it = map.map.iterator();
    while (it.next()) |entry| {
        try new_map.map.put(vm.allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    var other_it = other_map.map.iterator();
    while (other_it.next()) |entry| {
        try new_map.map.put(vm.allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    return value.Value.initObj(&new_map.obj);
}

/// Map#symbolize_keys
pub fn mapSymbolizeKeys(vm: *VM, map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const new_map = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&new_map.obj));

    var it = map.map.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        var new_k = k;
        if (k.isObject() and k.asObj().obj_type == .string) {
            const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj())));
            new_k = try vm.allocateSymbol(str.chars);
        }
        try new_map.map.put(vm.allocator, new_k, entry.value_ptr.*);
    }
    return value.Value.initObj(&new_map.obj);
}

/// Map#stringify_keys
pub fn mapStringifyKeys(vm: *VM, map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const new_map = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&new_map.obj));

    var it = map.map.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        var new_k = k;
        if (k.isObject() and k.asObj().obj_type == .symbol) {
            const sym = @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj())));
            new_k = try vm.allocateString(sym.chars);
        }
        try new_map.map.put(vm.allocator, new_k, entry.value_ptr.*);
    }
    return value.Value.initObj(&new_map.obj);
}

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
