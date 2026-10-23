//! The global functions `puts`, `print` and `inspect`: they write through the host's print
//! handler, and `inspect` prefixes its output with the calling line and column and returns
//! its last argument.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

inline fn printShared(vm: *VM, args: []const value.Value, append_newline: bool) !value.Value {
    if (vm.host.print_handler) |print_handler| {
        for (args) |arg| {
            var out: std.Io.Writer.Allocating = .init(vm.allocator);
            defer out.deinit();

            try vm.writeDisplay(arg, &out.writer);
            if (append_newline) {
                try out.writer.writeAll("\n");
            }

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
    if (vm.host.print_handler) |print_handler| {
        var loc_buf: [64]u8 = undefined;
        const loc_prefix: []const u8 = if (vm.currentPosition()) |at| std.mem.print(&loc_buf, "[line {d}, col {d}] ", .{ at.line, at.column }) catch "" else "";

        for (args) |arg| {
            var out: std.Io.Writer.Allocating = .init(vm.allocator);
            defer out.deinit();
            try out.writer.writeAll(loc_prefix);
            try vm.writeInspect(arg, &out.writer);
            try out.writer.writeAll("\n");
            print_handler(vm, out.written());
        }
    }
    return if (args.len > 0) args[args.len - 1] else value.Value.initNil();
}
