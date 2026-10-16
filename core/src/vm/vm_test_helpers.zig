//! What the VM test files (vm_*_test.zig) share: running a hand-built chunk with its stack
//! checked, and compiling and running a script (under GC stress too) and reading a global.

const std = @import("std");
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const resolver = @import("../core/resolver.zig");
const value = @import("../core/value.zig");
const kernel = @import("../kernel/kernel.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../core/document.zig").Document;
const Profiler = @import("profiler.zig").Profiler;
const geom = @import("../kernel/geometry_handle.zig");
const VM = @import("vm.zig").VM;
const InterpretResult = @import("vm.zig").InterpretResult;
const ErrorKind = @import("error_kind.zig").ErrorKind;

/// Runs a chunk and enforces strict stack equilibrium checks
pub fn executeAndAssertStack(vm: *VM, chunk_ptr: *chunk.Chunk, expected_stack_top: usize) !value.Value {
    // Turn on the brutal GC mode for tests
    vm.zealous_gc = true;

    const result = vm.interpret(chunk_ptr);
    try testing.expectEqual(.ok, result);

    // Catch stack leaks immediately
    try testing.expectEqual(expected_stack_top, vm.stack_top);

    return if (vm.stack_top > 0) vm.stack[vm.stack_top - 1] else value.Value.initNil();
}

// --- Unwinding, native boundaries, globals and conversions (Oct 2026 audit) ---

/// Parses + compiles `source` into `out_chunk` and interprets it.
pub fn compileAndRun(vm: *VM, out_chunk: *chunk.Chunk, source: []const u8) !InterpretResult {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var comp = Compiler.forDocument(testing.allocator, &doc, out_chunk, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    return vm.interpret(out_chunk);
}

pub fn expectGlobalString(vm: *VM, name: []const u8, expected: []const u8) !void {
    const val = vm.globals.get(name) orelse return error.MissingGlobal;
    try testing.expect(val.isString());
    try testing.expectEqualStrings(expected, val.asString().chars);
}

// Exception construction under a collecting GC

/// compileAndRun with a collection on every allocation. Stress is switched off
/// again before returning so the test's `vm.deinit` runs normally.
pub fn compileAndRunStressed(vm: *VM, out_chunk: *chunk.Chunk, source: []const u8) !InterpretResult {
    vm.gc.stress = true;
    defer vm.gc.stress = false;
    return compileAndRun(vm, out_chunk, source);
}

/// `op` (op_get_global or op_define_global) naming constant `name_idx`, with the global
/// cache the instruction carries, as the compiler emits it (emitter.emitGetGlobal).
pub fn writeGlobalOp(c: *chunk.Chunk, op: chunk.OpCode, name_idx: usize) !void {
    try c.writeOp(testing.allocator, op, 0);
    try c.write(testing.allocator, @intCast(name_idx), 0);
    const cache = try c.addGlobalCache(testing.allocator);
    try c.write(testing.allocator, @intCast(cache >> 8), 0);
    try c.write(testing.allocator, @intCast(cache & 0xff), 0);
}
