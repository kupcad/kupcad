//! VM tests of the core machinery: compiling and running scripts end to end, the dispatch
//! loop, inline caches, globals and constants, REPL locals, the debugger and the profiler.

const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const resolver = @import("../core/resolver.zig");
const value = @import("../core/value.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../frontend/document.zig").Document;
const Profiler = @import("profiler.zig").Profiler;
const VM = @import("vm.zig").VM;
const helpers = @import("vm_test_helpers.zig");
const test_support = @import("../test_support.zig");
const executeAndAssertStack = helpers.executeAndAssertStack;
const compileAndRun = helpers.compileAndRun;
const expectGlobalString = helpers.expectGlobalString;

// --- Mock Debugger Step Handler ---
var mock_step_count: usize = 0;

/// A host's debugger for the tests below: on its first call it starts stepping, counts the
/// line boundaries it is shown, and resumes after two of them, as `.step`, `.step`,
/// `.continue` would at the prompt.
var stepping_debugger_calls: usize = 0;

fn mockStepHandler(vm: *VM) void {
    _ = vm;
    mock_step_count += 1;
}

fn steppingDebugger(vm: *VM) void {
    stepping_debugger_calls += 1;
    vm.hooks.setStep(stepping_debugger_calls <= 2);
}

test "VM: Comprehensive Ruby-like language features integration" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\module MathHelpers
        \\  def square(x)
        \\    x * x
        \\  end
        \\end
        \\
        \\class Calculator
        \\  include MathHelpers
        \\
        \\  def initialize(offset)
        \\    @offset = offset
        \\    @@count = 42
        \\  end
        \\
        \\  def self.get_count
        \\    @@count
        \\  end
        \\
        \\  def compute(arr)
        \\    res = []
        \\    i = 0
        \\    while i < arr.length
        \\      val = arr[i]
        \\      processed = case val
        \\      when 1..5
        \\        self.square(val)
        \\      when 10
        \\        val * 2
        \\      else
        \\        -1
        \\      end
        \\      res.push(processed + @offset)
        \\      i += 1
        \\    end
        \\    res
        \\  end
        \\end
        \\
        \\class AdvancedCalculator < Calculator
        \\  def initialize(offset, multiplier)
        \\    super(offset)
        \\    @multiplier = multiplier
        \\  end
        \\
        \\  def compute(arr)
        \\    base_res = super(arr)
        \\    # Proves `@multiplier` is captured as an Upvalue inside the block!
        \\    base_res.map { |x| x * @multiplier }
        \\  end
        \\end
        \\
        \\calc = AdvancedCalculator.new(5, 2)
        \\# 2  -> (2^2 + 5) * 2  = 18
        \\# 10 -> (10*2 + 5) * 2 = 50
        \\# 42 -> (-1 + 5) * 2   = 8
        \\result = calc.compute([2, 10, 42])
        \\
        \\err_caught = false
        \\begin
        \\  raise(ArgumentError)
        \\rescue ArgumentError => e
        \\  err_caught = true
        \\end
        \\
        \\dict = { first: result[0], second: result[1] }
        \\a, *b, c = [*result, 100, 200]
        \\
        \\summary = "Count: #{Calculator.get_count}"
        \\
        \\[dict[:first], b.length(), c, err_caught, summary]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(arr_val.isArray());

    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 5), arr_obj.items.items.len);

    // dict[:first] == 18
    try testing.expectEqual(@as(f64, 18.0), arr_obj.items.items[0].asNumber());
    // b.length() == 3 (the middle splat captured [50, 8, 100])
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[1].asNumber());
    // c == 200 (the tail end of the destructure)
    try testing.expectEqual(@as(f64, 200.0), arr_obj.items.items[2].asNumber());
    // err_caught == true
    try testing.expectEqual(true, arr_obj.items.items[3].asBool());

    // Interpolated summary == "Count: 42"
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", arr_obj.items.items[4].asObj()));
    try testing.expectEqualStrings("Count: 42", str_obj.chars);
}

test "VM: DOD param registry getter and setter overloading" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Script:
    // 1. Define :width with a default of 42.5
    // 2. Retrieve it using param(:width)
    const source =
        \\param(:width, default: 42.5, validate: { min: 10, max: 100 })
        \\param(:width)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // The script should return exactly 42.5
    try testing.expectEqual(@as(f64, 42.5), result.asNumber());

    // Verify the DOD array actually stored it
    try testing.expectEqual(@as(usize, 1), vm.param_registry.len);
    try testing.expectEqual(@as(f64, 42.5), vm.param_registry.items(.current_value)[0].asNumber());
}

test "VM: param validation halts execution on bounds violations" {
    const sources = [_][]const u8{
        "param(:width, default: 200, validate: { max: 100 })",
        "param(:width, default: 5, validate: { min: 10 })",
        "param(:width, default: 150, validate: { min: 10, max: 100 })",
    };
    for (sources) |source| {
        errdefer std.debug.print("failing source: {s}\n", .{source});
        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        try registry.registerStandardLibrary(&vm);

        var doc = try Document.parse(testing.allocator, source);
        defer doc.deinit();
        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(testing.allocator);

        var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
        defer comp.deinit();
        try comp.compile(doc.tree.root);

        try testing.expectEqual(.runtime_error, vm.interpret(&out_chunk));
    }
}

test "VM: Universal Object Protocol (nil?, empty?, tap, into, dup)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\val = nil
        \\t1 = val.nil?
        \\t2 = "hello".nil?
        \\t3 = [].empty?
        \\
        \\t4 = cube(10).tap { |c| c.translate(5, 0, 0) }.volume()
        \\t5 = 10.into { |x| x * 2 }
        \\
        \\[t1, t2, t3, t4, t5]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = result.asArray();

    try testing.expectEqual(true, arr_obj.items.items[0].asBool()); // nil.nil? -> true
    try testing.expectEqual(false, arr_obj.items.items[1].asBool()); // "hello".nil? -> false
    try testing.expectEqual(true, arr_obj.items.items[2].asBool()); // [].empty? -> true
    try testing.expectApproxEqAbs(@as(f64, 1000.0), arr_obj.items.items[3].asNumber(), 0.1); // tap returns receiver un-mutated
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[4].asNumber()); // 10.then { |x| x * 2 } -> 20
}

test "VM: Inline Caching correctly populates and accelerates property getters and setters" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // The loop ensures the first pass is a cache miss, and the second pass is a cache hit!
    const source =
        \\class Point
        \\  def initialize(x)
        \\    self.x = x
        \\  end
        \\end
        \\p = Point.new(10)
        \\
        \\i = 0
        \\while (i < 2)
        \\  p.x = p.x + 5
        \\  i = i + 1
        \\end
        \\p.x
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 20.0), result.asNumber());

    // Assert that Inline Caches were actually populated by the VM during execution!
    var populated_caches: usize = 0;
    for (out_chunk.inline_caches.items) |ic| {
        if (ic.cached_class_1 != null) {
            populated_caches += 1;
        }
    }

    // There should be active caches for `self.x = x`, `p.x` (get), and `p.x =` (set)
    try testing.expect(populated_caches >= 2);
}

test "VM/Compiler: Seeded REPL locals correctly resolve to offset stack slots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: y + 5
    const y_id = try b.intern("y");
    const y_node = try b.createNode(.identifier, 0, @backingInt(y_id));
    const five = try b.number("5", 0);
    const add_node = try b.binary(.add, y_node, five, 0);

    // --- NEW: Provide a mock symbols array ---
    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @backingInt(add_node) + 1);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // 1. SEED 'y' at offset 1 (simulating slot 1 in the paused caller frame)
    const seeded = [_][]const u8{"y"};
    comp.seedLocals(&seeded, 1);

    try comp.compile(add_node);

    // 2. Verify it securely targeted the caller's stack slot without using globals
    try testing.expectEqual(chunk.OpCode.op_get_local, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[0])));
    try testing.expectEqual(@as(u8, 1), out_chunk.code.items[1]); // Successfully pointed to Slot 1
}

test "VM: Lexical Constant Resolution Hierarchies" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\GLOBAL_VAL = 100
        \\module Hardware
        \\  ROOT_VAL = 200
        \\  class Fastener
        \\    def get_scoped
        \\      ROOT_VAL
        \\    end
        \\
        \\     def get_global
        \\      GLOBAL_VAL
        \\    end
        \\  end
        \\end
        \\
        \\f = Hardware::Fastener.new
        \\[f.get_scoped, f.get_global]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    try testing.expectEqual(@as(f64, 200.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[1].asNumber());
}

test "VM Debugger: step_mode triggers callback exactly on line boundaries" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Bind the mock debugger handler and enable stepping
    vm.debugger_step_handler = mockStepHandler;
    vm.hooks.setStep(true);
    mock_step_count = 0;

    // A 3-line script should cross a line boundary exactly twice after the first instruction starts
    const source =
        \\x = 10
        \\y = 20
        \\z = x + y
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    // The line_index MUST be injected for step_mode to work!
    vm.line_index = &doc.line_index;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Interpret the script
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    // Line 1 -> Line 2 (Step 1)
    // Line 2 -> Line 3 (Step 2)
    try testing.expectEqual(@as(usize, 2), mock_step_count);
}

test "VM: Profiler traces scripts, closures, and native calls seamlessly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Register standard library so `Math.sin` is available natively
    try registry.registerStandardLibrary(&vm);

    // Initialize and attach the profiler using the Io-aware signature
    var profiler = Profiler.init(testing.allocator, testing.io);
    defer profiler.deinit();
    vm.profiler = &profiler;

    // A script designed to trigger all 3 profiler paths:
    // 1. "script" (Top-level VM interpretation)
    // 2. "math_heavy" (User-defined closure dispatch)
    // 3. "sin" (Native C++ / standard library FFI execution)
    const source =
        \\def math_heavy(iters)
        \\  Math.sin(iters)
        \\end
        \\
        \\math_heavy(5)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Execute with profiler actively tracing
    const result = vm.interpret(&out_chunk);

    // Ensure execution succeeded
    try testing.expectEqual(.ok, result);

    // Validate that all three function scopes were intercepted and recorded
    try testing.expect(profiler.stats.contains("script"));
    try testing.expect(profiler.stats.contains("math_heavy"));
    try testing.expect(profiler.stats.contains("Math.sin")); // natives profile under their qualified name

    // Verify execution metrics were collected
    const math_stats = profiler.stats.get("math_heavy").?;
    try testing.expect(math_stats.call_count == 1);
    try testing.expect(math_stats.total_time_ns >= math_stats.self_time_ns);

    // Ensure the runtime Unwind was graceful and didn't leave dangling timer frames
    try testing.expectEqual(@as(usize, 0), profiler.timer_stack.items.len);
}

test "VM: warn and benchmark utilities execute safely and transparently" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Mute the actual print handler so we don't spam the test console
    vm.host.print_handler = null;

    const source =
        \\# Warn is a side effect and should return nil
        \\w_res = warn("This is a test warning")
        \\
        \\# Benchmark should time the block but transparently return its result
        \\b_res = benchmark("Heavy Math") do
        \\  10 * 10
        \\end
        \\
        \\[w_res.nil?, b_res]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);

    // warn returns nil
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());

    // benchmark transparently returns 100
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[1].asNumber());
}

test "VM: Inline Caching correctly populates monomorphic and polymorphic slots" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // This script calls `.translate` in a loop.
    // The first iteration is on a 3D geometry (Cube).
    // The second iteration is on a 2D profile (Square).
    // This forces the cache to graduate from Monomorphic -> Polymorphic.
    const source =
        \\arr = [cube(10), square(10)]
        \\i = 0
        \\while i < 2
        \\  arr[i].translate(x: 5)
        \\  i += 1
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Execute the chunk
    _ = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Verify the Inline Caches
    // The `translate` method call is tracked by an inline cache.
    // We expect at least one cache to have BOTH slots populated
    // (Slot 1 = Geometry class, Slot 2 = CrossSection class).
    var polymorphic_hit = false;

    for (out_chunk.inline_caches.items) |ic| {
        if (ic.cached_class_1 != null and ic.cached_class_2 != null) {
            const class1 = ic.cached_class_1.?.name.chars;
            const class2 = ic.cached_class_2.?.name.chars;

            // Check if it captured both CAD types
            if ((std.mem.eql(u8, class1, "Geometry") and std.mem.eql(u8, class2, "CrossSection")) or
                (std.mem.eql(u8, class1, "CrossSection") and std.mem.eql(u8, class2, "Geometry")))
            {
                polymorphic_hit = true;
                break;
            }
        }
    }

    try testing.expect(polymorphic_hit);
}

// Global keys must outlive the chunk whose constant named them
test "VM: redefining a global on a reused VM after its defining chunk was freed" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    // Each run gets its own chunk, freed afterwards, as a session and the LSP do
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

test "VM Debugger: debugger() steps the following lines, then continues, and the run completes" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.host.print_handler = null;
    vm.debugger_handler = steppingDebugger;
    stepping_debugger_calls = 0;

    const source =
        \\a = 1
        \\debugger()
        \\b = 2
        \\c = 3
        \\d = 4
        \\r = a + b + c + d
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    vm.line_index = &doc.line_index;
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    try testing.expectEqual(.ok, vm.interpret(&out_chunk));
    // The breakpoint, then two line steps (b = 2, c = 3); `.continue` ran the rest unseen.
    try testing.expectEqual(@as(usize, 3), stepping_debugger_calls);
    try testing.expect(!vm.hooks.step);
    try testing.expectEqual(@as(f64, 10), vm.globals.get("r").?.asNumber());
}

test "VM Debugger: stepping with no one to answer runs the script to the end" {
    // step_mode without a step handler ended the run with a `paused` result no caller
    // could resume; nobody is there to pause for, so the run goes on.
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.hooks.setStep(true);
    const source =
        \\x = 10
        \\y = 20
        \\z = x + y
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    vm.line_index = &doc.line_index;
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    try testing.expectEqual(.ok, vm.interpret(&out_chunk));
    try testing.expect(!vm.hooks.step);
    try testing.expectEqual(@as(f64, 30), vm.globals.get("z").?.asNumber());
}

test "VM: a top-level variable's cached slot follows its assignments and the table's growth" {
    // Each global read and assignment caches where its variable lives (GlobalCache). New
    // names in the middle of a loop make the table grow, which moves every slot: the sites
    // that cached one must look again, not read freed memory.
    const support = @import("../test_support.zig");
    try support.expectScripts(&.{
        .{ .src = "i = 0\nwhile i < 10\n  i += 1\nend\nr = i", .expected = .{ .num = 10 } },
        .{ .src = "total = 0\ni = 0\nwhile i < 10\n  total = total + i\n  if i == 3\n    g0 = 1\n    g1 = 1\n    g2 = 1\n    g3 = 1\n    g4 = 1\n    g5 = 1\n    g6 = 1\n    g7 = 1\n    g8 = 1\n    g9 = 1\n    g10 = 1\n    g11 = 1\n    g12 = 1\n    g13 = 1\n    g14 = 1\n    g15 = 1\n    g16 = 1\n    g17 = 1\n    g18 = 1\n    g19 = 1\n    g20 = 1\n    g21 = 1\n    g22 = 1\n    g23 = 1\n    g24 = 1\n    g25 = 1\n    g26 = 1\n    g27 = 1\n    g28 = 1\n    g29 = 1\n    g30 = 1\n    g31 = 1\n    g32 = 1\n    g33 = 1\n    g34 = 1\n    g35 = 1\n    g36 = 1\n    g37 = 1\n    g38 = 1\n    g39 = 1\n    g40 = 1\n    g41 = 1\n    g42 = 1\n    g43 = 1\n    g44 = 1\n    g45 = 1\n    g46 = 1\n    g47 = 1\n    g48 = 1\n    g49 = 1\n    g50 = 1\n    g51 = 1\n    g52 = 1\n    g53 = 1\n    g54 = 1\n    g55 = 1\n    g56 = 1\n    g57 = 1\n    g58 = 1\n    g59 = 1\n    g60 = 1\n    g61 = 1\n    g62 = 1\n    g63 = 1\n  end\n  i += 1\nend\nr = total + g63", .expected = .{ .num = 46 } },
    });
}

test "VM: a run stopped inside a rescue leaves none of its handlers to the next run" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;
    // Out of instructions inside `begin`: the handler it registered stayed, pointing into
    // this chunk, and the next run's error jumped there
    vm.hooks.setLimit(2000);
    try testing.expectEqual(.execution_limit_exceeded, try test_support.runOn(&vm, "begin\n  while true\n  end\nrescue => e\n  e\nend"));
    vm.hooks.setLimit(0);
    try testing.expectEqual(.runtime_error, try test_support.runOn(&vm, "raise \"boom\""));
    try testing.expect(std.mem.find(u8, vm.last_error.?, "boom") != null);
}

test "GC: a collection with many Paths alive has room for each on its gray stack" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    try testing.expectEqual(.ok, try test_support.runOn(&vm, "paths = (1..20000).map { |i| line([0, 0], [i, 1]) }"));
    try testing.expect(vm.gc.paths.items.len >= 20000);
    // Every path is marked from the global: a stack sized without the paths overflowed
    vm.gc.collectGarbage(&vm, false);
    try testing.expect(vm.gc.paths.items.len >= 20000);
}

test "GC: the standard library registered again on a VM makes no new natives" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const natives = vm.gc.natives.count();
    const arena = vm.gc.builtins.queryCapacity();
    // As a session registers it before each run
    try registry.registerStandardLibrary(&vm);
    try testing.expectEqual(natives, vm.gc.natives.count());
    try testing.expectEqual(arena, vm.gc.builtins.queryCapacity());
}

test "VM: a chunk owns its locals' names, which outlive the document they were read from" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    // runOn parses the script into a document of its own, gone when it returns; the names
    // pointed into it, and the debugger read them from the chunk
    try testing.expectEqual(.ok, try test_support.runOn(&vm, "def add(first, second)\n  first + second\nend\nadd(1, 2)"));
    var first = false;
    var second = false;
    for (vm.gc.functions.items) |function| {
        const function_chunk: *chunk.Chunk = @ptrCast(@alignCast(function.chunk orelse continue));
        for (function_chunk.local_names.items) |name| {
            if (std.mem.eql(u8, name, "first")) first = true;
            if (std.mem.eql(u8, name, "second")) second = true;
        }
    }
    try testing.expect(first and second);
}
