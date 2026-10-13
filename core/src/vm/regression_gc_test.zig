//! Regression tests for issues found in the Oct 2026 audit.

const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const verifier = @import("verifier.zig");
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../core/document.zig").Document;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const VM = @import("vm.zig").VM;
const InterpretResult = @import("vm.zig").InterpretResult;

/// Parses + compiles `source` into `out_chunk` and interprets it.
fn compileAndRun(vm: *VM, out_chunk: *chunk.Chunk, source: []const u8) !InterpretResult {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, out_chunk, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    return vm.interpret(out_chunk);
}

fn expectGlobalString(vm: *VM, name: []const u8, expected: []const u8) !void {
    const val = vm.globals.get(name) orelse return error.MissingGlobal;
    try testing.expect(val.isString());
    try testing.expectEqualStrings(expected, val.asString().chars);
}

// --- Finding 1: constants of a chunk under compilation must be GC roots ---

test "GC regression: string constants survive collections triggered during compilation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Every later literal allocates and (under stress) collects; before the fix
    // "FIRST" was referenced only by the unrooted top-level chunk and got swept.
    vm.gc.stress = true;
    const source =
        \\first = "FIRST"
        \\b = "second literal"
        \\c = "third literal"
        \\d = "fourth literal"
        \\result = first
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // A collection between compile() and interpret() must not sweep constants either
    vm.gc.collectGarbage(&vm, false);
    vm.gc.stress = false;

    try testing.expectEqual(.ok, vm.interpret(&out_chunk));
    try expectGlobalString(&vm, "result", "FIRST");
}

test "GC regression: chunk registry is cleared when a chunk is freed" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    {
        var c = chunk.Chunk.init();
        defer c.free(testing.allocator);
        try vm.gc.trackChunk(&c);
        try testing.expectEqual(@as(usize, 1), vm.gc.live_chunks.chunks.items.len);
    }
    try testing.expectEqual(@as(usize, 0), vm.gc.live_chunks.chunks.items.len);
}

// --- Finding 2: unwind_stack protocol ---

test "GC regression: stale unwind entry is not restored by an outer native boundary" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // The first exception is handled without crossing a native and used to leave
    // its entry behind; the outer `each` then restored "stale" instead of "inner".
    const source =
        \\def deep(a, b, c, d, e, f)
        \\  g = 1
        \\  h = 2
        \\  begin
        \\    raise "stale"
        \\  rescue => err
        \\    nil
        \\  end
        \\  42
        \\end
        \\deep(1, 2, 3, 4, 5, 6)
        \\result = begin
        \\  [1].each { |a| [2].each { |b| raise "inner" } }
        \\rescue => e
        \\  e.message
        \\end
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    try expectGlobalString(&vm, "result", "inner");
    try testing.expectEqual(@as(usize, 0), vm.unwind_stack.items.len);
}

var probed_unwind_len: usize = 0;
fn probeUnwindLen(v_ptr: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const vm_ptr: *VM = @ptrCast(@alignCast(v_ptr));
    probed_unwind_len = @max(probed_unwind_len, vm_ptr.unwind_stack.items.len);
    return value.Value.initNil();
}

test "GC regression: handled exceptions do not accumulate unwind entries" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    const native_obj = try vm.gc.allocateNative(&vm, probeUnwindLen);
    try vm.globals.put(vm.gc.trackingAllocator(), "probe_unwind", value.Value.initObj(&native_obj.obj));
    probed_unwind_len = 0;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const source =
        \\i = 0
        \\while i < 200
        \\  begin
        \\    raise "x"
        \\  rescue => e
        \\  end
        \\  i = i + 1
        \\end
        \\probe_unwind()
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    // Previously one entry per raise (200), each pinning its exception as a GC root
    try testing.expect(probed_unwind_len <= 1);
}

// --- Finding 4: bound native methods must use the unwind protocol ---

test "GC regression: exception raised in a block passed to a bound native method is rescuable" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const source =
        \\m = [1, 2].method(:each)
        \\result = begin
        \\  m.call { |x| raise "from bound" }
        \\  "not rescued"
        \\rescue => e
        \\  e.message
        \\end
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    try expectGlobalString(&vm, "result", "from bound");
}

// --- Finding 3: op_import rooting, cache marking, chunk leak ---

test "GC regression: cached module results survive GC and re-import" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    try mem_vfs.vfs().writeFile("./mod.kup", "Payload = [\"payload\", \"more\"]\nexport Payload");

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.vfs = mem_vfs.vfs();
    vm.mute_errors = true;

    var first_chunk = chunk.Chunk.init();
    defer first_chunk.free(testing.allocator);
    // Stress GC also covers allocateClosure collecting the module's unrooted function
    vm.gc.stress = true;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &first_chunk, "import \"./mod.kup\"\nnil"));

    // The export module is now referenced only by the import cache
    vm.gc.collectGarbage(&vm, false);
    vm.gc.stress = false;

    var second_chunk = chunk.Chunk.init();
    defer second_chunk.free(testing.allocator);
    try testing.expectEqual(.ok, try compileAndRun(&vm, &second_chunk, "import { Payload } from \"./mod.kup\"\nresult = Payload[0]"));
    try expectGlobalString(&vm, "result", "payload");
}

test "GC regression: import whose compilation fails does not leak its chunk" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    // Parses cleanly but fails to compile (assigning to the protected intrinsic `cube`)
    try mem_vfs.vfs().writeFile("./bad.kup", "x = \"keep\"\ncube = 1");

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.vfs = mem_vfs.vfs();
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    const source =
        \\result = begin
        \\  import "./bad.kup"
        \\  "imported"
        \\rescue => e
        \\  e.message
        \\end
    ;
    // testing.allocator reports the heap chunk as leaked if it is not freed
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    const msg = vm.globals.get("result") orelse return error.MissingGlobal;
    try testing.expect(std.mem.startsWith(u8, msg.asString().chars, "ImportError: Compilation failed"));
}

// --- Finding 5: verifier coverage ---

test "GC regression: verifier rejects out-of-range constant indexes" {
    const ops = [_]chunk.OpCode{ .op_constant, .op_get_global, .op_define_global, .op_set_global, .op_import, .op_class, .op_method };
    for (ops) |op| {
        var c = chunk.Chunk.init();
        defer c.free(testing.allocator);
        try c.writeOp(testing.allocator, op, 0);
        try c.write(testing.allocator, 7, 0); // no constants at all
        try c.writeOp(testing.allocator, .op_return, 0);
        try testing.expectError(error.InvalidConstantIndex, verifier.verifyChunk(&c));
    }

    var wide = chunk.Chunk.init();
    defer wide.free(testing.allocator);
    _ = try wide.addConstant(testing.allocator, value.Value.initNumber(1));
    try wide.writeOp(testing.allocator, .op_constant_wide, 0);
    try wide.write(testing.allocator, 0x01, 0);
    try wide.write(testing.allocator, 0x00, 0);
    try wide.writeOp(testing.allocator, .op_return, 0);
    try testing.expectError(error.InvalidConstantIndex, verifier.verifyChunk(&wide));
}

test "GC regression: verifier rejects jumps into the middle of an instruction" {
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);
    _ = try c.addConstant(testing.allocator, value.Value.initNumber(1));

    // op_jump +1 lands on the operand byte of the following op_constant
    try c.writeOp(testing.allocator, .op_jump, 0);
    for ([_]u8{ 0, 0, 0, 1 }) |b| try c.write(testing.allocator, b, 0);
    try c.writeOp(testing.allocator, .op_constant, 0);
    try c.write(testing.allocator, 0, 0);
    try c.writeOp(testing.allocator, .op_return, 0);
    try testing.expectError(error.InvalidJumpOffset, verifier.verifyChunk(&c));

    // The same jump to an instruction boundary (+2) is accepted
    c.code.items[4] = 2;
    try verifier.verifyChunk(&c);
}

test "GC regression: interpret refuses malformed bytecode instead of indexing out of bounds" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.mute_errors = true;

    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);
    try c.writeOp(testing.allocator, .op_constant, 0);
    try c.write(testing.allocator, 200, 0);
    try c.writeOp(testing.allocator, .op_return, 0);

    try testing.expectEqual(.compile_error, vm.interpret(&c));
}

// --- Double throw: a native that raised must not get a second "Native Execution Error" ---

test "GC regression: exception raised by a native is thrown once and execution continues" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Array#reduce without a block calls throwDynamicError and then returns
    // error.RuntimeError; executeNative used to raise again from the handler.
    const source =
        \\inner = 0
        \\outer = 0
        \\msg = nil
        \\begin
        \\  begin
        \\    [].reduce
        \\  rescue => e
        \\    inner = inner + 1
        \\    msg = e.message
        \\  end
        \\rescue => e2
        \\  outer = outer + 1
        \\end
        \\after = "continued"
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    try testing.expectEqual(@as(f64, 1), vm.globals.get("inner").?.asNumber());
    try testing.expectEqual(@as(f64, 0), vm.globals.get("outer").?.asNumber());
    const msg = vm.globals.get("msg").?;
    try testing.expect(msg.isString());
    try testing.expect(std.mem.indexOf(u8, msg.asString().chars, "reduce requires a block") != null);
    try expectGlobalString(&vm, "after", "continued");
}
