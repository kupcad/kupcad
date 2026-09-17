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
    const msg_key = try vm.allocateString("message");
    try vm.setInstanceField(instance, msg_key, msg, null);

    // --- EAGER BACKTRACE CAPTURE ---
    if (vm.buildBacktrace()) |bt_arr| {
        const bt_key = try vm.allocateString("backtrace");
        try vm.setInstanceField(instance, bt_key, value.Value.initObj(&bt_arr.obj), null);
    } else |_| {}

    return receiver;
}

// e.message()
pub fn exceptionMessage(vm: *VM, receiver: value.Value) !value.Value {
    const instance = receiver.asInstance();
    const msg_key = try vm.allocateString("message");

    if (instance.class.instance_layout.get(msg_key)) |idx| {
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
    const bt_key = try vm.allocateString("backtrace");

    // Pull the pre-calculated backtrace!
    if (instance.class.instance_layout.get(bt_key)) |idx| {
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
    // Use allocateString directly, which internally uses the trackingAllocator!
    const exc_name = try vm.allocateString("Exception");
    vm.push(exc_name);

    const exc_class = try vm.gc.allocateClass(vm, @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", exc_name.asObj()))), vm.object_class);

    // Note: vm.globals.put safely stays vm.allocator because globals are tied to VM lifetime, not sandbox GC
    try vm.globals.put(vm.allocator, "Exception", value.Value.initObj(&exc_class.obj));
    _ = vm.pop();

    const init_fn = try vm.gc.allocateNative(vm, common.wrapMethod(exceptionInit));
    const init_key = try vm.allocateString("initialize");
    try exc_class.methods.put(vm.gc.trackingAllocator(), init_key, value.Value.initObj(&init_fn.obj));

    const msg_fn = try vm.gc.allocateNative(vm, common.wrapMethod(exceptionMessage));
    const msg_key = try vm.allocateString("message");
    const tos_key = try vm.allocateString("to_s");
    try exc_class.methods.put(vm.gc.trackingAllocator(), msg_key, value.Value.initObj(&msg_fn.obj));
    try exc_class.methods.put(vm.gc.trackingAllocator(), tos_key, value.Value.initObj(&msg_fn.obj));

    const bt_fn = try vm.gc.allocateNative(vm, common.wrapMethod(exceptionBacktrace));
    const bt_key = try vm.allocateString("backtrace");
    try exc_class.methods.put(vm.gc.trackingAllocator(), bt_key, value.Value.initObj(&bt_fn.obj));

    // StandardError < Exception
    const std_name = try vm.allocateString("StandardError");
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
        // Use allocateString directly to ensure trackingAllocator is used
        const name_val = try vm.allocateString(err_name);
        vm.push(name_val);
        const err_class = try vm.gc.allocateClass(vm, @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))), std_class);
        try vm.globals.put(vm.allocator, err_name, value.Value.initObj(&err_class.obj));
        _ = vm.pop();
    }
}
