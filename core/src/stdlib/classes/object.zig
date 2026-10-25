//! The methods every value has, bound on the root `Object` class by `registry.zig`: `class`,
//! `inspect`, `is_a?`, `respond_to?`, `nil?`, `empty?`, `method`, `tap`, `into`, `dup`/`clone`.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const common = @import("common.zig");
const arguments = @import("../arguments.zig");

/// Object#is_a?(Class) -> true if the receiver is an instance of the class or a subclass
fn objectIsA(vm: *VM, receiver: value.Value, class: *value.ObjClass) !value.Value {
    const own = vm.getClass(receiver) orelse return value.Value.initBool(false);
    return value.Value.initBool(VM.isSubclassOf(own, class));
}

/// Object#respond_to?(Symbol|String) -> true if the receiver has that method (or, for an
/// instance, that field)
fn objectRespondTo(vm: *VM, receiver: value.Value, name_val: value.Value) !value.Value {
    const query_name = try arguments.requireName(vm, name_val, "respond_to?", "the method name");
    const query_val = try vm.allocateString(query_name);

    if (receiver.isClass()) {
        if (vm.findClassMethodWithPrivacy(receiver.asClass(), query_val).method != null) return value.Value.initBool(true);
        return value.Value.initBool(std.mem.eql(u8, query_name, "new"));
    }
    if (classOrObject(vm, receiver)) |c| {
        if (vm.findMethodWithPrivacy(c, query_val, null).method != null) return value.Value.initBool(true);
    }
    if (receiver.isInstance()) {
        const field_name = if (query_name.len > 0 and query_name[0] == '@' and (query_name.len == 1 or query_name[1] != '@'))
            query_name[1..]
        else
            query_name;
        const field_val = try vm.allocateString(field_name);
        return value.Value.initBool(receiver.asInstance().class.instance_layout.contains(field_val));
    }
    return value.Value.initBool(false);
}

/// The class whose methods `receiver` answers: its own, or Object's for a value without one.
fn classOrObject(vm: *VM, receiver: value.Value) ?*value.ObjClass {
    return vm.getClass(receiver) orelse vm.object_class;
}

/// Object#nil?
fn objectNilQ(vm: *VM, receiver: value.Value) !value.Value {
    _ = vm;
    return value.Value.initBool(receiver.isNil());
}

/// Object#empty? -> nil, an empty String/Array/Map/JsonObject, a Solid with no volume or a
/// Sketch with no area (a sketch answered false whatever it held)
fn objectEmptyQ(vm: *VM, receiver: value.Value) !value.Value {
    if (receiver.isNil()) return value.Value.initBool(true);
    if (receiver.isString()) return value.Value.initBool(receiver.asString().chars.len == 0);
    if (receiver.isArray()) return value.Value.initBool(receiver.asArray().items.items.len == 0);
    if (receiver.isMap()) return value.Value.initBool(receiver.asMap().count() == 0);
    if (receiver.isJsonObject()) return value.Value.initBool(receiver.asJsonObject().map.count() == 0);
    if (receiver.isGeometry()) {
        const solid = try vm.ensureConcrete(receiver);
        try vm.requireFeature(solid.engine, .volume);
        return value.Value.initBool(kernel.volume(solid) == 0.0);
    }
    if (receiver.isCrossSection()) {
        const sketch = try vm.ensureConcreteCrossSection(receiver);
        try vm.requireFeature(sketch.engine, .sketch_measure);
        return value.Value.initBool(kernel.crossSectionArea(sketch) == 0.0);
    }
    return value.Value.initBool(false);
}

/// Object#tap { |obj| ... } -> yields the receiver to the block and returns the receiver
fn objectTap(vm: *VM, receiver: value.Value, block: ?*value.ObjClosure) !value.Value {
    if (block) |b| _ = try vm.callClosureSync(b, &.{receiver});
    return receiver;
}

/// Object#into { |obj| ... } -> yields the receiver to the block and returns the block's result
fn objectInto(vm: *VM, receiver: value.Value, block: ?*value.ObjClosure) !value.Value {
    const b = block orelse return receiver;
    return vm.callClosureSync(b, &.{receiver});
}

/// Object#method(:name) -> the method bound to the receiver, called with `.call`
fn objectMethod(vm: *VM, receiver: value.Value, name_val: value.Value) !value.Value {
    const method_name = try arguments.requireName(vm, name_val, "method", "the method name");
    const query_val = try vm.allocateString(method_name);
    const class = classOrObject(vm, receiver);
    const method_val = (if (class) |c| vm.findMethod(c, query_val) else null) orelse {
        return vm.fail(.NameError, "undefined method '{s}' for {s}", .{ method_name, arguments.typeName(vm, receiver) });
    };
    const bound = try vm.gc.allocateBoundMethod(vm, receiver, method_val);
    return value.Value.initObj(&bound.obj);
}

/// Object#dup / Object#clone -> values are immutable or shared, so the receiver itself
/// Object#dup / #clone -> a shallow copy of an Array, Map or instance: its own elements,
/// entries or fields, holding the same values. Everything else is immutable (or a
/// handle, like a Solid) and is returned as it is. It used to return the receiver
/// itself, so `copy = parts.dup; copy.push(x)` changed `parts`.
fn objectDup(vm: *VM, receiver: value.Value) !value.Value {
    if (receiver.isArray()) {
        const copy = try vm.gc.allocateArray(vm);
        vm.push(value.Value.initObj(&copy.obj)); // rooted while its storage is allocated
        defer _ = vm.pop();
        try copy.items.appendSlice(vm.gc.trackingAllocator(), receiver.asArray().items.items);
        return value.Value.initObj(&copy.obj);
    }
    if (receiver.isMap()) {
        const copy = try vm.gc.allocateMap(vm);
        vm.push(value.Value.initObj(&copy.obj));
        defer _ = vm.pop();
        copy.table = try receiver.asMap().table.clone(vm.gc.trackingAllocator());
        copy.deleted = receiver.asMap().deleted;
        return value.Value.initObj(&copy.obj);
    }
    if (receiver.isInstance()) {
        const source = receiver.asInstance();
        const copy = try vm.gc.allocateInstance(vm, source.class);
        vm.push(value.Value.initObj(&copy.obj));
        defer _ = vm.pop();
        try copy.fields.appendSlice(vm.gc.trackingAllocator(), source.fields.items);
        return value.Value.initObj(&copy.obj);
    }
    return receiver;
}

/// Object#class -> the receiver's class, or nil for a value that has none (nil, a lambda)
fn objectClass(vm: *VM, receiver: value.Value) !value.Value {
    const class = vm.getClass(receiver) orelse return value.Value.initNil();
    return value.Value.initObj(&class.obj);
}

/// Object#inspect -> the receiver as it would be written in a script: Strings quoted,
/// Symbols with their colon (`puts` and interpolation print Strings bare).
fn objectInspect(vm: *VM, receiver: value.Value) !value.Value {
    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();
    try receiver.stringify(true, &out.writer);
    return vm.allocateString(out.written());
}

pub const methods = [_]common.MethodDef{
    .{ .name = "class", .func = common.wrapMethod(objectClass) },
    .{ .name = "inspect", .func = common.wrapMethod(objectInspect) },
    .{ .name = "is_a?", .func = common.wrapMethod(objectIsA) },
    .{ .name = "respond_to?", .func = common.wrapMethod(objectRespondTo) },
    .{ .name = "nil?", .func = common.wrapMethod(objectNilQ) },
    .{ .name = "empty?", .func = common.wrapMethod(objectEmptyQ) },
    .{ .name = "method", .func = common.wrapMethod(objectMethod) },
    .{ .name = "tap", .func = common.wrapMethod(objectTap) },
    .{ .name = "into", .func = common.wrapMethod(objectInto) },
    .{ .name = "dup", .func = common.wrapMethod(objectDup) },
    .{ .name = "clone", .func = common.wrapMethod(objectDup) },
};
