//! Regression tests for issues found in the Oct 2026 audit.

const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
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
    // Once the script closure roots the chunk, interpret drops the compile-time registration
    try testing.expectEqual(@as(usize, 0), vm.gc.live_chunks.chunks.items.len);
}

test "GC regression: chunk registry never holds a freed chunk or outlives its VM" {
    {
        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();

        var c = chunk.Chunk.init();
        try vm.gc.trackChunk(&c);
        try testing.expectEqual(@as(usize, 1), vm.gc.live_chunks.chunks.items.len);
        c.free(testing.allocator);
        try testing.expectEqual(@as(usize, 0), vm.gc.live_chunks.chunks.items.len);
    }

    // A chunk freed after its VM (common for stack chunks) must not touch the destroyed registry
    var c = chunk.Chunk.init();
    defer c.free(testing.allocator);
    var vm = try VM.init(testing.allocator, testing.io);
    {
        errdefer vm.deinit();
        try vm.gc.trackChunk(&c);
    }
    vm.deinit();
    try testing.expect(c.registry == null);
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
    // Previously one entry per raise (200), each pinning its exception as a GC root.
    // Probed mid-run: interpret() clears the stack on exit, so checking afterwards proves nothing.
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
    // A cache hit, not a re-import: the key must not borrow the (swept) path constant
    try testing.expectEqual(@as(u32, 1), vm.modules.count());
}

test "GC regression: exception raised inside an imported module is rescued by the importer" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    try mem_vfs.vfs().writeFile("./boom.kup", "raise \"module failed\"");

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.vfs = mem_vfs.vfs();
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    // The `begin` sits at the import's stack slot, so a rescued unwind leaves exactly
    // one value above the module closure's base, the same shape as a normal return.
    // The import must still be seen as failed: not cached, and raising again when retried.
    const source =
        \\first = begin
        \\  import "./boom.kup"
        \\  "not rescued"
        \\rescue => e
        \\  e.message
        \\end
        \\second = begin
        \\  import "./boom.kup"
        \\  "served from cache"
        \\rescue => e
        \\  e.message
        \\end
        \\after = "continued"
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    try expectGlobalString(&vm, "first", "module failed");
    try expectGlobalString(&vm, "second", "module failed");
    try expectGlobalString(&vm, "after", "continued");
    try testing.expectEqual(@as(u32, 0), vm.modules.count());
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

// --- Finding 5: verifier runs before execution (opcode-level checks live in verifier_test.zig) ---

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

// --- Double throw: a native that raised must not get a second "Native ... Error" ---

const native_raise_message = "raised by native";

/// Raises a rescuable exception, then fails with an ordinary error as stdlib natives do.
fn raiseThenFail(v_ptr: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const vm_ptr: *VM = @ptrCast(@alignCast(v_ptr));
    _ = vm_ptr.throwDynamicError(native_raise_message, .{});
    return error.RuntimeError;
}

fn raiseThenFailInvoke(vm_ptr: *VM, receiver: value.Value, method_name: []const u8, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = receiver;
    _ = method_name;
    return raiseThenFail(vm_ptr, arg_count, args);
}

/// Defines `RaisingInit`, a class whose native `initialize` raises.
fn defineRaisingInitClass(vm: *VM) !void {
    const name_val = try vm.allocateString("RaisingInit");
    vm.push(name_val);
    defer _ = vm.pop();
    const class_obj = try vm.gc.allocateClass(vm, name_val.asString(), vm.object_class);
    try vm.globals.put(vm.allocator, "RaisingInit", value.Value.initObj(&class_obj.obj));

    const init_fn = try vm.gc.allocateNative(vm, raiseThenFail);
    const init_key = try vm.allocateString("initialize");
    try class_obj.methods.put(vm.gc.trackingAllocator(), init_key, value.Value.initObj(&init_fn.obj));
}

test "GC regression: exception raised by a native is thrown once and execution continues" {
    // Each native boundary that raises: a stdlib method (Array#reduce without a block),
    // a native constructor, and the host invoke handler (CAD kernel methods).
    const cases = [_]struct { expr: []const u8, message: []const u8 }{
        .{ .expr = "[].reduce", .message = "reduce requires a block" },
        .{ .expr = "RaisingInit.new", .message = native_raise_message },
        .{ .expr = "5.not_a_method", .message = native_raise_message },
    };
    for (cases) |case| {
        errdefer std.debug.print("failing case: {s}\n", .{case.expr});
        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        try registry.registerStandardLibrary(&vm);
        vm.mute_errors = true;
        try defineRaisingInitClass(&vm);
        vm.host.invoke_handler = raiseThenFailInvoke;

        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(testing.allocator);

        const source = try std.fmt.allocPrint(testing.allocator,
            \\inner = 0
            \\outer = 0
            \\msg = nil
            \\begin
            \\  begin
            \\    {s}
            \\  rescue => e
            \\    inner = inner + 1
            \\    msg = e.message
            \\  end
            \\rescue => e2
            \\  outer = outer + 1
            \\end
            \\after = "continued"
        , .{case.expr});
        defer testing.allocator.free(source);

        try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
        try testing.expectEqual(@as(f64, 1), vm.globals.get("inner").?.asNumber());
        try testing.expectEqual(@as(f64, 0), vm.globals.get("outer").?.asNumber());
        const msg = vm.globals.get("msg").?;
        try testing.expect(msg.isString());
        try testing.expect(std.mem.indexOf(u8, msg.asString().chars, case.message) != null);
        try expectGlobalString(&vm, "after", "continued");
    }
}

// --- Global keys must outlive the chunk whose constant named them ---

test "GC regression: redefining a global on a reused VM after its defining chunk was freed" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    // Each run gets its own chunk, freed afterwards, as the daemon and LSP do
    const runs = [_][]const u8{
        "shared_global = \"first run\"",
        "padding = \"0123456789abcdef0123456789abcdef\"\nshared_global = \"second run\"",
        "result = shared_global",
    };
    var global_count: ?u32 = null;
    for (runs) |source| {
        {
            var run_chunk = chunk.Chunk.init();
            defer run_chunk.free(testing.allocator);
            try testing.expectEqual(.ok, try compileAndRun(&vm, &run_chunk, source));
        }
        vm.resetStack();
        // Sweeps the run's constants, including the string naming `shared_global`
        vm.gc.collectGarbage(&vm, false);
        if (global_count == null) global_count = vm.globals.count();
    }
    try expectGlobalString(&vm, "result", "second run");
    // A dangling key no longer matches its name, so redefining it used to add a duplicate
    try testing.expectEqual(global_count.? + 2, vm.globals.count());
}

// --- Calling a class directly runs a native initialize ---

test "GC regression: class with a native initialize can be called directly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    // Exception's initialize is a native; the call-syntax path used to cast it to a
    // closure. A closure initialize must yield the instance there too, as with `.new`.
    const source =
        \\class Box
        \\  def initialize(w)
        \\    @w = w
        \\  end
        \\  def width
        \\    @w
        \\  end
        \\end
        \\box_width = Box(7).width
        \\err = ArgumentError("bad width")
        \\direct = err.message
        \\is_instance = err.is_a?(ArgumentError)
        \\raised = begin
        \\  raise ArgumentError("bad height")
        \\rescue ArgumentError => e
        \\  e.message
        \\end
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    try testing.expectEqual(@as(f64, 7), vm.globals.get("box_width").?.asNumber());
    try expectGlobalString(&vm, "direct", "bad width");
    try testing.expect(vm.globals.get("is_instance").?.asBool());
    try expectGlobalString(&vm, "raised", "bad height");
}

// --- Number -> integer conversions: NaN, inf and out-of-range operands ---

test "GC regression: bitwise operands and array indexes reject non-integral numbers" {
    // `message` set: the expression must raise that; otherwise it evaluates to `number`.
    // Each case used to reach @intFromFloat unchecked (a panic in Debug, UB in release).
    const cases = [_]struct { expr: []const u8, number: f64 = 0, message: ?[]const u8 = null }{
        // Addition shared the bitwise path and converted its operands too
        .{ .expr = "1e300 + huge", .number = 2e300 },
        .{ .expr = "inf_v - 1", .number = std.math.inf(f64) },
        .{ .expr = "inf_v | 1", .message = "RangeError" },
        // inf - inf is the NaN that reaches bytecode (multiply/divide raise on NaN)
        .{ .expr = "(inf_v - inf_v) ^ 1", .message = "RangeError" },
        .{ .expr = "1 & huge", .message = "RangeError" },
        .{ .expr = "1 << 64", .message = "Shift count" },
        .{ .expr = "1 >> -1", .message = "Shift count" },
        .{ .expr = "1 << inf_v", .message = "RangeError" },
        // In-range behaviour is unchanged: truncation, wrapping `<<`, arithmetic `>>`
        .{ .expr = "6 & 3", .number = 2 },
        .{ .expr = "5.9 | 0", .number = 5 },
        .{ .expr = "-8 >> 1", .number = -4 },
        .{ .expr = "1 << 63", .number = -0x1p63 },
        .{ .expr = "[1, 2][inf_v]", .message = "out of bounds" },
        .{ .expr = "[1, 2][-inf_v]", .message = "out of bounds" },
        .{ .expr = "[1, 2][huge]", .message = "out of bounds" },
        .{ .expr = "[1, 2][-1]", .number = 2 },
        .{ .expr = "a = [1, 2]\n  a[inf_v] = 3", .message = "out of bounds" },
    };
    for (cases) |case| {
        errdefer std.debug.print("failing case: {s}\n", .{case.expr});
        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        try registry.registerStandardLibrary(&vm);
        vm.mute_errors = true;

        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(testing.allocator);

        // Operands come from variables so the compiler cannot constant-fold them
        const source = try std.fmt.allocPrint(testing.allocator,
            \\huge = 1e300
            \\inf_v = huge * huge
            \\result = begin
            \\  {s}
            \\rescue => e
            \\  e.message
            \\end
        , .{case.expr});
        defer testing.allocator.free(source);

        try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
        const result = vm.globals.get("result") orelse return error.MissingGlobal;
        if (case.message) |message| {
            try testing.expect(result.isString());
            try testing.expect(std.mem.indexOf(u8, result.asString().chars, message) != null);
        } else {
            try testing.expect(result.isNumber());
            try testing.expectEqual(case.number, result.asNumber());
        }
    }
}
