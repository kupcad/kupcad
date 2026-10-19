//! The Map class's methods (`keys`, `each`, `merge`, `get`, `symbolize_keys` and the rest),
//! as a `methods` table of `common.MethodDef`, and `mapNew`, which registry.zig binds as
//! `Map.new`.

const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const HandleScope = @import("../../vm/scope.zig").HandleScope;
const common = @import("common.zig");
const callBlock = @import("iteration.zig").callBlock;

/// Map.new -> an empty Map
pub fn mapNew(vm: *VM, class: value.Value) !value.Value {
    _ = class;
    const map = try vm.gc.allocateMap(vm);
    return value.Value.initObj(&map.obj);
}

/// Map#keys -> its keys, in insertion order
pub fn mapKeys(vm: *VM, map: *value.ObjMap) !value.Value {
    return value.Value.initObj(&(try vm.gc.allocateArrayOf(vm, map.map.keys())).obj);
}

/// Map#values
pub fn mapValues(vm: *VM, map: *value.ObjMap) !value.Value {
    return value.Value.initObj(&(try vm.gc.allocateArrayOf(vm, map.map.values())).obj);
}

/// Map#key?(key)
pub fn mapKey(vm: *VM, map: *value.ObjMap, key: value.Value) !value.Value {
    _ = vm;
    return value.Value.initBool(map.map.contains(key));
}

/// Map#delete(key)
/// Map#delete(key) -> the removed value, nil when absent. The other entries keep their
/// order (a swap-remove moved the last entry into the hole).
pub fn mapDelete(vm: *VM, map: *value.ObjMap, key: value.Value) !value.Value {
    _ = vm;
    if (map.map.fetchOrderedRemove(key)) |kv| {
        return kv.value;
    }
    return value.Value.initNil();
}

// The iterators index the map afresh on every step and stop at its current count: a
// block that inserts into the map it iterates moves its entries, and the key and value
// slices taken once read freed memory.

/// Map#each { |k, v| ... }
pub fn mapEach(vm: *VM, map: *value.ObjMap, closure: *value.ObjClosure) !value.Value {
    var i: usize = 0;
    while (i < map.map.count()) : (i += 1) {
        switch (try callBlock(vm, closure, &.{ map.map.keys()[i], map.map.values()[i] })) {
            .broke => |v| return v,
            .value => {},
        }
    }
    return value.Value.initObj(&map.obj);
}

/// Map#to_a
/// Converts the map to an array of key-value pair arrays [[k, v], ...]
pub fn mapToA(vm: *VM, map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));

    try new_arr.items.ensureTotalCapacity(vm.gc.trackingAllocator(), map.map.count());

    const keys = map.map.keys();
    const values = map.map.values();

    for (keys, 0..) |k, i| {
        const pair_arr = try vm.gc.allocateArray(vm);
        vm.push(value.Value.initObj(&pair_arr.obj)); // Protect pair_arr from GC

        try pair_arr.items.ensureTotalCapacity(vm.gc.trackingAllocator(), 2);
        pair_arr.items.appendAssumeCapacity(k);
        pair_arr.items.appendAssumeCapacity(values[i]);

        _ = vm.pop(); // Unprotect pair_arr
        new_arr.items.appendAssumeCapacity(value.Value.initObj(&pair_arr.obj));
    }

    return value.Value.initObj(&new_arr.obj);
}

/// Map#map { |k, v| ... }
/// Yields an array of array pairs `[[k, v], ...]` if no block is provided,
/// or an array of the block evaluations if a block is provided.
pub fn mapMap(vm: *VM, map: *value.ObjMap, block_opt: ?*value.ObjClosure) !value.Value {
    // Fallback to `to_a` if no block is provided
    if (block_opt == null) {
        return mapToA(vm, map);
    }

    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const new_arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&new_arr.obj));

    try new_arr.items.ensureTotalCapacity(vm.gc.trackingAllocator(), map.map.count());
    const closure = block_opt.?;

    var i: usize = 0;
    while (i < map.map.count()) : (i += 1) {
        const mapped_val = switch (try callBlock(vm, closure, &.{ map.map.keys()[i], map.map.values()[i] })) {
            .broke => |v| return v,
            .value => |v| v,
        };
        try new_arr.items.append(vm.gc.trackingAllocator(), mapped_val);
    }

    return value.Value.initObj(&new_arr.obj);
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
        try new_map.map.put(vm.gc.trackingAllocator(), entry.key_ptr.*, entry.value_ptr.*);
    }

    var other_it = other_map.map.iterator();
    while (other_it.next()) |entry| {
        try new_map.map.put(vm.gc.trackingAllocator(), entry.key_ptr.*, entry.value_ptr.*);
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
        if (k.isString()) {
            const str = k.asString();
            new_k = try vm.allocateSymbol(str.chars);
        }
        try new_map.map.put(vm.gc.trackingAllocator(), new_k, entry.value_ptr.*);
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
        if (k.isSymbol()) {
            const sym = k.asSymbol();
            new_k = try vm.allocateString(sym.chars);
        }
        try new_map.map.put(vm.gc.trackingAllocator(), new_k, entry.value_ptr.*);
    }
    return value.Value.initObj(&new_map.obj);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "keys", .func = common.wrapMethod(mapKeys) },
    .{ .name = "values", .func = common.wrapMethod(mapValues) },
    .{ .name = "key?", .func = common.wrapMethod(mapKey) },
    .{ .name = "delete", .func = common.wrapMethod(mapDelete) },
    .{ .name = "each", .func = common.wrapMethod(mapEach) },
    .{ .name = "map", .func = common.wrapMethod(mapMap) },
    .{ .name = "empty?", .func = common.wrapMethod(mapEmpty) },
    .{ .name = "get", .func = common.wrapMethod(mapGet) },
    .{ .name = "merge", .func = common.wrapMethod(mapMerge) },
    .{ .name = "symbolize_keys", .func = common.wrapMethod(mapSymbolizeKeys) },
    .{ .name = "stringify_keys", .func = common.wrapMethod(mapStringifyKeys) },
    .{ .name = "to_a", .func = common.wrapMethod(mapToA) },
};
