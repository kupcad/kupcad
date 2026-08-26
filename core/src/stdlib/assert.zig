const value = @import("../core/value.zig");
const chunk = @import("../vm/chunk.zig");
const VM = @import("../vm/vm.zig").VM;

pub fn nativeAssert(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count == 0) {
        vm.reportError("ArgumentError: assert requires at least 1 argument.\n", .{});
        return error.RuntimeError;
    }

    var pos_count = arg_count;
    var block_closure: ?*value.ObjClosure = null;

    // The VM pushes blocks as the final argument invisibly. Extract it if present.
    if (arg_count > 0 and args[arg_count - 1].isClosure()) {
        block_closure = args[arg_count - 1].asClosure();
        pos_count -= 1;
    }

    if (pos_count < 1 or pos_count > 3) {
        vm.reportError("ArgumentError: assert expects 1 to 3 positional arguments.\n", .{});
        return error.RuntimeError;
    }

    const condition = args[0];

    // Check if the assertion failed (using Truthiness: only false or nil fail)
    if (value.Value.isFalsey(condition)) {

        // Determine Exception Class
        var err_class: *value.ObjClass = undefined;
        if (pos_count == 3) {
            const err_val = args[2];
            if (!err_val.isClass()) {
                vm.reportError("TypeError: Third argument to assert must be an Exception Class.\n", .{});
                return error.RuntimeError;
            }
            err_class = err_val.asClass();
        } else {
            const default_err = vm.globals.get("AssertionError") orelse {
                vm.reportError("RuntimeError: AssertionError class not found.\n", .{});
                return error.RuntimeError;
            };
            err_class = default_err.asClass();
        }

        // Determine Message
        var msg_val = value.Value.initNil();
        if (block_closure) |closure| {
            // Lazy Evaluation: Only execute the block because the assertion failed!
            msg_val = try vm.callClosureSync(closure, &.{});
            if (!msg_val.isObject() or msg_val.asObj().obj_type != .string) {
                vm.reportError("TypeError: assert block must return a String message.\n", .{});
                return error.RuntimeError;
            }
        } else if (pos_count >= 2) {
            msg_val = args[1];
            if (!msg_val.isObject() or msg_val.asObj().obj_type != .string) {
                vm.reportError("TypeError: assert message must be a String.\n", .{});
                return error.RuntimeError;
            }
        } else {
            msg_val = try vm.allocateString("Assertion failed.");
        }

        // Construct and Throw Exception
        const inst = try vm.gc.allocateInstance(vm, err_class);
        vm.push(value.Value.initObj(&inst.obj)); // Protect from GC
        try vm.setInstanceField(inst, "message", msg_val, null);

        // Capture Stack Trace
        if (vm.buildBacktrace()) |bt_arr| {
            vm.push(value.Value.initObj(&bt_arr.obj));
            try vm.setInstanceField(inst, "backtrace", value.Value.initObj(&bt_arr.obj), null);
            _ = vm.pop();
        } else |_| {}

        _ = vm.pop(); // Unprotect

        // Throw directly into the VM's rescue system
        vm.push(value.Value.initObj(&inst.obj));
        const res = vm.executeThrow();

        if (res == .ok) {
            // A rescue block caught it! Tell the Native Wrapper to sync the instruction pointer.
            return error.Unwind;
        } else {
            // Uncaught exception
            return error.FatalError;
        }
    }

    return value.Value.initNil();
}
