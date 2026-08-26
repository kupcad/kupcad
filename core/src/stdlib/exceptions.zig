const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const common = @import("classes/common.zig");

// --- Native Methods ---

// Default initializer for Exception.new("message")
pub fn exceptionInit(vm: *VM, receiver: value.Value, message_opt: ?value.Value) !value.Value {
    std.debug.assert(receiver.isInstance());
    const instance = receiver.asInstance();

    const msg = message_opt orelse try vm.allocateString(instance.class.name.chars);
    try vm.setInstanceField(instance, "message", msg, null);

    // --- EAGER BACKTRACE CAPTURE ---
    if (vm.buildBacktrace()) |bt_arr| {
        try vm.setInstanceField(instance, "backtrace", value.Value.initObj(&bt_arr.obj), null);
    } else |_| {}

    return receiver;
}

// e.message()
pub fn exceptionMessage(vm: *VM, receiver: value.Value) !value.Value {
    const instance = receiver.asInstance();

    if (instance.class.instance_layout.get("message")) |idx| {
        if (idx < instance.fields.items.len) {
            return instance.fields.items[idx];
        }
    }
    // Fallback to the class name if no message was set
    return try vm.allocateString(instance.class.name.chars);
}

// e.backtrace()
pub fn exceptionBacktrace(vm: *VM, receiver: value.Value) !value.Value {
    const instance = receiver.asInstance();

    // Pull the pre-calculated backtrace!
    if (instance.class.instance_layout.get("backtrace")) |idx| {
        if (idx < instance.fields.items.len) {
            return instance.fields.items[idx];
        }
    }

    // Fallback to empty array if something went wrong during capture
    const arr_obj = try vm.gc.allocateArray(vm);
    return value.Value.initObj(&arr_obj.obj);
}

// --- Bootstrap Hierarchy ---

pub fn registerExceptions(vm: *VM) !void {
    // Base Exception
    const exc_name = try vm.allocateStringTakeOwnership(try vm.allocator.dupe(u8, "Exception"));
    vm.push(exc_name);

    const exc_class = try vm.gc.allocateClass(vm, @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", exc_name.asObj()))), vm.object_class);

    try vm.globals.put(vm.allocator, "Exception", value.Value.initObj(&exc_class.obj));
    _ = vm.pop();

    const init_fn = try vm.gc.allocateNative(vm, common.wrapMethod(exceptionInit));
    try exc_class.methods.put(vm.allocator, "initialize", value.Value.initObj(&init_fn.obj));

    const msg_fn = try vm.gc.allocateNative(vm, common.wrapMethod(exceptionMessage));
    try exc_class.methods.put(vm.allocator, "message", value.Value.initObj(&msg_fn.obj));
    try exc_class.methods.put(vm.allocator, "to_s", value.Value.initObj(&msg_fn.obj));

    const bt_fn = try vm.gc.allocateNative(vm, common.wrapMethod(exceptionBacktrace));
    try exc_class.methods.put(vm.allocator, "backtrace", value.Value.initObj(&bt_fn.obj));

    // StandardError < Exception
    const std_name = try vm.allocateStringTakeOwnership(try vm.allocator.dupe(u8, "StandardError"));
    vm.push(std_name);
    const std_class = try vm.gc.allocateClass(vm, @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", std_name.asObj()))), exc_class);
    try vm.globals.put(vm.allocator, "StandardError", value.Value.initObj(&std_class.obj));
    _ = vm.pop();

    // Common Ruby-like Subclasses
    const error_types = [_][]const u8{
        "ArgumentError",
        "TypeError",
        "RuntimeError",
        "IndexError",
        "ZeroDivisionError",
        "AssertionError",
    };

    for (error_types) |err_name| {
        const name_val = try vm.allocateStringTakeOwnership(try vm.allocator.dupe(u8, err_name));
        vm.push(name_val);
        const err_class = try vm.gc.allocateClass(vm, @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))), std_class);
        try vm.globals.put(vm.allocator, err_name, value.Value.initObj(&err_class.obj));
        _ = vm.pop();
    }
}
