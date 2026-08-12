const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

pub fn nativePuts(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (vm.host.print_handler) |print_handler| {
        for (0..arg_count) |i| {
            var out: std.Io.Writer.Allocating = .init(vm.allocator);
            defer out.deinit();
            try args[i].stringify(false, &out.writer);
            try out.writer.writeAll("\n");
            print_handler(vm, out.written());
        }
    }
    return value.Value.initNil();
}

pub fn nativePrint(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (vm.host.print_handler) |print_handler| {
        for (0..arg_count) |i| {
            var out: std.Io.Writer.Allocating = .init(vm.allocator);
            defer out.deinit();
            try args[i].stringify(false, &out.writer);
            print_handler(vm, out.written());
        }
    }
    return value.Value.initNil();
}

pub fn nativeP(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (vm.host.print_handler) |print_handler| {
        for (0..arg_count) |i| {
            var out: std.Io.Writer.Allocating = .init(vm.allocator);
            defer out.deinit();
            try args[i].stringify(true, &out.writer); // Trigger Inspect Mode
            try out.writer.writeAll("\n");
            print_handler(vm, out.written());
        }
    }
    return if (arg_count > 0) args[arg_count - 1] else value.Value.initNil();
}
