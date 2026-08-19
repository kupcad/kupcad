const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const common = @import("common.zig");

/// Object#nil? -> Returns true if receiver is NilClass, false otherwise
pub fn nativeNilQ(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm_opaque;
    _ = arg_count;
    const receiver = (args - 1)[0];
    return value.Value.initBool(receiver.isNil());
}

/// Object#empty? -> Checks length of collections/strings or volume of 3D geometry
pub fn nativeEmptyQ(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = arg_count;
    const self_val = (args - 1)[0];

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
    const receiver = (args - 1)[0];

    if (arg_count > 0 and args[arg_count - 1].isClosure()) {
        const block_closure = args[arg_count - 1].asClosure();

        // Execute block and capture its result
        const yield_res = try vm.callClosureSync(block_closure, &.{receiver});

        // Safely discard the block's return value to prevent memory leaks
        vm.releaseValue(yield_res);
    }

    // Retain receiver before returning to counteract op_invoke's stack cleanup
    vm.retainValue(receiver);
    return receiver;
}

/// Object#into { |obj| ... } -> Yields receiver to block, returns block result
pub fn nativeInto(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];

    if (arg_count > 0 and args[arg_count - 1].isClosure()) {
        const block_closure = args[arg_count - 1].asClosure();
        // Return the evaluated block's result directly (it already has the correct ref count)
        return try vm.callClosureSync(block_closure, &.{receiver});
    }

    // If no block is provided, it acts as an identity function. Must retain!
    vm.retainValue(receiver);
    return receiver;
}

/// Object#dup / Object#clone -> Duplicates primitive or increments ARC on geometry
pub fn nativeDup(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = arg_count;
    const receiver = (args - 1)[0];

    vm.retainValue(receiver);
    return receiver;
}

pub const methods = [_]common.MethodDef{
    .{ .name = "nil?", .func = nativeNilQ },
    .{ .name = "empty?", .func = nativeEmptyQ },
    .{ .name = "tap", .func = nativeTap },
    .{ .name = "into", .func = nativeInto },
    .{ .name = "dup", .func = nativeDup },
    .{ .name = "clone", .func = nativeDup },
};
