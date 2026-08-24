const std = @import("std");
const builtin = @import("builtin");
const value = @import("../core/value.zig");
const chunk = @import("../vm/chunk.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const VM = @import("../vm/vm.zig").VM;

const MAX_HISTORY = 100;

// DOD History Buffer
const History = struct {
    chars: std.ArrayListUnmanaged(u8) = .empty,
    line_starts: std.ArrayListUnmanaged(usize) = .empty,

    pub fn push(self: *History, alloc: std.mem.Allocator, line: []const u8) !void {
        if (line.len == 0) return;

        if (self.line_starts.items.len > 0) {
            const last_start = self.line_starts.items[self.line_starts.items.len - 1];
            const last_line = self.chars.items[last_start..];
            if (std.mem.eql(u8, last_line, line)) return;
        }

        // Cap History Array to prevent Memory Leaks
        if (self.line_starts.items.len >= MAX_HISTORY) {
            const first_start = self.line_starts.items[0];
            const second_start = self.line_starts.items[1];
            const diff = second_start - first_start;

            // Shift characters and remove oldest entry
            self.chars.replaceRange(alloc, 0, diff, &[_]u8{}) catch {};
            _ = self.line_starts.orderedRemove(0);

            for (self.line_starts.items) |*s| s.* -= diff;
        }

        try self.line_starts.append(alloc, self.chars.items.len);
        try self.chars.appendSlice(alloc, line);
    }

    pub fn get(self: *const History, index: usize) []const u8 {
        const start = self.line_starts.items[index];
        const end = if (index + 1 < self.line_starts.items.len)
            self.line_starts.items[index + 1]
        else
            self.chars.items.len;
        return self.chars.items[start..end];
    }

    pub fn count(self: *const History) usize {
        return self.line_starts.items.len;
    }

    pub fn deinit(self: *History, alloc: std.mem.Allocator) void {
        self.chars.deinit(alloc);
        self.line_starts.deinit(alloc);
    }
};

// --- Raw Terminal Line Editor ---
fn refreshLine(vm: *VM, stdout: std.Io.File, prompt: []const u8, buf: []const u8, cursor: usize) !void {
    stdout.writeStreamingAll(vm.io, "\r\x1b[2K") catch {}; // Clear line
    stdout.writeStreamingAll(vm.io, prompt) catch {};
    stdout.writeStreamingAll(vm.io, buf) catch {};

    if (buf.len > cursor) {
        var ansi_buf: [32]u8 = undefined;
        if (std.fmt.bufPrint(&ansi_buf, "\x1b[{d}D", .{buf.len - cursor})) |msg| {
            stdout.writeStreamingAll(vm.io, msg) catch {};
        } else |_| {}
    }
}

fn readLine(vm: *VM, prompt: []const u8, history: *History) !?[]const u8 {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        stdout.writeStreamingAll(vm.io, prompt) catch {};
        var buf: [1024]u8 = undefined;
        const bytes_read = stdin.readStreaming(vm.io, &.{&buf}) catch return null;
        if (bytes_read == 0) return null;

        return try vm.allocator.dupe(u8, std.mem.trimEnd(u8, buf[0..bytes_read], "\r\n"));
    }

    const posix = std.posix;
    const stdin_fd = posix.STDIN_FILENO;

    // Enable Raw Terminal Mode using Zig 0.16 strongly-typed flags
    const orig_termios_opt = posix.tcgetattr(stdin_fd) catch null;
    if (orig_termios_opt) |orig| {
        var raw = orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        posix.tcsetattr(stdin_fd, .FLUSH, raw) catch {};
    }
    defer {
        if (orig_termios_opt) |orig| {
            posix.tcsetattr(stdin_fd, .FLUSH, orig) catch {};
        }
    }

    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    var cursor: usize = 0;
    var hist_idx: usize = history.count();

    try refreshLine(vm, stdout, prompt, buf[0..len], cursor);

    while (true) {
        var b_buf: [1]u8 = undefined;
        const n = stdin.readStreaming(vm.io, &.{&b_buf}) catch return null;
        if (n == 0) return null;
        const c = b_buf[0];

        if (c == '\n' or c == '\r') {
            stdout.writeStreamingAll(vm.io, "\n") catch {};
            return try vm.allocator.dupe(u8, buf[0..len]);
        } else if (c == 3 or c == 4) { // Ctrl+C or Ctrl+D
            stdout.writeStreamingAll(vm.io, "\n") catch {};
            return null;
        } else if (c == 127 or c == 8) { // Backspace
            if (cursor > 0) {
                std.mem.copyForwards(u8, buf[cursor - 1 .. len - 1], buf[cursor..len]);
                len -= 1;
                cursor -= 1;
                try refreshLine(vm, stdout, prompt, buf[0..len], cursor);
            }
        } else if (c == 27) { // ANSI Escape sequence parsing
            var seq1: [1]u8 = undefined;
            if ((stdin.readStreaming(vm.io, &.{&seq1}) catch 0) == 1 and seq1[0] == '[') {
                var seq2: [1]u8 = undefined;
                if ((stdin.readStreaming(vm.io, &.{&seq2}) catch 0) == 1) {
                    if (seq2[0] == 'A') { // Up Arrow
                        if (hist_idx > 0) {
                            hist_idx -= 1;
                            const h = history.get(hist_idx);
                            @memcpy(buf[0..h.len], h);
                            len = h.len;
                            cursor = h.len;
                            try refreshLine(vm, stdout, prompt, buf[0..len], cursor);
                        }
                    } else if (seq2[0] == 'B') { // Down Arrow
                        if (hist_idx < history.count()) {
                            hist_idx += 1;
                            if (hist_idx == history.count()) {
                                len = 0;
                                cursor = 0;
                            } else {
                                const h = history.get(hist_idx);
                                @memcpy(buf[0..h.len], h);
                                len = h.len;
                                cursor = h.len;
                            }
                            try refreshLine(vm, stdout, prompt, buf[0..len], cursor);
                        }
                    } else if (seq2[0] == 'C') { // Right Arrow
                        if (cursor < len) {
                            cursor += 1;
                            try refreshLine(vm, stdout, prompt, buf[0..len], cursor);
                        }
                    } else if (seq2[0] == 'D') { // Left Arrow
                        if (cursor > 0) {
                            cursor -= 1;
                            try refreshLine(vm, stdout, prompt, buf[0..len], cursor);
                        }
                    }
                }
            }
        } else if (c >= 32 and c < 127) { // Standard printable characters
            if (len < buf.len) {
                std.mem.copyBackwards(u8, buf[cursor + 1 .. len + 1], buf[cursor..len]);
                buf[cursor] = c;
                len += 1;
                cursor += 1;
                try refreshLine(vm, stdout, prompt, buf[0..len], cursor);
            }
        }
    }
}

fn printLocals(vm: *VM) void {
    const stdout = std.Io.File.stdout();
    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();
    out.writer.writeAll("--- Locals ---\n") catch {};

    if (vm.frames.items.len > 0) {
        const frame = &vm.frames.items[vm.frames.items.len - 1];
        if (frame.closure.function.chunk) |c_ptr| {
            const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(c_ptr)));
            const locals = exec_chunk.local_names.items;
            for (locals, 0..) |name, i| {
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

fn printStack(vm: *VM) void {
    const stdout = std.Io.File.stdout();
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

fn printGlobals(vm: *VM) void {
    const stdout = std.Io.File.stdout();
    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();
    out.writer.writeAll("--- User Globals ---\n") catch {};

    var it = vm.globals.iterator();
    while (it.next()) |entry| {
        const val = entry.value_ptr.*;
        if (val.isNative() or val.isClass() or val.isModule()) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "GC") or std.mem.eql(u8, entry.key_ptr.*, "Math")) continue;

        out.writer.print("{s}: ", .{entry.key_ptr.*}) catch {};
        val.stringify(true, &out.writer) catch {};
        out.writer.writeAll("\n") catch {};
    }
    out.writer.writeAll("--------------------\n") catch {};
    stdout.writeStreamingAll(vm.io, out.written()) catch {};
}

fn evaluateContextually(vm: *VM, input: []const u8) void {
    const stdout = std.Io.File.stdout();
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

    const caller_frame = &vm.frames.items[vm.frames.items.len - 1];
    var caller_locals: []const []const u8 = &.{};
    if (caller_frame.closure.function.chunk) |c_ptr| {
        const caller_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(c_ptr)));
        caller_locals = caller_chunk.local_names.items;
    }

    comp.seedLocals(caller_locals, 1);
    comp.compile(doc.tree.root) catch |err| {
        var err_buf: [128]u8 = undefined;
        const err_str = std.fmt.bufPrint(&err_buf, "Compile error: {}\n", .{err}) catch "Compile error.\n";
        stdout.writeStreamingAll(vm.io, err_str) catch {};
        return;
    };

    const func = vm.gc.allocateFunction(vm) catch return;
    func.chunk = &eval_chunk;
    func.owns_chunk = false;
    func.local_count = eval_chunk.local_count;

    const closure = vm.gc.allocateClosure(vm, func) catch return;
    const target_depth = vm.frames.items.len;
    const repl_base_slot = vm.stack_top;

    vm.push(value.Value.initObj(&closure.obj));

    for (0..caller_locals.len) |i| {
        if (caller_frame.base_slot + i < repl_base_slot) {
            vm.push(vm.stack[caller_frame.base_slot + i]);
        } else {
            vm.push(value.Value.initNil());
        }
    }

    const copied_slots = caller_locals.len + 1;
    if (func.local_count > copied_slots) {
        const padding = func.local_count - copied_slots;
        vm.ensureStackCapacity(vm.stack_top + padding) catch return;
        for (0..padding) |_| vm.push(value.Value.initNil());
    }

    vm.frames.append(vm.allocator, .{
        .closure = closure,
        .ip = 0,
        .base_slot = repl_base_slot,
    }) catch return;

    const saved_step = vm.step_mode;
    vm.step_mode = false;
    const res = vm.runUntil(target_depth);
    vm.step_mode = saved_step;

    if (res == .ok) {
        const result_val = vm.pop();

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

    vm.shrinkStack(repl_base_slot);
}

pub fn debuggerLoop(vm: *VM) void {
    const stdout = std.Io.File.stdout();

    stdout.writeStreamingAll(vm.io, "\n===   KupCAD Debugger ===\n") catch {};
    stdout.writeStreamingAll(vm.io, "Commands: .step, .continue, .locals, .stack, .globals, .help\n") catch {};

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

    var history = History{};
    defer history.deinit(vm.allocator);

    while (true) {
        const input_opt = readLine(vm, "(dbg) > ", &history) catch |err| {
            std.log.err("Debugger input error: {}", .{err});
            break;
        };

        if (input_opt == null) break;

        const input = input_opt.?;
        defer vm.allocator.free(input);

        const trimmed = std.mem.trim(u8, input, " \r\n\t");
        if (trimmed.len == 0) continue;

        history.push(vm.allocator, trimmed) catch {};

        if (std.mem.eql(u8, trimmed, ".c") or std.mem.eql(u8, trimmed, ".continue")) {
            stdout.writeStreamingAll(vm.io, "Resuming execution...\n\n") catch {};
            vm.step_mode = false;
            break;
        } else if (std.mem.eql(u8, trimmed, ".s") or std.mem.eql(u8, trimmed, ".step")) {
            vm.step_mode = true;
            break;
        } else if (std.mem.eql(u8, trimmed, ".q") or std.mem.eql(u8, trimmed, ".exit") or std.mem.eql(u8, trimmed, ".quit")) {
            stdout.writeStreamingAll(vm.io, "Exiting KupCAD...\n") catch {};
            std.process.exit(0);
        } else if (std.mem.eql(u8, trimmed, ".l") or std.mem.eql(u8, trimmed, ".locals")) {
            printLocals(vm);
        } else if (std.mem.eql(u8, trimmed, ".st") or std.mem.eql(u8, trimmed, ".stack")) {
            printStack(vm);
        } else if (std.mem.eql(u8, trimmed, ".g") or std.mem.eql(u8, trimmed, ".globals")) {
            printGlobals(vm);
        } else if (std.mem.eql(u8, trimmed, ".h") or std.mem.eql(u8, trimmed, ".help")) {
            stdout.writeStreamingAll(vm.io, "Commands:\n  .s, .step      Step to next line\n  .c, .continue  Resume execution\n  .l, .locals    Print local variables\n  .st, .stack    Print VM stack\n  .g, .globals   Print User Globals\n  .q, .exit      Quit program\n  <expr>         Evaluate expression (e.g. 'c', 'width * 2')\n") catch {};
        } else {
            evaluateContextually(vm, trimmed);
        }
    }
}

pub fn nativeDebugger(vm: *VM) !value.Value {
    vm.debugger_step_handler = debuggerLoop;
    debuggerLoop(vm);
    return value.Value.initNil();
}
