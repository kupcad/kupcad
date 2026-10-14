const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const util = @import("methods/util.zig");

/// assert(condition, message = "Assertion failed.", error_class = AssertionError) { message }
/// -> raises when the condition is false or nil; the block, if given, builds the message
/// lazily (only for a failure).
pub fn nativeAssert(vm: *VM, condition: value.Value, message: ?value.Value, error_class: ?*value.ObjClass, block: ?*value.ObjClosure) anyerror!value.Value {
    if (!value.Value.isFalsey(condition)) return value.Value.initNil();

    const err_class = error_class orelse vm.error_classes.get(.AssertionError) orelse {
        _ = vm.raiseError(.RuntimeError, "AssertionError class not found", .{});
        return error.RuntimeError;
    };

    const msg_val = if (block) |closure|
        try requireMessage(vm, try vm.callClosureSync(closure, &.{}), "its block to return a String message")
    else if (message) |m|
        try requireMessage(vm, m, "a String for its message")
    else
        try vm.allocateString("Assertion failed.");

    // Construct and Throw Exception
    vm.push(msg_val); // A fresh message is otherwise unrooted while the instance is allocated
    const inst = try vm.gc.allocateInstance(vm, err_class);
    vm.push(value.Value.initObj(&inst.obj)); // Protect from GC

    const msg_key = try vm.allocateString("message");
    try vm.setInstanceField(inst, msg_key, msg_val, null);

    // Capture Stack Trace
    if (vm.buildBacktrace()) |bt_arr| {
        vm.push(value.Value.initObj(&bt_arr.obj));
        const bt_key = try vm.allocateString("backtrace");
        try vm.setInstanceField(inst, bt_key, value.Value.initObj(&bt_arr.obj), null);
        _ = vm.pop();
    } else |_| {}

    _ = vm.pop(); // Unprotect
    _ = vm.pop(); // msg_val, now held by the instance

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

fn requireMessage(vm: *VM, msg: value.Value, comptime expected: []const u8) !value.Value {
    if (msg.isString()) return msg;
    _ = vm.raiseError(.TypeError, "assert expects " ++ expected ++ ", got {s}", .{util.typeName(vm, msg)});
    return error.RuntimeError;
}

pub fn nativeWarn(vm: *VM, args: []const value.Value) anyerror!value.Value {
    if (vm.host.print_handler) |print_handler| {
        var out: std.Io.Writer.Allocating = .init(vm.allocator);
        defer out.deinit();

        try out.writer.writeAll("[Warning] ");

        for (args) |arg| {
            try arg.stringify(false, &out.writer);
        }
        try out.writer.writeAll("\n");

        print_handler(vm, out.written());
    }

    return value.Value.initNil();
}

/// benchmark(label = "Execution") { ... } -> runs the block, prints how long it took and
/// returns its result
pub fn nativeBenchmark(vm: *VM, label_str: ?*value.ObjString, block: *value.ObjClosure) anyerror!value.Value {
    const label = if (label_str) |l| l.chars else "Execution";

    // Start Timer using the VM's IO capability
    const start_time = std.Io.Clock.now(.awake, vm.io);

    const result = try vm.callClosureSync(block, &.{});

    // Stop Timer
    const end_time = std.Io.Clock.now(.awake, vm.io);

    // Calculate safe duration
    const duration_ns = start_time.durationTo(end_time).toNanoseconds();
    const elapsed_ns: u64 = @intCast(@max(0, duration_ns));
    const duration_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    if (vm.host.print_handler) |print_handler| {
        if (vm.fmtScratch("[Benchmark] {s}: {d:.3} ms\n", .{ label, duration_ms })) |msg| {
            print_handler(vm, msg);
        } else |_| {}
    }

    return result;
}
