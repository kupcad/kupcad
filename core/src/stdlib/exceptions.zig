const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");

// --- Native Methods ---

// Default initializer for Exception.new("message")
fn exceptionInit(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0]; // Safely step back 1 slot to get the Receiver

    std.debug.assert(receiver.isInstance());

    const instance = receiver.asInstance();

    var msg = value.Value.initNil();
    if (arg_count > 0) {
        msg = args[0]; // First argument
    } else {
        msg = try vm.allocateString(instance.class.name.chars);
    }

    try vm.setInstanceField(instance, "message", msg);
    return receiver;
}

// e.message()
fn exceptionMessage(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = arg_count;
    const receiver = (args - 1)[0]; // Safely step back 1 slot to get the Receiver
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
fn exceptionBacktrace(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = arg_count;
    _ = args;
    const arr_obj = try vm.gc.allocateArray(vm);
    return value.Value.initObj(&arr_obj.obj);
}

// --- Bootstrap Hierarchy ---

pub fn registerExceptions(vm: *VM) !void {
    // Base Exception
    const exc_name = try vm.allocateStringTakeOwnership(try vm.allocator.dupe(u8, "Exception"));
    vm.push(exc_name);

    const exc_class = try vm.gc.allocateClass(vm, @as(*value.ObjString, @ptrCast(exc_name.asObj())), vm.object_class);

    try vm.globals.put(vm.allocator, "Exception", value.Value.initObj(&exc_class.obj));
    _ = vm.pop();

    const init_fn = try vm.gc.allocateNative(vm, exceptionInit);
    try exc_class.methods.put(vm.allocator, "initialize", value.Value.initObj(&init_fn.obj));

    const msg_fn = try vm.gc.allocateNative(vm, exceptionMessage);
    try exc_class.methods.put(vm.allocator, "message", value.Value.initObj(&msg_fn.obj));
    try exc_class.methods.put(vm.allocator, "to_s", value.Value.initObj(&msg_fn.obj));

    const bt_fn = try vm.gc.allocateNative(vm, exceptionBacktrace);
    try exc_class.methods.put(vm.allocator, "backtrace", value.Value.initObj(&bt_fn.obj));

    // StandardError < Exception
    const std_name = try vm.allocateStringTakeOwnership(try vm.allocator.dupe(u8, "StandardError"));
    vm.push(std_name);
    const std_class = try vm.gc.allocateClass(vm, @as(*value.ObjString, @ptrCast(std_name.asObj())), exc_class);
    try vm.globals.put(vm.allocator, "StandardError", value.Value.initObj(&std_class.obj));
    _ = vm.pop();

    // Common Ruby-like Subclasses
    const error_types = [_][]const u8{
        "ArgumentError",
        "TypeError",
        "RuntimeError",
        "IndexError",
        "ZeroDivisionError",
    };

    for (error_types) |err_name| {
        const name_val = try vm.allocateStringTakeOwnership(try vm.allocator.dupe(u8, err_name));
        vm.push(name_val);
        const err_class = try vm.gc.allocateClass(vm, @as(*value.ObjString, @ptrCast(name_val.asObj())), std_class);
        try vm.globals.put(vm.allocator, err_name, value.Value.initObj(&err_class.obj));
        _ = vm.pop();
    }
}
