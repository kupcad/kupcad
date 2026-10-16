//! The exception classes: `registerExceptions` defines Exception (with `message` and
//! `backtrace`), StandardError below it, and one class per runtime `ErrorKind`, which the
//! VM keeps for `raiseError`.

const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const ErrorKind = @import("../vm/error_kind.zig").ErrorKind;
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
    // Base Exception. The class names are static strings, never collected, so nothing
    // needs rooting while the classes are made.
    const exc_name = try vm.staticString("Exception");
    const exc_class = try vm.gc.allocateClass(vm, exc_name.asString(), vm.object_class);

    // Note: vm.globals.put safely stays vm.allocator because globals are tied to VM lifetime, not sandbox GC
    try vm.setGlobal("Exception", value.Value.initObj(&exc_class.obj));

    const init_fn = try vm.gc.allocateNative("Exception#initialize", common.wrapMethod(exceptionInit));
    const init_key = try vm.staticString("initialize");
    try exc_class.methods.put(vm.gc.trackingAllocator(), init_key, value.Value.initObj(&init_fn.obj));

    const msg_fn = try vm.gc.allocateNative("Exception#message", common.wrapMethod(exceptionMessage));
    const msg_key = try vm.staticString("message");
    const tos_key = try vm.staticString("to_s");
    try exc_class.methods.put(vm.gc.trackingAllocator(), msg_key, value.Value.initObj(&msg_fn.obj));
    try exc_class.methods.put(vm.gc.trackingAllocator(), tos_key, value.Value.initObj(&msg_fn.obj));

    const bt_fn = try vm.gc.allocateNative("Exception#backtrace", common.wrapMethod(exceptionBacktrace));
    const bt_key = try vm.staticString("backtrace");
    try exc_class.methods.put(vm.gc.trackingAllocator(), bt_key, value.Value.initObj(&bt_fn.obj));

    // StandardError < Exception
    const std_name = try vm.staticString("StandardError");
    const std_class = try vm.gc.allocateClass(vm, std_name.asString(), exc_class);
    try vm.setGlobal("StandardError", value.Value.initObj(&std_class.obj));

    // One class per runtime error kind; the VM keeps them for raiseError.
    inline for (comptime std.meta.fieldNames(ErrorKind)) |err_name| {
        const name_val = try vm.staticString(err_name);
        const err_class = try vm.gc.allocateClass(vm, name_val.asString(), std_class);
        try vm.setGlobal(err_name, value.Value.initObj(&err_class.obj));
        vm.error_classes.set(@field(ErrorKind, err_name), err_class);
    }
}
