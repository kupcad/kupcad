const std = @import("std");
const value = @import("../core/value.zig");
const chunk = @import("../vm/chunk.zig");
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
        var loc_buf: [64]u8 = undefined;
        var loc_prefix: []const u8 = "";

        // Resolve current source position from call frame
        if (vm.frames.items.len > 0) {
            const frame = &vm.frames.items[vm.frames.items.len - 1];
            if (frame.closure.function.chunk) |chunk_ptr| {
                const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(chunk_ptr)));
                const instruction_ip = if (frame.ip > 0) frame.ip - 1 else 0;
                const source_offset = exec_chunk.getOffset(instruction_ip);

                if (vm.line_index) |li| {
                    const line = li.getLine(source_offset) + 1;
                    const col = li.getUtf8Column(source_offset) + 1;
                    loc_prefix = std.fmt.bufPrint(&loc_buf, "[line {d}, col {d}] ", .{ line, col }) catch "";
                }
            }
        }

        for (0..arg_count) |i| {
            var out: std.Io.Writer.Allocating = .init(vm.allocator);
            defer out.deinit();

            try out.writer.writeAll(loc_prefix);
            try args[i].stringify(true, &out.writer); // Trigger Inspect Mode
            try out.writer.writeAll("\n");

            print_handler(vm, out.written());
        }
    }
    return if (arg_count > 0) args[arg_count - 1] else value.Value.initNil();
}
