//! Helpers shared by tests across the codebase.

const std = @import("std");

/// Call first in a test that drives a failure path whose warning is the expected outcome
/// (a rejected lockfile, a refused connection). The test runner prints every warning a
/// test logs, so these expected ones buried real problems and made `zig build test` print
/// a "failed command" line though every test passed. The runner restores the level before
/// each test; errors are still counted and still fail the test.
pub fn expectWarnings() void {
    std.testing.log_level = .err;
}

const VM = @import("vm/vm.zig").VM;
const InterpretResult = @import("vm/vm.zig").InterpretResult;
const chunk = @import("vm/chunk.zig");
const Document = @import("core/document.zig").Document;
const Compiler = @import("compiler/compiler.zig").Compiler;
const registry = @import("stdlib/registry.zig");
const ErrorKind = @import("vm/error_kind.zig").ErrorKind;
const value = @import("core/value.zig");
const disassembler = @import("tools/dev/disassembler.zig");

/// Kernel-computed numbers (volumes, bounds) are compared with this absolute tolerance.
pub const NUMBER_TOLERANCE = 1e-9;

/// A VM with the standard library, muted: its errors are what a test expects, and the
/// test runner treats logged errors as failures. Script output (puts) stays out of the log.
pub fn initVm() !VM {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    errdefer vm.deinit();
    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);
    vm.host.print_handler = null;
    return vm;
}

/// Compiles and runs `source` on `vm`. A syntax error fails the test.
pub fn runOn(vm: *VM, source: []const u8) !InterpretResult {
    return runWith(std.testing.allocator, vm, source);
}

/// `runOn`, parsing and compiling with `allocator` (the one `vm` was made with, in a test
/// that fails allocations).
pub fn runWith(allocator: std.mem.Allocator, vm: *VM, source: []const u8) !InterpretResult {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    if (doc.diagnostics.len > 0) {
        std.debug.print("syntax error in test script: {s}\n", .{doc.diagnostics[0].message});
        return error.SyntaxError;
    }
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(allocator);
    var comp = Compiler.forDocument(allocator, &doc, &out_chunk, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    return vm.interpret(&out_chunk);
}

/// `rescue <Kind> => e` for every runtime error kind, each giving "<Kind>: <message>",
/// so an expected string checks the error's class as well as its message.
const RESCUE_BY_KIND = blk: {
    var text: []const u8 = "";
    for (std.meta.fieldNames(ErrorKind)) |kind| text = text ++ "rescue " ++ kind ++ " => e\n  \"" ++ kind ++ ": \" + e.message\n";
    break :blk text;
};

/// Wraps `src` so the global `r` holds the rescued error as "<Kind>: <message>", or
/// "no error" when nothing was raised.
pub fn rescued(comptime src: []const u8) []const u8 {
    return "r = begin\n  " ++ src ++ "\n  \"no error\"\n" ++ RESCUE_BY_KIND ++ "end";
}

/// What a script should leave in the global `r`.
pub const Expected = union(enum) {
    nums: []const f64,
    num: f64,
    boolean: bool,
    str: []const u8,
    nil,
};

pub const ScriptCase = struct {
    src: []const u8,
    expected: Expected,
    /// Collect before every instruction, so a value a native forgot to root is swept at once.
    gc_stress: bool = false,
};

/// Runs each script on a fresh VM and checks its `r`; names the offending script on failure.
pub fn expectScripts(cases: []const ScriptCase) !void {
    for (cases) |case| {
        errdefer std.debug.print("script:\n{s}\n", .{case.src});
        var vm = try initVm();
        defer vm.deinit();
        vm.hooks.setZealousGc(case.gc_stress);
        try std.testing.expectEqual(InterpretResult.ok, try runOn(&vm, case.src));
        const r = vm.globals.get("r") orelse return error.MissingGlobal;
        try expectValue(case.expected, r);
    }
}

/// Runs each script, expecting it to fail with `expected` (as a whole run: an uncaught error).
pub fn expectRuns(expected: InterpretResult, sources: []const []const u8) !void {
    for (sources) |src| {
        errdefer std.debug.print("script:\n{s}\n", .{src});
        var vm = try initVm();
        defer vm.deinit();
        try std.testing.expectEqual(expected, try runOn(&vm, src));
    }
}

pub fn expectValue(expected: Expected, r: value.Value) !void {
    switch (expected) {
        .nums => |want| {
            try std.testing.expect(r.isArray());
            const items = r.asArray().items.items;
            try std.testing.expectEqual(want.len, items.len);
            for (want, items) |w, item| {
                try std.testing.expect(item.isNumber());
                try std.testing.expectApproxEqAbs(w, item.asNumber(), NUMBER_TOLERANCE);
            }
        },
        .num => |want| {
            try std.testing.expect(r.isNumber());
            try std.testing.expectApproxEqAbs(want, r.asNumber(), NUMBER_TOLERANCE);
        },
        .boolean => |want| {
            try std.testing.expect(r.isBool());
            try std.testing.expectEqual(want, r.asBool());
        },
        .str => |want| {
            try std.testing.expect(r.isString());
            try std.testing.expectEqualStrings(want, r.asString().chars);
        },
        .nil => try std.testing.expect(r.isNil()),
    }
}

/// Runs `run(context, allocator)` once for every allocation it makes, failing that one
/// allocation. Each run must free everything it allocated, and must either fail or give
/// exactly what a run without failures gives (`run` returns its result as bytes it
/// allocated): a run that swallowed a failure and went on with less would hide a bug.
pub fn expectAllocationFailuresHandled(context: anytype, comptime run: fn (@TypeOf(context), std.mem.Allocator) anyerror![]const u8) !void {
    const expected = try run(context, std.testing.allocator);
    defer std.testing.allocator.free(expected);
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        errdefer std.debug.print("with allocation {d} failing\n", .{fail_index});
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        const done = if (run(context, allocator)) |bytes| blk: {
            defer allocator.free(bytes);
            if (failing.has_induced_failure) try std.testing.expectEqualStrings(expected, bytes);
            // A run that reached no failing allocation has seen every allocation fail.
            break :blk !failing.has_induced_failure;
        } else |err| blk: {
            if (!failing.has_induced_failure) return err; // a failure that wasn't induced
            break :blk false;
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (done) return;
    }
}

/// The opcodes `c` starts with must be `expected`, in order, whatever their operands
/// (instructions are stepped over with the disassembler, which knows each one's length:
/// byte offsets broke whenever an operand changed).
pub fn expectOps(c: *const chunk.Chunk, expected: []const chunk.OpCode) !void {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var offset: usize = 0;
    for (expected, 0..) |op, n| {
        errdefer std.debug.print("instruction {d} at byte {d}\n", .{ n, offset });
        try std.testing.expect(offset < c.code.items.len);
        try std.testing.expectEqual(op, @as(chunk.OpCode, @fromBackingInt(c.code.items[offset])));
        offset = try disassembler.disassembleInstruction(c, offset, &sink.writer);
    }
}

/// Where the `n`th instruction of `c` starts.
pub fn instructionAt(c: *const chunk.Chunk, n: usize) !usize {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var offset: usize = 0;
    for (0..n) |_| offset = try disassembler.disassembleInstruction(c, offset, &sink.writer);
    return offset;
}
