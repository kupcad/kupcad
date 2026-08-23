const std = @import("std");
const value = @import("../core/value.zig");
const chunk = @import("../vm/chunk.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const VM = @import("../vm/vm.zig").VM;

fn printLocals(vm: *VM, stdout: anytype) void {
    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();
    out.writer.writeAll("--- Locals ---\n") catch {};

    if (vm.frames.items.len > 0) {
        const frame = &vm.frames.items[vm.frames.items.len - 1];
        if (frame.closure.function.chunk) |c_ptr| {
            const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(c_ptr)));
            const locals = exec_chunk.local_names.items;
            for (locals, 0..) |name, i| {
                // Hide padding slots and anonymous variables from the user
                if (std.mem.eql(u8, name, "<anonymous>")) continue;
                const slot = frame.base_slot + i;
                if (slot < vm.stack_top) {
                    out.writer.print("{s}: ", .{name}) catch {};
                    vm.stack[slot].stringify(true, &out.writer) catch {};
                    out.writer.writeAll("\n") catch {};
                }
            }
        }
    }
    out.writer.writeAll("--------------\n") catch {};
    stdout.writeStreamingAll(vm.io, out.written()) catch {};
}

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
    out.writer.writeAll("--- User Globals ---\n") catch {};

    var it = vm.globals.iterator();
    while (it.next()) |entry| {
        const val = entry.value_ptr.*;

        // Filter out the standard library to reduce noise
        if (val.isNative() or val.isClass() or val.isModule()) continue;

        // Hide standard library singletons
        if (std.mem.eql(u8, entry.key_ptr.*, "GC") or std.mem.eql(u8, entry.key_ptr.*, "Math")) continue;

        out.writer.print("{s}: ", .{entry.key_ptr.*}) catch {};
        val.stringify(true, &out.writer) catch {};
        out.writer.writeAll("\n") catch {};
    }
    out.writer.writeAll("--------------------\n") catch {};
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

    // Disable step mode temporarily inside REPL eval to prevent infinite recursion
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

pub fn debuggerLoop(vm: *VM) void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    stdout.writeStreamingAll(vm.io, "\n===   KupCAD Debugger ===\n") catch {};
    stdout.writeStreamingAll(vm.io, "Commands: .step, .continue, .locals, .stack, .globals, .help\n") catch {};

    // Print current line context
    if (vm.frames.items.len > 0) {
        const frame = &vm.frames.items[vm.frames.items.len - 1];
        if (frame.closure.function.chunk) |chunk_ptr| {
            const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(chunk_ptr)));
            const instruction_ip = if (frame.ip > 0) frame.ip - 1 else 0;
            const source_offset = exec_chunk.getOffset(instruction_ip);
            if (vm.line_index) |li| {
                const line = li.getLine(source_offset) + 1;
                const col = li.getUtf8Column(source_offset) + 1;
                var loc_buf: [64]u8 = undefined;
                if (std.fmt.bufPrint(&loc_buf, "Break at line {d}, col {d}\n", .{ line, col })) |msg| {
                    stdout.writeStreamingAll(vm.io, msg) catch {};
                } else |_| {}
            }
        }
    }

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

        // --- COMMAND ROUTER ---
        if (std.mem.eql(u8, input, ".c") or std.mem.eql(u8, input, ".continue")) {
            stdout.writeStreamingAll(vm.io, "Resuming execution...\n\n") catch {};
            vm.step_mode = false;
            break;
        } else if (std.mem.eql(u8, input, ".s") or std.mem.eql(u8, input, ".step")) {
            vm.step_mode = true;
            break;
        } else if (std.mem.eql(u8, input, ".q") or std.mem.eql(u8, input, ".exit") or std.mem.eql(u8, input, ".quit")) {
            stdout.writeStreamingAll(vm.io, "Exiting KupCAD...\n") catch {};
            std.process.exit(0);
        } else if (std.mem.eql(u8, input, ".l") or std.mem.eql(u8, input, ".locals")) {
            printLocals(vm, stdout);
        } else if (std.mem.eql(u8, input, ".st") or std.mem.eql(u8, input, ".stack")) {
            printStack(vm, stdout);
        } else if (std.mem.eql(u8, input, ".g") or std.mem.eql(u8, input, ".globals")) {
            printGlobals(vm, stdout);
        } else if (std.mem.eql(u8, input, ".h") or std.mem.eql(u8, input, ".help")) {
            stdout.writeStreamingAll(vm.io, "Commands:\n  .s, .step      Step to next line\n  .c, .continue  Resume execution\n  .l, .locals    Print local variables\n  .st, .stack    Print VM stack\n  .g, .globals   Print global variables\n  .q, .exit      Quit program\n  <expr>         Evaluate KupCAD expression (e.g. 'c', 'width * 2')\n") catch {};
        } else {
            // Evaluate standard script variables and expressions!
            evaluateContextually(vm, input, stdout);
        }
    }
}

pub fn nativeDebugger(vm: *VM) !value.Value {
    // Lazy-bind the step handler so the VM calls this loop automatically on line boundaries
    vm.debugger_step_handler = debuggerLoop;

    debuggerLoop(vm);
    return value.Value.initNil();
}
