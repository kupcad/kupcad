//! `import_json(path)`, which `import name from "./file.json"` calls too: a JSON file read as
//! data. An object becomes a JsonObject (classes/json_object.zig), an array an Array, a
//! number a Number, a string a String, true and false Booleans and null nil. The JSON is
//! read as the project config and a `-P` file are (core/json_input.zig).

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const HandleScope = @import("../vm/scope.zig").HandleScope;
const json_input = @import("../core/json_input.zig");
const json_object = @import("classes/json_object.zig");
const limits = @import("../core/limits.zig");

/// Stack slots one level of nesting holds while it is read: an object's path, the object
/// and the key of the entry being read.
const SLOTS_PER_LEVEL = 3;

/// import_json(path, keys = nil) -> the file's value. A file that can't be read, is larger
/// than limits.MAX_JSON_BYTES, isn't JSON, nests deeper than limits.MAX_JSON_DEPTH or holds
/// a number past the largest is an ImportError naming the file (and the line and column,
/// or the place in the data). With `keys` (Strings or Symbols), the values its object holds
/// under them, in order, as an Array: what `import { gears, frame } from "./machine.json"`
/// reads. A file that isn't an object is an ImportError, a key it doesn't have a KeyError.
pub fn nativeImportJson(vm: *VM, path: []const u8, keys: ?*value.ObjArray) !value.Value {
    const text = vm.readScriptFile(path) catch |err| {
        if (err == error.OutOfMemory) return err;
        return vm.fail(.ImportError, "could not read JSON file '{s}': {s}", .{ path, @errorName(err) });
    };
    defer vm.allocator.free(text);
    if (text.len > limits.MAX_JSON_BYTES) {
        return vm.fail(.ImportError, "JSON file '{s}' is {d} bytes; a script reads at most {d}", .{ path, text.len, limits.MAX_JSON_BYTES });
    }

    var at: json_input.Position = undefined;
    const parsed = json_input.parse(std.json.Value, vm.allocator, text, &at) catch |err| {
        const what = json_input.describeSyntaxError(err) orelse return err;
        return vm.fail(.ImportError, "{s}: line {d}, column {d}: {s}", .{ path, at.line, at.column, what });
    };
    defer parsed.deinit();

    var scope = HandleScope.init(vm);
    defer scope.deinit();
    try vm.ensureStackCapacity(vm.stack_top + 1 + SLOTS_PER_LEVEL * limits.MAX_JSON_DEPTH);
    const source = try vm.gc.allocateString(vm, path);
    vm.push(value.Value.initObj(&source.obj));
    var reader: Reader = .{ .vm = vm, .source = source };
    defer reader.path.deinit(vm.allocator);
    const read = try reader.convert(parsed.value, limits.MAX_JSON_DEPTH);
    const names = keys orelse return read;
    vm.push(read);
    return valuesOf(vm, path, read, names.items.items);
}

/// The values `read`, the data of the file at `path`, holds under `keys`, as an Array.
fn valuesOf(vm: *VM, path: []const u8, read: value.Value, keys: []const value.Value) !value.Value {
    if (!read.isJsonObject()) {
        const kind = vm.typeName(read);
        return vm.fail(.ImportError, "{s} is {s} {s} value, not an object: it has no keys to take", .{ path, json_object.article(kind), kind });
    }
    const object = read.asJsonObject();
    const values = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&values.obj));
    try values.items.ensureTotalCapacity(vm.gc.trackingAllocator(), keys.len);
    for (keys) |key| {
        const held = try json_object.lookup(vm, object, key) orelse return json_object.missingKey(vm, object, key, .of(object));
        values.items.appendAssumeCapacity(held);
    }
    return value.Value.initObj(&values.obj);
}

/// Turns parsed JSON into the script's values, keeping each container it builds rooted on
/// the VM stack until its parent holds it. Each level restores the stack top with a
/// HandleScope, not a pop: an error raised below has already unwound the stack.
const Reader = struct {
    vm: *VM,
    /// The file, which every JsonObject names in its errors.
    source: *value.ObjString,
    /// Where the value being read is.
    path: json_object.Path = .{},

    /// `v`, with at most `depth` levels of objects and arrays.
    fn convert(self: *Reader, v: std.json.Value, depth: usize) error{ RuntimeError, OutOfMemory }!value.Value {
        return switch (v) {
            .null => value.Value.initNil(),
            .bool => |b| value.Value.initBool(b),
            .integer => |n| value.Value.initNumber(@floatFromInt(n)),
            .float => |f| self.number(f),
            // Digits too many for an i64; past 1.8e308 they are no number a script holds
            .number_string => |s| self.number(std.fmt.parseFloat(f64, s) catch std.math.inf(f64)),
            .string => |s| try self.vm.allocateString(s),
            .array => |a| self.array(a.items, depth),
            .object => |o| self.object(&o, depth),
        };
    }

    fn here(self: *const Reader) json_object.Where {
        return .{ .source = self.source.chars, .path = self.path.text.items };
    }

    fn number(self: *Reader, f: f64) !value.Value {
        if (!std.math.isFinite(f)) return self.vm.fail(.ImportError, "{f} is a number past the largest (1.8e308)", .{self.here()});
        return value.Value.initNumber(f);
    }

    fn tooDeep(self: *Reader) error{RuntimeError} {
        return self.vm.fail(.ImportError, "{f} nests deeper than {d} levels", .{ self.here(), limits.MAX_JSON_DEPTH });
    }

    fn array(self: *Reader, items: []const std.json.Value, depth: usize) !value.Value {
        if (depth == 0) return self.tooDeep();
        const vm = self.vm;
        var scope = HandleScope.init(vm);
        defer scope.deinit();
        const arr = try vm.gc.allocateArray(vm);
        vm.push(value.Value.initObj(&arr.obj));
        try arr.items.ensureTotalCapacity(vm.gc.trackingAllocator(), items.len);
        for (items, 0..) |item, i| {
            const mark = try self.path.enterIndex(vm.allocator, i);
            arr.items.appendAssumeCapacity(try self.convert(item, depth - 1));
            self.path.leave(mark);
        }
        return value.Value.initObj(&arr.obj);
    }

    fn object(self: *Reader, entries: *const std.json.ObjectMap, depth: usize) !value.Value {
        if (depth == 0) return self.tooDeep();
        const vm = self.vm;
        var scope = HandleScope.init(vm);
        defer scope.deinit();
        const path = try vm.gc.allocateString(vm, self.path.text.items);
        vm.push(value.Value.initObj(&path.obj));
        const obj = try vm.gc.allocateJsonObject(vm, self.source, path);
        vm.push(value.Value.initObj(&obj.obj));
        try obj.map.ensureTotalCapacity(vm.gc.trackingAllocator(), entries.count());
        for (entries.keys(), entries.values()) |key, item| {
            var entry_scope = HandleScope.init(vm);
            defer entry_scope.deinit();
            const name = try vm.allocateString(key);
            vm.push(name);
            const mark = try self.path.enterKey(vm.allocator, key);
            obj.map.putAssumeCapacity(name, try self.convert(item, depth - 1));
            self.path.leave(mark);
        }
        return value.Value.initObj(&obj.obj);
    }
};
