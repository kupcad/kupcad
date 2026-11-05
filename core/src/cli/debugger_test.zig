//! The debugger (debugger.zig) at a script's pause, given its lines as a terminal would and its
//! answers kept, and the history of what was typed.

const std = @import("std");
const testing = std.testing;
const debugger = @import("debugger.zig");
const support = @import("../test_support.zig");
const VM = @import("../vm/vm.zig").VM;
const InterpretResult = @import("../vm/vm.zig").InterpretResult;
const chunk = @import("../vm/chunk.zig");
const Document = @import("../frontend/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;

const PAUSED_IN_A_METHOD =
    \\def f(x)
    \\  y = x * 2
    \\  debugger
    \\  y + 1
    \\end
    \\r = f(5)
;

/// Lines given in turn, as the terminal gives them (owned by the VM's allocator); Ctrl+C for
/// INTERRUPT.
const Lines = struct {
    lines: []const []const u8,
    at: usize = 0,

    const INTERRUPT = "<Ctrl+C>";

    pub fn next(self: *Lines, vm: *VM) !?[]const u8 {
        if (self.at == self.lines.len) return null;
        defer self.at += 1;
        if (std.mem.eql(u8, self.lines[self.at], INTERRUPT)) return error.Interrupted;
        return try vm.allocator.dupe(u8, self.lines[self.at]);
    }
};

/// A VM whose debugger is given `lines` and answers into `out`, found by the VM
/// (@fieldParentPtr) as the handler is given it alone.
const Paused = struct {
    vm: VM,
    lines: Lines,
    out: std.Io.Writer.Allocating,
    pauses: usize = 0,

    fn open(vm: *VM) void {
        const self: *Paused = @fieldParentPtr("vm", vm);
        self.pauses += 1;
        debugger.session(vm, &self.lines, &self.out.writer);
    }

    fn deinit(self: *Paused) void {
        self.out.deinit();
        self.vm.deinit();
    }
};

/// Runs `source` with its debugger given `lines`, the lines of the source known to the VM, as
/// the CLI makes them, so a pause says where it is.
fn runPaused(paused: *Paused, source: []const u8) !InterpretResult {
    paused.vm.debugger_handler = Paused.open;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    paused.vm.line_index = &doc.line_index;
    defer paused.vm.line_index = null;
    var code = chunk.Chunk.init();
    defer code.free(testing.allocator);
    var compiler = Compiler.forDocument(testing.allocator, &doc, &code, &paused.vm);
    defer compiler.deinit();
    try compiler.compile(doc.tree.root);
    return paused.vm.interpret(&code);
}

fn expectSaid(paused: *Paused, text: []const u8) !void {
    if (std.mem.find(u8, paused.out.written(), text) == null) {
        std.debug.print("expected the debugger to say: {s}\nit said:\n{s}\n", .{ text, paused.out.written() });
        return error.TestUnexpectedResult;
    }
}

test "debugger: the paused frame's locals are listed, evaluated with, and written back" {
    var paused: Paused = .{ .vm = try support.initVm(), .lines = .{ .lines = &.{ ".locals", "y * 10", "y = 7", ".continue" } }, .out = .init(testing.allocator) };
    defer paused.deinit();
    try testing.expectEqual(.ok, try runPaused(&paused, PAUSED_IN_A_METHOD));
    try expectSaid(&paused, "Break at line 3");
    try expectSaid(&paused, "x: 5\ny: 10\n");
    try expectSaid(&paused, "100\n");
    try expectSaid(&paused, "Resuming execution...");
    // y set to 7 at the pause: f gives 8
    try testing.expectEqual(@as(f64, 8), paused.vm.globals.get("r").?.asNumber());
}

test "debugger: what doesn't read or run is said so, and the pause goes on" {
    var paused: Paused = .{ .vm = try support.initVm(), .lines = .{ .lines = &.{ "1 +", "y.no_such_method", "", ".globals", ".help", ".c" } }, .out = .init(testing.allocator) };
    defer paused.deinit();
    try testing.expectEqual(.ok, try runPaused(&paused, "g = 3\n" ++ PAUSED_IN_A_METHOD));
    try expectSaid(&paused, "Syntax error.\n");
    try expectSaid(&paused, "Evaluation failed: NoMethodError");
    try expectSaid(&paused, "g: 3\n");
    try expectSaid(&paused, ".q, .exit      Stop the run");
    try testing.expectEqual(@as(f64, 11), paused.vm.globals.get("r").?.asNumber());
}

test "debugger: .quit and Ctrl+C stop the run as a failure, and its end resumes it" {
    for ([_][]const u8{ ".quit", Lines.INTERRUPT }) |stop| {
        var paused: Paused = .{ .vm = try support.initVm(), .lines = .{ .lines = &.{stop} }, .out = .init(testing.allocator) };
        defer paused.deinit();
        try testing.expect(try runPaused(&paused, PAUSED_IN_A_METHOD) != .ok);
        try expectSaid(&paused, "Stopping the run.\n");
        try testing.expect(paused.vm.globals.get("r") == null);
    }
    // No more lines (Ctrl+D): the run goes on
    var ended: Paused = .{ .vm = try support.initVm(), .lines = .{ .lines = &.{} }, .out = .init(testing.allocator) };
    defer ended.deinit();
    try testing.expectEqual(.ok, try runPaused(&ended, PAUSED_IN_A_METHOD));
    try testing.expectEqual(@as(f64, 11), ended.vm.globals.get("r").?.asNumber());
}

test "debugger: .step pauses again at the next line" {
    var paused: Paused = .{ .vm = try support.initVm(), .lines = .{ .lines = &.{ ".step", ".locals", ".continue" } }, .out = .init(testing.allocator) };
    defer paused.deinit();
    try testing.expectEqual(.ok, try runPaused(&paused, PAUSED_IN_A_METHOD));
    try testing.expectEqual(@as(usize, 2), paused.pauses);
    try expectSaid(&paused, "Break at line 4");
}

test "debugger: the history keeps what was typed, once in a row, the newest last, at most 100" {
    var history: debugger.History = .{};
    defer history.deinit(testing.allocator);
    try history.push(testing.allocator, "a");
    try history.push(testing.allocator, "a");
    try history.push(testing.allocator, "");
    try history.push(testing.allocator, "b");
    try testing.expectEqual(@as(usize, 2), history.count());
    try testing.expectEqualStrings("b", history.get(1));

    var buf: [16]u8 = undefined;
    for (0..150) |i| try history.push(testing.allocator, try std.fmt.bufPrint(&buf, "line {d}", .{i}));
    try testing.expectEqual(@as(usize, 100), history.count());
    try testing.expectEqualStrings("line 50", history.get(0));
    try testing.expectEqualStrings("line 149", history.get(99));
}
