//! The Map class's methods (`keys`, `each`, `merge`, `get`, `fetch`, `dig`, `filter`,
//! `transform_values`, `symbolize_keys` and the rest), as a `methods` table of
//! `common.MethodDef`, and `mapNew`, which registry.zig binds as `Map.new`.

const std = @import("std");
const value = @import("../../core/value.zig");
const error_kind = @import("../../vm/error_kind.zig");
const vm_mod = @import("../../vm/vm.zig");
const VM = vm_mod.VM;
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
    return value.Value.initObj(&(try vm.gc.allocateArrayOfEntries(vm, map.entries(), .key)).obj);
}

/// Map#values
pub fn mapValues(vm: *VM, map: *value.ObjMap) !value.Value {
    return value.Value.initObj(&(try vm.gc.allocateArrayOfEntries(vm, map.entries(), .value)).obj);
}

/// Map#key?(key)
pub fn mapKey(vm: *VM, map: *value.ObjMap, key: value.Value) !value.Value {
    _ = vm;
    return value.Value.initBool(map.table.contains(key));
}

/// Map#delete(key) -> the removed value, nil when absent. The other entries keep their
/// order, at no cost (ObjMap.delete): moving those after it up re-hashed each of them, so
/// emptying a Map took a time its size squared.
pub fn mapDelete(vm: *VM, map: *value.ObjMap, key: value.Value) !value.Value {
    return map.delete(vm.gc.trackingAllocator(), key) orelse value.Value.initNil();
}

/// The entries a block is given, one at a time, by the iterators: the keys there when the
/// walk began (a copy, rooted in the caller's scope), each with its value when its turn
/// comes. One the block deletes before its turn isn't given, and one it adds isn't either:
/// walked by position, deleting the entry given moved the next into its place, which the
/// walk then passed, and a block adding entries walked on until memory ran out.
const Walk = struct {
    map: *value.ObjMap,
    keys: *value.ObjArray,
    at: usize = 0,

    fn init(vm: *VM, scope: HandleScope, map: *value.ObjMap) !Walk {
        const keys = try scope.array();
        try keys.items.ensureTotalCapacity(vm.gc.trackingAllocator(), map.count());
        var entries = map.entries();
        while (entries.next()) |entry| keys.items.appendAssumeCapacity(entry.key);
        return .{ .map = map, .keys = keys };
    }

    fn next(self: *Walk) ?struct { value.Value, value.Value } {
        while (self.at < self.keys.items.items.len) {
            const key = self.keys.items.items[self.at];
            self.at += 1;
            if (self.map.table.get(key)) |val| return .{ key, val };
        }
        return null;
    }
};

/// Map#each { |k, v| ... }
pub fn mapEach(vm: *VM, map: *value.ObjMap, closure: *value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    var walk = try Walk.init(vm, scope, map);
    while (walk.next()) |entry| {
        var held = HandleScope.init(vm);
        defer held.deinit();
        // Rooted: the block may delete the entry
        vm.push(entry[1]);
        switch (try callBlock(vm, closure, &.{ entry[0], entry[1] })) {
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

    const new_arr = try scope.array();

    try new_arr.items.ensureTotalCapacity(vm.gc.trackingAllocator(), map.count());

    var entries = map.entries();
    while (entries.next()) |entry| {
        const pair_arr = try scope.array();

        try pair_arr.items.ensureTotalCapacity(vm.gc.trackingAllocator(), 2);
        pair_arr.items.appendAssumeCapacity(entry.key);
        pair_arr.items.appendAssumeCapacity(entry.value);

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
    const new_arr = try scope.array();

    try new_arr.items.ensureTotalCapacity(vm.gc.trackingAllocator(), map.count());
    const closure = block_opt.?;

    var walk = try Walk.init(vm, scope, map);
    while (walk.next()) |entry| {
        var held = HandleScope.init(vm);
        defer held.deinit();
        vm.push(entry[1]);
        const mapped_val = switch (try callBlock(vm, closure, &.{ entry[0], entry[1] })) {
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
    return value.Value.initBool(map.count() == 0);
}

/// Map#get(key, default)
pub fn mapGet(vm: *VM, map: *value.ObjMap, key: value.Value, default_val: value.Value) !value.Value {
    _ = vm;
    return map.table.get(key) orelse default_val;
}

/// Map#merge(other_map)
pub fn mapMerge(vm: *VM, map: *value.ObjMap, other_map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const new_map = try scope.map();

    for ([_]*value.ObjMap{ map, other_map }) |source| {
        var entries = source.entries();
        while (entries.next()) |entry| try new_map.table.put(vm.gc.trackingAllocator(), entry.key, entry.value);
    }

    return value.Value.initObj(&new_map.obj);
}

/// Map#symbolize_keys
pub fn mapSymbolizeKeys(vm: *VM, map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const new_map = try scope.map();

    var entries = map.entries();
    while (entries.next()) |entry| {
        const k = entry.key;
        var new_k = k;
        if (k.isString()) {
            const str = k.asString();
            new_k = try vm.allocateSymbol(str.chars);
        }
        try new_map.table.put(vm.gc.trackingAllocator(), new_k, entry.value);
    }
    return value.Value.initObj(&new_map.obj);
}

/// Map#stringify_keys
pub fn mapStringifyKeys(vm: *VM, map: *value.ObjMap) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const new_map = try scope.map();

    var entries = map.entries();
    while (entries.next()) |entry| {
        const k = entry.key;
        var new_k = k;
        if (k.isSymbol()) {
            const sym = k.asSymbol();
            new_k = try vm.allocateString(sym.chars);
        }
        try new_map.table.put(vm.gc.trackingAllocator(), new_k, entry.value);
    }
    return value.Value.initObj(&new_map.obj);
}

/// Map#size / Map#length: how many entries it holds.
pub fn mapSize(vm: *VM, map: *value.ObjMap) !value.Value {
    _ = vm;
    return value.Value.initNumber(@floatFromInt(map.count()));
}

/// Map#fetch(key, default) -> the value under `key`; without one, `default` when it is
/// given (nil too), else a KeyError naming the key and the keys the Map has.
pub fn mapFetch(vm: *VM, map: *value.ObjMap, key: value.Value, default: []const value.Value) !value.Value {
    if (default.len > 1) return vm.fail(.ArgumentError, "fetch takes a key and at most one default, got {d} arguments", .{default.len + 1});
    if (map.table.get(key)) |held| return held;
    if (default.len > 0) return default[0];
    return vm.fail(.KeyError, "fetch: the Map has no key {s} ({s}{s})", .{ shown(vm, key), if (map.count() > 0) "its keys: " else "it has none", shownList(vm, map.entries()) });
}

/// Map#dig(key, *more) -> what the keys lead to, each a key into a Map (a String or a
/// Symbol into a JsonObject) or an integer into an Array (negative from the end): nil
/// where a step finds nothing, as Ruby's. A step into a value with no entries is a
/// TypeError. (JsonObject#dig raises at a missing key instead, naming where in its file.)
pub fn mapDig(vm: *VM, map: *value.ObjMap, first: value.Value, more: []const value.Value) !value.Value {
    var current = try digStep(vm, value.Value.initObj(&map.obj), first);
    for (more) |step| {
        if (current.isNil()) break;
        current = try digStep(vm, current, step);
    }
    return current;
}

fn digStep(vm: *VM, current: value.Value, step: value.Value) !value.Value {
    if (current.isMap()) return current.asMap().table.get(step) orelse value.Value.initNil();
    if (current.isJsonObject()) {
        const held = vm.jsonObjectGet(current.asJsonObject(), step) catch return vm.fail(.TypeError, "dig: " ++ error_kind.JSON_KEY_FMT, .{vm.typeName(step)});
        return held orelse value.Value.initNil();
    }
    if (current.isArray()) {
        if (!step.isNumber() or @trunc(step.asNumber()) != step.asNumber()) return vm.fail(.TypeError, "dig: an Array is indexed by an integer, got {s}", .{shown(vm, step)});
        const items = current.asArray().items.items;
        const index = vm.resolveArrayIndex(items.len, step) catch return value.Value.initNil();
        return items[index];
    }
    return vm.fail(.TypeError, "dig: {s} has no entries to find {s} in", .{ vm.typeName(current), shown(vm, step) });
}

/// `v` as `inspect` shows a built-in value (a script's `inspect` isn't called), in the
/// scratch arena, for an error's message.
fn shown(vm: *VM, v: value.Value) []const u8 {
    var out: std.Io.Writer.Allocating = .init(vm.scratch_arena.allocator());
    v.stringify(true, &out.writer) catch return "?";
    return out.written();
}

/// The keys of `entries` as `shown` writes them, as an error lists them ("a, b", "..." past
/// vm_mod.MAX_NAMES_LISTED).
fn shownList(vm: *VM, entries: value.Entries) []const u8 {
    var out: std.Io.Writer.Allocating = .init(vm.scratch_arena.allocator());
    var it = entries;
    var listed: usize = 0;
    while (it.next()) |entry| : (listed += 1) {
        if (listed == vm_mod.MAX_NAMES_LISTED) break;
        if (listed > 0) out.writer.writeAll(", ") catch return "";
        entry.key.stringify(true, &out.writer) catch return "";
    }
    if (entries.count > vm_mod.MAX_NAMES_LISTED) out.writer.writeAll(", ...") catch return "";
    return out.written();
}

/// Map#filter { |k, v| ... }: a new Map of the entries the block is truthy for.
pub fn mapFilter(vm: *VM, map: *value.ObjMap, closure: *value.ObjClosure) !value.Value {
    return keepEntries(vm, map, closure, true);
}

/// Map#reject { |k, v| ... }: a new Map of the entries the block is false or nil for.
pub fn mapReject(vm: *VM, map: *value.ObjMap, closure: *value.ObjClosure) !value.Value {
    return keepEntries(vm, map, closure, false);
}

fn keepEntries(vm: *VM, map: *value.ObjMap, closure: *value.ObjClosure, truthy: bool) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const kept = try scope.map();
    var walk = try Walk.init(vm, scope, map);
    while (walk.next()) |entry| {
        const key, const val = entry;
        // Rooted: the block may delete the entry
        var held = HandleScope.init(vm);
        defer held.deinit();
        vm.push(val);
        const res = switch (try callBlock(vm, closure, &.{ key, val })) {
            .broke => |v| return v,
            .value => |v| v,
        };
        if (res.isFalsey() != truthy) try kept.table.put(vm.gc.trackingAllocator(), key, val);
    }
    return value.Value.initObj(&kept.obj);
}

/// Map#transform_values { |v| ... }: a new Map of the same keys, each with what the block
/// gives for its value.
pub fn mapTransformValues(vm: *VM, map: *value.ObjMap, closure: *value.ObjClosure) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const out = try scope.map();
    var walk = try Walk.init(vm, scope, map);
    while (walk.next()) |entry| {
        const key, const val = entry;
        var held = HandleScope.init(vm);
        defer held.deinit();
        vm.push(val);
        const result = switch (try callBlock(vm, closure, &.{val})) {
            .broke => |v| return v,
            .value => |v| v,
        };
        vm.push(result);
        try out.table.put(vm.gc.trackingAllocator(), key, result);
    }
    return value.Value.initObj(&out.obj);
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
    .{ .name = "size", .func = common.wrapMethod(mapSize) },
    .{ .name = "length", .func = common.wrapMethod(mapSize) },
    .{ .name = "fetch", .func = common.wrapMethod(mapFetch) },
    .{ .name = "dig", .func = common.wrapMethod(mapDig) },
    .{ .name = "filter", .func = common.wrapMethod(mapFilter) },
    .{ .name = "reject", .func = common.wrapMethod(mapReject) },
    .{ .name = "transform_values", .func = common.wrapMethod(mapTransformValues) },
};
