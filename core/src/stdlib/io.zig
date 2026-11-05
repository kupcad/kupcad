//! The global functions `puts`, `print` and `inspect`: they write through the host's print
//! handler, and `inspect` prefixes its output with the calling line and column and returns
//! its last argument.

const std = @import("std");
const value = @import("../core/value.zig");
const limits = @import("../core/limits.zig");
const VM = @import("../vm/vm.zig").VM;
const Text = @import("../vm/text.zig").Text;

/// `args` copied into `buf`: each is shown by its own to_s or inspect, a script's, which may
/// grow the VM stack and move the arguments that lie in it (they stay rooted there). Read in
/// place, the next one came from the freed stack.
fn copied(buf: *[limits.MAX_ARGS]value.Value, args: []const value.Value) []const value.Value {
    @memcpy(buf[0..args.len], args);
    return buf[0..args.len];
}

inline fn printShared(vm: *VM, args: []const value.Value, append_newline: bool) !value.Value {
    if (vm.host.print_handler) |print_handler| {
        var buf: [limits.MAX_ARGS]value.Value = undefined;
        for (copied(&buf, args)) |arg| {
            var out: Text = .init(vm);
            defer out.deinit();
            try out.display(arg);
            if (append_newline) try out.writeAll("\n");
            print_handler(vm, out.written());
        }
    }
    return value.Value.initNil();
}

pub fn nativePuts(vm: *VM, args: []const value.Value) !value.Value {
    return printShared(vm, args, true);
}

pub fn nativePrint(vm: *VM, args: []const value.Value) !value.Value {
    return printShared(vm, args, false);
}

pub fn nativeInspect(vm: *VM, args: []const value.Value) !value.Value {
    var buf: [limits.MAX_ARGS]value.Value = undefined;
    const shown = copied(&buf, args);
    if (vm.host.print_handler) |print_handler| {
        var loc_buf: [64]u8 = undefined;
        const loc_prefix: []const u8 = if (vm.currentPosition()) |at| std.mem.print(&loc_buf, "[line {d}, col {d}] ", .{ at.line, at.column }) catch "" else "";

        for (shown) |arg| {
            var out: Text = .init(vm);
            defer out.deinit();
            try out.writeAll(loc_prefix);
            try out.inspect(arg);
            try out.writeAll("\n");
            print_handler(vm, out.written());
        }
    }
    return if (shown.len > 0) shown[shown.len - 1] else value.Value.initNil();
}
