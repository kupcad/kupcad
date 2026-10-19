//! The JsonObject class's methods. A JsonObject is a JSON object `import_json` read: read-only,
//! its keys Strings as the file has them, each found by that String or by the Symbol of the
//! same name. `[]` gives nil for a key it doesn't have, as a Map's does; `fetch` and `dig`
//! raise an error naming where in the file the key is missing, and `to_h` gives a Map of it
//! that a script can change. Also `Path` and `Where`, which import_json (stdlib/json.zig)
//! words its errors with too.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const HandleScope = @import("../../vm/scope.zig").HandleScope;
const JSON_KEY_FMT = @import("../../vm/error_kind.zig").JSON_KEY_FMT;
const MAX_JSON_DEPTH = @import("../../core/limits.zig").MAX_JSON_DEPTH;
const common = @import("common.zig");
const callBlock = @import("iteration.zig").callBlock;

/// Keys a KeyError lists of the object it looked in, before "...".
const MAX_KEYS_LISTED = 8;

/// Where a value is in its file, built a step at a time: `gears[0].teeth`.
pub const Path = struct {
    text: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Path, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
    }

    /// Steps into the entry `key`; returns the mark to `leave` back to.
    pub fn enterKey(self: *Path, allocator: std.mem.Allocator, key: []const u8) !usize {
        const mark = self.text.items.len;
        if (mark > 0) try self.text.append(allocator, '.');
        try self.text.appendSlice(allocator, key);
        return mark;
    }

    /// Steps into the element `index`; returns the mark to `leave` back to.
    pub fn enterIndex(self: *Path, allocator: std.mem.Allocator, index: usize) !usize {
        const mark = self.text.items.len;
        try self.text.print(allocator, "[{d}]", .{index});
        return mark;
    }

    pub fn leave(self: *Path, mark: usize) void {
        self.text.shrinkRetainingCapacity(mark);
    }
};

/// A place in a file, for an error: `machine.json` for the whole file, `machine.json:
/// gears[0]` inside it.
pub const Where = struct {
    source: []const u8,
    path: []const u8,

    pub fn of(object: *const value.ObjJsonObject) Where {
        return .{ .source = object.source.chars, .path = object.path.chars };
    }

    pub fn format(self: Where, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.source);
        if (self.path.len > 0) try writer.print(": {s}", .{self.path});
    }
};

/// What `object` holds under `key` (see VM.jsonObjectGet), or null; a key that is neither a
/// String nor a Symbol is a TypeError.
fn lookup(vm: *VM, object: *value.ObjJsonObject, key: value.Value) !?value.Value {
    return vm.jsonObjectGet(object, key) catch vm.fail(.TypeError, JSON_KEY_FMT, .{vm.typeName(key)});
}

/// The name of a key lookup accepted: a String's or a Symbol's.
fn keyName(key: value.Value) []const u8 {
    return if (key.isString()) key.asString().chars else key.asSymbol().chars;
}

/// The KeyError for `key`, which `object` at `where` doesn't have: it names the keys it has.
fn missingKey(vm: *VM, object: *const value.ObjJsonObject, key: value.Value, where: Where) error{ RuntimeError, OutOfMemory } {
    var keys: std.ArrayList(u8) = .empty;
    defer keys.deinit(vm.allocator);
    const names = object.map.keys();
    if (names.len == 0) {
        try keys.appendSlice(vm.allocator, "it has none");
    } else {
        try keys.appendSlice(vm.allocator, "its keys: ");
        for (names[0..@min(names.len, MAX_KEYS_LISTED)], 0..) |name, i| {
            try keys.print(vm.allocator, "{s}{s}", .{ if (i > 0) ", " else "", name.asString().chars });
        }
        if (names.len > MAX_KEYS_LISTED) try keys.appendSlice(vm.allocator, ", ...");
    }
    return vm.fail(.KeyError, "{f} has no key \"{s}\" ({s})", .{ where, keyName(key), keys.items });
}

/// JsonObject#fetch(key, default) -> the value under `key`; without one, `default` when it
/// is given (nil too), else a KeyError naming the key, where the object is and its keys.
pub fn jsonFetch(vm: *VM, object: *value.ObjJsonObject, key: value.Value, default: []const value.Value) !value.Value {
    if (try lookup(vm, object, key)) |held| return held;
    if (default.len > 0) return default[0];
    return missingKey(vm, object, key, .of(object));
}

/// JsonObject#dig(key, *more) -> what the keys lead to, each a String or a Symbol into a
/// JsonObject or an integer into an Array (negative from the end): `machine.dig(:gears,
/// 0, :teeth)`. Where a step finds nothing it raises, naming the place in the file: a
/// KeyError for a missing key, an IndexError past an Array's end, a TypeError for a step
/// into a value with no entries. (Ruby's dig gives nil instead, which surfaces later as an
/// error about nil, far from the file.)
pub fn jsonDig(vm: *VM, object: *value.ObjJsonObject, first: value.Value, more: []const value.Value) !value.Value {
    var path: Path = .{};
    defer path.deinit(vm.allocator);
    try path.text.appendSlice(vm.allocator, object.path.chars);
    var current = try digStep(vm, value.Value.initObj(&object.obj), first, object.source.chars, &path);
    for (more) |step| current = try digStep(vm, current, step, object.source.chars, &path);
    return current;
}

/// One step of `dig` from `current`, which is at `path` in `source`; the path then names
/// what it returns.
fn digStep(vm: *VM, current: value.Value, step: value.Value, source: []const u8, path: *Path) !value.Value {
    const here: Where = .{ .source = source, .path = path.text.items };
    if (current.isJsonObject()) {
        const object = current.asJsonObject();
        const held = try lookup(vm, object, step) orelse return missingKey(vm, object, step, here);
        _ = try path.enterKey(vm.allocator, keyName(step));
        return held;
    }
    if (current.isArray()) {
        const items = current.asArray().items.items;
        if (!step.isNumber()) return vm.fail(.TypeError, "dig: {f} is an Array, indexed by an integer, got {s}", .{ here, vm.typeName(step) });
        const index = vm.resolveArrayIndex(items.len, step) catch {
            return vm.fail(.IndexError, "dig: {f} has no element {f} (size {d})", .{ here, value.fmtNumber(step.asNumber()), items.len });
        };
        _ = try path.enterIndex(vm.allocator, index);
        return items[index];
    }
    return vm.fail(.TypeError, "dig: {f} is a {s} value, not a JsonObject or an Array", .{ here, vm.typeName(current) });
}

/// JsonObject#key?(key)
pub fn jsonKey(vm: *VM, object: *value.ObjJsonObject, key: value.Value) !value.Value {
    return value.Value.initBool(try lookup(vm, object, key) != null);
}

/// JsonObject#keys -> its keys, Strings in the file's order
pub fn jsonKeys(vm: *VM, object: *value.ObjJsonObject) !value.Value {
    return value.Value.initObj(&(try vm.gc.allocateArrayOf(vm, object.map.keys())).obj);
}

/// JsonObject#values
pub fn jsonValues(vm: *VM, object: *value.ObjJsonObject) !value.Value {
    return value.Value.initObj(&(try vm.gc.allocateArrayOf(vm, object.map.values())).obj);
}

/// JsonObject#size -> how many keys it has
pub fn jsonSize(vm: *VM, object: *value.ObjJsonObject) !value.Value {
    _ = vm;
    return value.Value.initNumber(@floatFromInt(object.map.count()));
}

/// JsonObject#each { |key, value| ... } -> the object, or the value of a `break`
pub fn jsonEach(vm: *VM, object: *value.ObjJsonObject, block: *value.ObjClosure) !value.Value {
    // Read-only: the block can't move the entries, as it can a Map's
    for (object.map.keys(), object.map.values()) |k, v| {
        switch (try callBlock(vm, block, &.{ k, v })) {
            .broke => |result| return result,
            .value => {},
        }
    }
    return value.Value.initObj(&object.obj);
}

/// JsonObject#to_h -> a Map of its entries that a script can change: its objects Maps and
/// its Arrays copies, all the way down, so changing it changes nothing the file gave.
pub fn jsonToH(vm: *VM, object: *value.ObjJsonObject) !value.Value {
    try vm.ensureStackCapacity(vm.stack_top + MAX_JSON_DEPTH);
    return plainCopy(vm, value.Value.initObj(&object.obj), MAX_JSON_DEPTH);
}

/// `v` with each JsonObject in it a Map and each Array a copy. An Array a script made
/// hold itself would nest forever: past `depth` levels it is a ValueError. Each level keeps
/// its copy rooted with a HandleScope, not a pop: an error raised below has already
/// unwound the stack.
fn plainCopy(vm: *VM, v: value.Value, depth: usize) !value.Value {
    if (!v.isJsonObject() and !v.isArray()) return v;
    if (depth == 0) return vm.fail(.ValueError, "to_h: the data nests deeper than {d} levels (an Array holding itself?)", .{MAX_JSON_DEPTH});
    const tracking = vm.gc.trackingAllocator();
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    if (v.isArray()) {
        const items = v.asArray().items.items;
        const copy = try vm.gc.allocateArray(vm);
        vm.push(value.Value.initObj(&copy.obj));
        try copy.items.ensureTotalCapacity(tracking, items.len);
        for (items) |item| copy.items.appendAssumeCapacity(try plainCopy(vm, item, depth - 1));
        return value.Value.initObj(&copy.obj);
    }
    const entries = &v.asJsonObject().map;
    const copy = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&copy.obj));
    try copy.map.ensureTotalCapacity(tracking, entries.count());
    for (entries.keys(), entries.values()) |k, item| copy.map.putAssumeCapacity(k, try plainCopy(vm, item, depth - 1));
    return value.Value.initObj(&copy.obj);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "fetch", .func = common.wrapMethodWith(jsonFetch, .{ .positional = &.{ "key", "default" } }) },
    .{ .name = "dig", .func = common.wrapMethod(jsonDig) },
    .{ .name = "key?", .func = common.wrapMethod(jsonKey) },
    .{ .name = "keys", .func = common.wrapMethod(jsonKeys) },
    .{ .name = "values", .func = common.wrapMethod(jsonValues) },
    .{ .name = "size", .func = common.wrapMethod(jsonSize) },
    .{ .name = "length", .func = common.wrapMethod(jsonSize) },
    .{ .name = "each", .func = common.wrapMethod(jsonEach) },
    .{ .name = "to_h", .func = common.wrapMethod(jsonToH) },
};
