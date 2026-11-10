//! The terminal debugger a script's `debugger` call opens: `debuggerLoop` reads commands
//! (`.step`, `.continue`, `.locals`, `.stack`, `.globals`) or expressions to evaluate in
//! the paused frame, with line editing and history. `terminalDebugger` picks it when stdin
//! is a terminal; the `debugger` built-in (stdlib/diagnostics.zig) calls the VM's handler.
//! `session` is the debugger apart from the terminal, the lines it is given and where it
//! answers its caller's, so its tests give it both.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../core/value.zig");
const chunk = @import("../vm/chunk.zig");
const Document = @import("../frontend/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const VM = @import("../vm/vm.zig").VM;
const progress = @import("progress.zig");

const log = std.log.scoped(.debugger);

const MAX_HISTORY = 100;
const PROMPT = "(dbg) > ";
const HELP =
    \\Commands:
    \\  .s, .step      Step to next line
    \\  .c, .continue  Resume execution
    \\  .l, .locals    Print local variables
    \\  .st, .stack    Print VM stack
    \\  .g, .globals   Print User Globals
    \\  .q, .exit      Stop the run (Ctrl+C too)
    \\  <expr>         Evaluate expression (e.g. 'c', 'width * 2')
    \\
;
/// How long after an Esc the rest of an arrow key's sequence may come: an Esc alone (no more
/// within it) waited for two more bytes.
const ESCAPE_FOLLOW_MS = 50;

/// The lines typed before, the newest last, at most MAX_HISTORY, none twice in a row.
pub const History = struct {
    chars: std.ArrayList(u8) = .empty,
    line_starts: std.ArrayList(usize) = .empty,

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
            try self.chars.replaceRange(alloc, 0, diff, &[_]u8{});
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
fn refreshLine(vm: *VM, stderr: std.Io.File, prompt: []const u8, buf: []const u8, cursor: usize) !void {
    stderr.writeStreamingAll(vm.io, "\r\x1b[2K") catch return; // Clear line
    stderr.writeStreamingAll(vm.io, prompt) catch return;
    stderr.writeStreamingAll(vm.io, buf) catch return;

    if (buf.len > cursor) {
        var ansi_buf: [32]u8 = undefined;
        if (std.mem.print(&ansi_buf, "\x1b[{d}D", .{buf.len - cursor})) |msg| {
            stderr.writeStreamingAll(vm.io, msg) catch return;
        } else |_| {}
    }
}

/// A line typed at `prompt`, owned; null at the end of input (Ctrl+D), error.Interrupted on
/// Ctrl+C, which the terminal gives as a key while a line is read.
fn readLine(vm: *VM, prompt: []const u8, history: *History) !?[]const u8 {
    const stdin = std.Io.File.stdin();
    const stderr = std.Io.File.stderr();

    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        stderr.writeStreamingAll(vm.io, prompt) catch return null;
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
        // Ctrl+C a key, not a signal: it killed the process with the terminal left raw
        raw.lflag.ISIG = false;
        posix.tcsetattr(stdin_fd, .FLUSH, raw) catch |err| log.warn("Terminal config error: {}", .{err});
    }
    defer {
        if (orig_termios_opt) |orig| {
            posix.tcsetattr(stdin_fd, .FLUSH, orig) catch |err| log.warn("Terminal config error: {}", .{err});
        }
    }

    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    var cursor: usize = 0;
    var hist_idx: usize = history.count();

    try refreshLine(vm, stderr, prompt, buf[0..len], cursor);

    while (true) {
        var b_buf: [1]u8 = undefined;
        const n = stdin.readStreaming(vm.io, &.{&b_buf}) catch return null;
        if (n == 0) return null;
        const c = b_buf[0];

        if (c == '\n' or c == '\r') {
            stderr.writeStreamingAll(vm.io, "\n") catch return null;
            return try vm.allocator.dupe(u8, buf[0..len]);
        } else if (c == 3) { // Ctrl+C: stop the run
            stderr.writeStreamingAll(vm.io, "\n") catch return error.Interrupted;
            return error.Interrupted;
        } else if (c == 4) { // Ctrl+D: the end of input, the run goes on
            stderr.writeStreamingAll(vm.io, "\n") catch return null;
            return null;
        } else if (c == 127 or c == 8) { // Backspace
            if (cursor > 0) {
                @memmove(buf[cursor - 1 .. len - 1], buf[cursor..len]);
                len -= 1;
                cursor -= 1;
                try refreshLine(vm, stderr, prompt, buf[0..len], cursor);
            }
        } else if (c == 27) { // ANSI Escape sequence parsing
            // An Esc alone: nothing follows soon
            var follows = [_]posix.pollfd{.{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 }};
            if ((posix.poll(&follows, ESCAPE_FOLLOW_MS) catch 0) == 0) continue;
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
                            try refreshLine(vm, stderr, prompt, buf[0..len], cursor);
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
                            try refreshLine(vm, stderr, prompt, buf[0..len], cursor);
                        }
                    } else if (seq2[0] == 'C') { // Right Arrow
                        if (cursor < len) {
                            cursor += 1;
                            try refreshLine(vm, stderr, prompt, buf[0..len], cursor);
                        }
                    } else if (seq2[0] == 'D') { // Left Arrow
                        if (cursor > 0) {
                            cursor -= 1;
                            try refreshLine(vm, stderr, prompt, buf[0..len], cursor);
                        }
                    }
                }
            }
        } else if (c >= 32 and c < 127) { // Standard printable characters
            if (len < buf.len) {
                @memmove(buf[cursor + 1 .. len + 1], buf[cursor..len]);
                buf[cursor] = c;
                len += 1;
                cursor += 1;
                try refreshLine(vm, stderr, prompt, buf[0..len], cursor);
            }
        }
    }
}

fn printLocals(vm: *VM, out: *std.Io.Writer) !void {
    try out.writeAll("--- Locals ---\n");

    if (vm.frames.items.len > 0) {
        const frame = &vm.frames.items[vm.frames.items.len - 1];
        if (frame.closure.function.chunk) |c_ptr| {
            const exec_chunk: *chunk.Chunk = @ptrCast(@alignCast(c_ptr));
            const locals = exec_chunk.local_names.items;
            for (locals, 0..) |name, i| {
                if (std.mem.eql(u8, name, "<anonymous>")) continue;
                const slot = frame.base_slot + i;
                if (slot < vm.stack_top) {
                    try out.print("{s}: ", .{name});
                    try vm.stack[slot].stringify(true, out);
                    try out.writeAll("\n");
                }
            }
        }
    }
    try out.writeAll("--------------\n");
}

fn printStack(vm: *VM, out: *std.Io.Writer) !void {
    try out.writeAll("--- VM Stack ---\n");
    var i: usize = vm.stack_top;
    while (i > 0) {
        i -= 1;
        try out.print("[{d:0>2}] ", .{i});
        try vm.stack[i].stringify(true, out);
        try out.writeAll("\n");
    }
    try out.writeAll("----------------\n");
}

fn printGlobals(vm: *VM, out: *std.Io.Writer) !void {
    try out.writeAll("--- User Globals ---\n");

    var it = vm.globals.iterator();
    while (it.next()) |entry| {
        const val = entry.value_ptr.*;
        if (val.isNative() or val.isClass() or val.isModule()) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "GC") or std.mem.eql(u8, entry.key_ptr.*, "Math")) continue;

        try out.print("{s}: ", .{entry.key_ptr.*});
        try val.stringify(true, out);
        try out.writeAll("\n");
    }
    try out.writeAll("--------------------\n");
}

/// `input` evaluated in the paused frame, its locals read and written back; the value, or why
/// there is none, on `out`.
fn evaluateContextually(vm: *VM, input: []const u8, out: *std.Io.Writer) !void {
    var doc = Document.parse(vm.allocator, input) catch return out.writeAll("Parse error.\n");
    defer doc.deinit();

    if (doc.diagnostics.len > 0) return out.writeAll("Syntax error.\n");

    var eval_chunk = chunk.Chunk.init();
    defer eval_chunk.free(vm.allocator);

    var comp = Compiler.forDocument(vm.allocator, &doc, &eval_chunk, vm);
    defer comp.deinit();

    // By index: `vm.frames` grows below (the REPL's own frame), which can move its items.
    const caller_frame_index = vm.frames.items.len - 1;
    const caller_frame = &vm.frames.items[caller_frame_index];
    var caller_locals: []const []const u8 = &.{};
    if (caller_frame.closure.function.chunk) |c_ptr| {
        const caller_chunk: *chunk.Chunk = @ptrCast(@alignCast(c_ptr));
        caller_locals = caller_chunk.local_names.items;
    }

    comp.seedLocals(caller_locals, 1);
    comp.compile(doc.tree.root) catch |err| {
        const where = comp.errorLine(vm.allocator, &doc.line_index);
        defer if (where) |w| vm.allocator.free(w);
        return out.print("Compile error: {s}\n", .{where orelse @errorName(err)});
    };

    const func = vm.gc.allocateFunction(vm) catch return;
    func.chunk = &eval_chunk;
    func.owns_chunk = false;
    func.local_count = eval_chunk.local_count;

    const target_depth = vm.frames.items.len;
    const repl_base_slot = vm.stack_top;
    // However it ends, the REPL's closure and locals go: an early return left them on the
    // stack, under the paused frame's values
    defer vm.shrinkStack(repl_base_slot);

    // The closure, the caller's locals and the padding, then the frame's own depth.
    vm.ensureStackCapacity(vm.stack_top + 1 + @max(caller_locals.len, func.local_count) + eval_chunk.max_stack_slots) catch return;
    // Rooted while the closure is allocated (which can collect), then swapped for it.
    vm.push(value.Value.initObj(&func.obj));
    const closure = vm.gc.allocateClosure(vm, func) catch return;
    vm.stack[repl_base_slot] = value.Value.initObj(&closure.obj);

    const caller_base_slot = caller_frame.base_slot;
    for (0..caller_locals.len) |i| {
        if (caller_base_slot + i < repl_base_slot) {
            vm.push(vm.stack[caller_base_slot + i]);
        } else {
            vm.push(value.Value.initNil());
        }
    }

    const copied_slots = caller_locals.len + 1;
    if (func.local_count > copied_slots) {
        const padding = func.local_count - copied_slots;
        vm.ensureStackCapacity(vm.stack_top + padding) catch {
            func.chunk = null;
            return;
        };
        for (0..padding) |_| vm.push(value.Value.initNil());
    }

    vm.frames.append(vm.allocator, .{
        .closure = closure,
        .ip = 0,
        .base_slot = repl_base_slot,
    }) catch {
        func.chunk = null;
        return;
    };

    const saved_step = vm.hooks.step;
    vm.hooks.setStep(false);
    // The paused script's rescues are none of what is typed here: an error would have unwound
    // into them, the paused frame jumping to its rescue
    const paused_rescues = vm.rescue_frames;
    vm.rescue_frames = .empty;
    const res = vm.runUntil(target_depth);
    vm.rescue_frames.deinit(vm.allocator);
    vm.rescue_frames = paused_rescues;
    // A lambda typed here holds this closure as its `self` and may outlive eval_chunk (see
    // VM.interpret); detached before anything allocates
    func.chunk = null;
    vm.hooks.setStep(saved_step);

    if (res == .ok) {
        const result_val = vm.pop();

        for (0..caller_locals.len) |i| {
            if (caller_base_slot + i < repl_base_slot) {
                vm.stack[caller_base_slot + i] = vm.stack[repl_base_slot + 1 + i];
            }
        }

        try result_val.stringify(true, out);
        try out.writeAll("\n");
    } else {
        defer vm.abandonNestedRun(target_depth, repl_base_slot);
        try out.print("Evaluation failed: {s}\n", .{vm.last_error orelse @tagName(res)});
    }
}

/// Stops the paused run, as a failure: `.quit` and Ctrl+C. It used to exit the process, with
/// success, its outputs unwritten and nothing it holds released.
fn stopRun(vm: *VM, out: *std.Io.Writer) void {
    out.writeAll("Stopping the run.\n") catch {};
    vm.cancel_token.store(true, .release);
}

/// The terminal's lines, edited and recalled from the history (`readLine`).
const Terminal = struct {
    history: History = .{},

    pub fn next(self: *Terminal, vm: *VM) !?[]const u8 {
        const line = try readLine(vm, PROMPT, &self.history) orelse return null;
        const typed = std.mem.trim(u8, line, " \r\n\t");
        if (typed.len > 0) self.history.push(vm.allocator, typed) catch |err| log.warn("History push failed: {}", .{err});
        return line;
    }
};

pub fn debuggerLoop(vm: *VM) void {
    // The prompt has the terminal: the progress line would be drawn over it
    progress.pause();
    defer progress.unpause();
    var terminal: Terminal = .{};
    defer terminal.history.deinit(vm.allocator);
    // Streaming, as log.printStderr writes: stderr may be a file it appends to
    var stderr = std.Io.File.stderr().writerStreaming(vm.io, &.{});
    session(vm, &terminal, &stderr.interface);
}

/// The debugger at a pause: each line `lines.next(vm)` gives (owned by the VM's allocator; null
/// at their end, error.Interrupted for Ctrl+C) a command or an expression, answered on `out`,
/// until one resumes the run, steps it or stops it.
pub fn session(vm: *VM, lines: anytype, out: *std.Io.Writer) void {
    out.writeAll("\n===   KupCAD Debugger ===\nCommands: .step, .continue, .locals, .stack, .globals, .help\n") catch return;
    if (vm.currentPosition()) |at| out.print("Break at line {d}, col {d}\n", .{ at.line, at.column }) catch return;

    while (true) {
        const input = lines.next(vm) catch |err| {
            if (err == error.Interrupted) {
                stopRun(vm, out);
                break;
            }
            log.err("Debugger input error: {}", .{err});
            break;
        } orelse break;
        defer vm.allocator.free(input);

        const trimmed = std.mem.trim(u8, input, " \r\n\t");
        if (trimmed.len == 0) continue;

        if (isCommand(trimmed, ".c", ".continue")) {
            out.writeAll("Resuming execution...\n\n") catch return;
            vm.hooks.setStep(false);
            break;
        } else if (isCommand(trimmed, ".s", ".step")) {
            vm.hooks.setStep(true);
            break;
        } else if (isCommand(trimmed, ".q", ".exit") or std.mem.eql(u8, trimmed, ".quit")) {
            stopRun(vm, out);
            break;
        }
        const answered = if (isCommand(trimmed, ".l", ".locals"))
            printLocals(vm, out)
        else if (isCommand(trimmed, ".st", ".stack"))
            printStack(vm, out)
        else if (isCommand(trimmed, ".g", ".globals"))
            printGlobals(vm, out)
        else if (isCommand(trimmed, ".h", ".help"))
            out.writeAll(HELP)
        else
            evaluateContextually(vm, trimmed, out);
        answered catch return;
    }
}

/// Whether `input` is a command, by its short name or its long one.
fn isCommand(input: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, input, short) or std.mem.eql(u8, input, long);
}

/// The debugger for a host run from a terminal (`kupcad build`, `kupcad watch`), or null
/// when stdin is not one: then no one could answer its prompt.
pub fn terminalDebugger(io: std.Io) ?*const fn (vm: *VM) void {
    const interactive = std.Io.File.stdin().isTty(io) catch false;
    return if (interactive) debuggerLoop else null;
}
