const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

pub fn nativeDebugger(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    stdout.writeStreamingAll(vm.io, "\n=== 🐛 KupCAD Debugger ===\n") catch {};
    stdout.writeStreamingAll(vm.io, "Type 'stack', 'globals', 'help', or 'c' to continue.\n") catch {};

    var buf: [1024]u8 = undefined;

    while (true) {
        stdout.writeStreamingAll(vm.io, "(dbg) > ") catch {};

        const bytes_read = stdin.readStreaming(vm.io, &.{&buf}) catch |err| {
            std.log.err("Debugger input error: {}", .{err});
            break;
        };

        if (bytes_read == 0) break; // EOF (Ctrl+D)

        const input = std.mem.trim(u8, buf[0..bytes_read], " \r\n\t");
        if (input.len == 0) continue;

        if (std.mem.eql(u8, input, "c") or std.mem.eql(u8, input, "continue")) {
            stdout.writeStreamingAll(vm.io, "Resuming execution...\n\n") catch {};
            break;
        } else if (std.mem.eql(u8, input, "stack")) {
            var out: std.Io.Writer.Allocating = .init(vm.allocator);
            defer out.deinit();

            out.writer.writeAll("--- VM Stack ---\n") catch {};
            var i: usize = vm.stack_top;
            while (i > 0) {
                i -= 1;
                out.writer.print("[{d:0>2}] ", .{i}) catch {};
                vm.stack[i].stringify(true, &out.writer) catch {};
                out.writer.writeAll("\n") catch {};
            }
            out.writer.writeAll("----------------\n") catch {};
            stdout.writeStreamingAll(vm.io, out.written()) catch {};
        } else if (std.mem.eql(u8, input, "globals")) {
            var out: std.Io.Writer.Allocating = .init(vm.allocator);
            defer out.deinit();

            out.writer.writeAll("--- Globals ---\n") catch {};
            var it = vm.globals.iterator();
            while (it.next()) |entry| {
                out.writer.print("{s}: ", .{entry.key_ptr.*}) catch {};
                entry.value_ptr.*.stringify(true, &out.writer) catch {};
                out.writer.writeAll("\n") catch {};
            }
            out.writer.writeAll("---------------\n") catch {};
            stdout.writeStreamingAll(vm.io, out.written()) catch {};
        } else if (std.mem.eql(u8, input, "help")) {
            stdout.writeStreamingAll(vm.io, "Commands: stack, globals, c (continue), help\n") catch {};
        } else {
            stdout.writeStreamingAll(vm.io, "Unknown command. Type 'help'.\n") catch {};
        }
    }

    return value.Value.initNil();
}
