const std = @import("std");
const value = @import("../core/value.zig");
const chunk = @import("../vm/chunk.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const VM = @import("../vm/vm.zig").VM;

fn printStack(vm: *VM, stdout: anytype) void {
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
}

fn printGlobals(vm: *VM, stdout: anytype) void {
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
}

fn evaluateContextually(vm: *VM, input: []const u8, stdout: anytype) void {
    var doc = Document.parse(vm.allocator, input) catch {
        stdout.writeStreamingAll(vm.io, "Parse error.\n") catch {};
        return;
    };
    defer doc.deinit();

    if (doc.diagnostics.len > 0) {
        stdout.writeStreamingAll(vm.io, "Syntax error.\n") catch {};
        return;
    }

    var eval_chunk = chunk.Chunk.init();
    defer eval_chunk.free(vm.allocator);

    var comp = Compiler.init(vm.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &eval_chunk, vm);
    defer comp.deinit();

    // 1. Resolve Caller's State
    const caller_frame = &vm.frames.items[vm.frames.items.len - 1];
    var caller_locals: []const []const u8 = &.{};

    if (caller_frame.closure.function.chunk) |c_ptr| {
        const caller_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(c_ptr)));
        caller_locals = caller_chunk.local_names.items;
    }

    // 2. Seed Compiler (Offset 1 because slot 0 is reserved for the REPL closure)
    comp.seedLocals(caller_locals, 1);

    comp.compile(doc.tree.root) catch |err| {
        var err_buf: [128]u8 = undefined;
        const err_str = std.fmt.bufPrint(&err_buf, "Compile error: {}\n", .{err}) catch "Compile error.\n";
        stdout.writeStreamingAll(vm.io, err_str) catch {};
        return;
    };

    // 3. Execution Setup
    const func = vm.gc.allocateFunction(vm) catch return;
    func.chunk = &eval_chunk;
    func.owns_chunk = false;
    func.local_count = eval_chunk.local_count;

    const closure = vm.gc.allocateClosure(vm, func) catch return;
    const target_depth = vm.frames.items.len;
    const repl_base_slot = vm.stack_top;

    // Push REPL closure
    vm.push(value.Value.initObj(&closure.obj));

    // 4. COPY IN: Copy caller's locals into the new REPL frame
    for (0..caller_locals.len) |i| {
        if (caller_frame.base_slot + i < repl_base_slot) {
            vm.push(vm.stack[caller_frame.base_slot + i]);
        } else {
            vm.push(value.Value.initNil());
        }
    }

    // 5. Pad any new locals the REPL declared
    const copied_slots = caller_locals.len + 1;
    if (func.local_count > copied_slots) {
        const padding = func.local_count - copied_slots;
        vm.ensureStackCapacity(vm.stack_top + padding) catch return;
        for (0..padding) |_| vm.push(value.Value.initNil());
    }

    // 6. Execute REPL
    vm.frames.append(vm.allocator, .{
        .closure = closure,
        .ip = 0,
        .base_slot = repl_base_slot,
    }) catch return;

    // Disable step mode temporarily inside REPL eval
    const saved_step = vm.step_mode;
    vm.step_mode = false;
    const res = vm.runUntil(target_depth);
    vm.step_mode = saved_step;

    if (res == .ok) {
        const result_val = vm.pop();

        // 7. COPY OUT: Sync mutated locals back to the caller!
        for (0..caller_locals.len) |i| {
            if (caller_frame.base_slot + i < repl_base_slot) {
                vm.stack[caller_frame.base_slot + i] = vm.stack[repl_base_slot + 1 + i];
            }
        }

        var out: std.Io.Writer.Allocating = .init(vm.allocator);
        defer out.deinit();
        result_val.stringify(true, &out.writer) catch {};
        out.writer.writeAll("\n") catch {};
        stdout.writeStreamingAll(vm.io, out.written()) catch {};
    } else {
        stdout.writeStreamingAll(vm.io, "Evaluation failed.\n") catch {};
    }

    // 8. Clean up REPL frame memory footprint
    vm.shrinkStack(repl_base_slot);
}

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
        } else if (std.mem.eql(u8, input, "exit") or std.mem.eql(u8, input, "quit")) {
            stdout.writeStreamingAll(vm.io, "Exiting KupCAD...\n") catch {};
            std.process.exit(0);
        } else if (std.mem.eql(u8, input, "stack")) {
            printStack(vm, stdout);
        } else if (std.mem.eql(u8, input, "globals")) {
            printGlobals(vm, stdout);
        } else if (std.mem.eql(u8, input, "help")) {
            stdout.writeStreamingAll(vm.io, "Commands: stack, globals, c (continue), exit (quit program), help\n") catch {};
        } else {
            evaluateContextually(vm, input, stdout);
        }
    }

    return value.Value.initNil();
}
