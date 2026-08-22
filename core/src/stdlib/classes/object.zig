const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const common = @import("common.zig");

/// Object#is_a?(Class) -> Returns true if receiver is an instance of the class or its subclasses
pub fn nativeIsA(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);

    const has_block = arg_count > 0 and args[arg_count - 1].isClosure();
    const pos_args = if (has_block) arg_count - 1 else arg_count;

    if (pos_args != 1) {
        vm.runtimeError("Runtime Error: is_a? expects exactly 1 argument.\n", .{});
        return error.RuntimeError;
    }

    const target_val = args[0];
    if (!target_val.isClass()) {
        vm.runtimeError("Runtime Error: is_a? expects a Class as its argument.\n", .{});
        return error.RuntimeError;
    }

    var match = false;

    // DRY: Use the centralized class resolver on the VM
    if (vm.getClass(receiver)) |start_class| {
        match = VM.isSubclassOf(start_class, target_val.asClass());
    }

    return value.Value.initBool(match);
}

/// Object#responds_to?(Symbol|String) -> Returns true if receiver can invoke the method
pub fn nativeRespondsTo(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);

    const has_block = arg_count > 0 and args[arg_count - 1].isClosure();
    const pos_args = if (has_block) arg_count - 1 else arg_count;

    if (pos_args != 1) {
        vm.runtimeError("Runtime Error: responds_to? expects exactly 1 argument.\n", .{});
        return error.RuntimeError;
    }

    const target_val = args[0];
    const query_name = if (target_val.isObject() and target_val.asObj().obj_type == .symbol)
        @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", target_val.asObj()))).chars
    else if (target_val.isObject() and target_val.asObj().obj_type == .string)
        @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", target_val.asObj()))).chars
    else {
        vm.runtimeError("Runtime Error: responds_to? expects a Symbol or String.\n", .{});
        return error.RuntimeError;
    };

    var match = false;
    if (receiver.isClass()) {
        if (vm.findClassMethod(receiver.asClass(), query_name) != null) match = true;
        if (!match and std.mem.eql(u8, query_name, "new")) match = true;
    } else if (vm.getClass(receiver)) |c| {
        if (vm.findMethod(c, query_name) != null) match = true;
    }

    // Check if the query refers to an instance variable auto-getter (if implemented later)
    if (!match and receiver.isInstance()) {
        const clean_name = if (query_name.len > 0 and query_name[0] == '@' and (query_name.len == 1 or query_name[1] != '@'))
            query_name[1..]
        else
            query_name;
        if (receiver.asInstance().class.instance_layout.contains(clean_name)) match = true;
    }

    return value.Value.initBool(match);
}

/// Object#nil? -> Returns true if receiver is NilClass, false otherwise
pub fn nativeNilQ(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    return value.Value.initBool(receiver.isNil());
}

/// Object#empty? -> Checks length of collections/strings or volume of 3D geometry
pub fn nativeEmptyQ(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const self_val = vm.getReceiver(args);

    if (self_val.isNil()) return value.Value.initBool(true);

    if (self_val.isObject()) {
        const obj = self_val.asObj();
        switch (obj.obj_type) {
            .string => {
                const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", obj)));
                return value.Value.initBool(str.chars.len == 0);
            },
            .array => {
                const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", obj)));
                return value.Value.initBool(arr.items.items.len == 0);
            },
            .map => {
                const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", obj)));
                return value.Value.initBool(map.keys.items.len == 0);
            },
            else => {},
        }
    }

    if (self_val.isGeometry()) {
        const handle = try vm.ensureConcrete(self_val);
        const vol = kernel.volume(handle);
        return value.Value.initBool(vol == 0.0);
    }
    return value.Value.initBool(false);
}

/// Object#tap { |obj| ... } -> Yields receiver to block, discards block result, returns receiver
pub fn nativeTap(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);

    if (arg_count > 0 and args[arg_count - 1].isClosure()) {
        const block_closure = args[arg_count - 1].asClosure();
        // Execute block and capture its result
        _ = try vm.callClosureSync(block_closure, &.{receiver});
    }
    return receiver;
}

/// Object#into { |obj| ... } -> Yields receiver to block, returns block result
pub fn nativeInto(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);

    if (arg_count > 0 and args[arg_count - 1].isClosure()) {
        const block_closure = args[arg_count - 1].asClosure();
        // Return the evaluated block's result directly (it already has the correct ref count)
        return try vm.callClosureSync(block_closure, &.{receiver});
    }
    return receiver;
}

/// Object#dup / Object#clone -> Duplicates primitive or increments ARC on geometry
pub fn nativeDup(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = vm.getReceiver(args);
    return receiver;
}

pub const methods = [_]common.MethodDef{
    .{ .name = "is_a?", .func = nativeIsA },
    .{ .name = "responds_to?", .func = nativeRespondsTo },
    .{ .name = "nil?", .func = nativeNilQ },
    .{ .name = "empty?", .func = nativeEmptyQ },
    .{ .name = "tap", .func = nativeTap },
    .{ .name = "into", .func = nativeInto },
    .{ .name = "dup", .func = nativeDup },
    .{ .name = "clone", .func = nativeDup },
};
