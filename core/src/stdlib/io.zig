const std = @import("std");
const value = @import("../core/value.zig");
const chunk = @import("../vm/chunk.zig");
const VM = @import("../vm/vm.zig").VM;

inline fn printShared(vm: *VM, args: []const value.Value, append_newline: bool) !value.Value {
    if (vm.host.print_handler) |print_handler| {
        for (args) |arg| {
            var out: std.Io.Writer.Allocating = .init(vm.allocator);
            defer out.deinit();

            try arg.stringify(false, &out.writer);
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
        var loc_prefix: []const u8 = "";

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

        for (args) |arg| {
            var out: std.Io.Writer.Allocating = .init(vm.allocator);
            defer out.deinit();
            try out.writer.writeAll(loc_prefix);

            var printed = false;
            if (arg.isInstance()) {
                const inst = arg.asInstance();
                if (inst.class.methods.get("inspect") orelse inst.class.methods.get("to_s")) |m_val| {
                    if (m_val.isObject() and m_val.asObj().obj_type == .native) {
                        const native_obj = @as(*value.ObjNative, @alignCast(@fieldParentPtr("obj", m_val.asObj())));

                        // Push `arg` onto the VM stack so `vm.getReceiver(args_ptr)` safely resolves `arg`!
                        vm.push(arg);
                        defer _ = vm.pop();
                        const args_ptr = vm.stack.ptr + vm.stack_top;

                        if (native_obj.function(vm, 0, args_ptr)) |res_str| {
                            try res_str.stringify(false, &out.writer);
                            printed = true;
                        } else |_| {}
                    }
                }
            }

            if (!printed) {
                try arg.stringify(true, &out.writer);
            }

            try out.writer.writeAll("\n");
            print_handler(vm, out.written());
        }
    }
    return if (args.len > 0) args[args.len - 1] else value.Value.initNil();
}
