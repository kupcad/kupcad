//! VM tests of the runtime's resources: the stack and call frames as they grow, the
//! instruction budget, garbage collection (ARC for geometry), the scratch arena and memory limits.

const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../frontend/document.zig").Document;
const geom = @import("../core/geometry_handle.zig");
const VM = @import("vm.zig").VM;
const InterpretResult = @import("vm.zig").InterpretResult;
const helpers = @import("vm_test_helpers.zig");
const executeAndAssertStack = helpers.executeAndAssertStack;
const compileAndRunStressed = helpers.compileAndRunStressed;

// --- Mock C++ Destructor for GC Tests ---
var mock_destructor_called = false;

var mock_last_destroyed_handle: ?geom.GeometryHandle = null;

/// The native stack MAX_NESTED_RUNS levels may take: half of the 16 MiB a script runs on
/// (Zig links executables with that main stack and spawns threads with it), leaving the
/// rest to what runs inside the deepest level. A debug build takes about 32 KiB a level,
/// a release one about 4 KiB.
const NESTED_RUN_STACK_BUDGET = 8 * 1024 * 1024;

fn mockMeshDestructor(handle: geom.GeometryHandle) void {
    mock_destructor_called = true;
    mock_last_destroyed_handle = handle;
}

/// A native that keeps scratch memory across a backtrace and a nested run of its block,
/// then reports whether the memory still holds what it wrote.
fn holdScratch(vm_opaque: *anyopaque, args: value.NativeArgs) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const held = try vm.fmtScratch("{s}", .{"held by the native"});
    _ = try vm.buildBacktrace();
    if (args.block()) |block| _ = try vm.callClosureSync(block, &.{});
    // Fresh scratch allocations would reuse `held` if the arena had been reset under it.
    _ = try vm.fmtScratch("{s}", .{"overwrites a reset arena"});
    return value.Value.initBool(std.mem.eql(u8, held, "held by the native"));
}

test "VM: Dynamic stack growth handles pushes beyond initial 64K pre-allocation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Push past the 65536 initial buffer size to prove ensureStackCapacity still reallocates!
    const push_count: usize = 70_000;

    // We don't call ensureStackCapacity here, we let the `push` method trigger it dynamically!
    for (0..push_count) |i| {
        vm.push(value.Value.initNumber(@floatFromInt(i)));
    }

    try testing.expect(vm.stack.len >= push_count);
    try testing.expectEqual(push_count, vm.stack_top);

    var i: usize = push_count;
    while (i > 0) {
        i -= 1;
        const val = vm.pop();
        try testing.expectEqual(@as(f64, @floatFromInt(i)), val.asNumber());
    }
    try testing.expectEqual(@as(usize, 0), vm.stack_top);
}

test "VM: Gas limit prevents infinite loops and throws specific error" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.hooks.setLimit(50);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    try out_chunk.writeOp(testing.allocator, .op_loop, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 5, 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);
    out_chunk.max_stack_slots = 1;

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.execution_limit_exceeded, result);
}

test "VM: JIT materialization cascades through DAG and ARC safely cleans up" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Build a complex symbolic DAG (Cube + Sphere + Translate)
    // 2. Call `.bbox()` to force JIT materialization down the entire tree!
    const source =
        \\part = cube(10, 10, 10, true) + sphere(5).translate(0, 0, 5)
        \\part.bbox()
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Execute the script
    const bbox_val = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Verify it is a Native BBox
    try testing.expect(bbox_val.isBBox());
    const bbox_inst = bbox_val.asBBox();

    // Verify it actually extracted volume correctly
    try testing.expect(bbox_inst.max[0] > bbox_inst.min[0]);
}

test "VM: 2D primitives, sweeps, and Bitwise AND (Intersection) work seamlessly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Mute print_handler during unit tests
    vm.host.print_handler = null;

    // Test script:
    // 1. Create a 10x10 square and extrude it 50 units (Volume should be 5000)
    // 2. Create two 10x10x10 cubes, shift one by 5, and Intersect them (Volume should be 125)
    const source =
        \\sq = square(size: 10, center: true)
        \\part1 = sq.extrude(50)
        \\
        \\box1 = cube(10, 10, 10, false)
        \\box2 = cube(10, 10, 10, false).translate(5, 5, 5)
        \\part2 = box1 & box2
        \\
        \\[part1.volume(), part2.volume()]
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

    // Extruded 10x10 square up to 50 = 5000 volume
    try testing.expect(arr_obj.items.items[0].asNumber() > 4999.0);
    try testing.expect(arr_obj.items.items[0].asNumber() < 5001.0);

    // Intersecting cubes should yield a 5x5x5 cube = 125 volume
    try testing.expect(arr_obj.items.items[1].asNumber() > 124.0);
    try testing.expect(arr_obj.items.items[1].asNumber() < 126.0);
}

test "VM: GC Grey Stack handles deeply nested objects without C-stack overflow" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Deep enough that a recursive markObject would overflow the C stack
    const nesting_depth = 2000;
    const source = std.fmt.comptimePrint(
        \\arr = []
        \\i = 0
        \\while (i < {d})
        \\  arr = [arr]
        \\  i = i + 1
        \\end
        \\arr
    , .{nesting_depth});

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    vm.gc.collectGarbage(&vm, false);

    // Every nesting level survived the collection
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    var depth: usize = 0;
    var cur = vm.stack[0];
    while (cur.asArray().items.items.len == 1) : (depth += 1) cur = cur.asArray().items.items[0];
    try testing.expectEqual(@as(usize, nesting_depth), depth);
}

test "VM: op_interpolate prevents memory leak on GC OOM" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Allocate string fragments BEFORE artificially restricting the GC
    const s1 = try out_chunk.addConstant(testing.allocator, try vm.allocateString("A"));
    const s2 = try out_chunk.addConstant(testing.allocator, try vm.allocateString("B"));

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(s1), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(s2), 0);

    try out_chunk.writeOp(testing.allocator, .op_interpolate, 0);
    try out_chunk.write(testing.allocator, 2, 0); // 2 parts
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    // NOW restrict memory to force an OOM during execution of op_interpolate
    vm.gc.max_memory_limit = 10;

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);
    // If the leak exists, Zig's testing allocator will panic at the end of this test.
}

test "VM: Optimized String methods operate safely without leaks" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Proves that allocateStringTakeOwnership correctly takes over the memory
    // from our stringUpcase/stringReplace refactor without double allocating.
    const source =
        \\[ "hello".upcase(), "WORLD".downcase(), "foo bar".replace("foo", "baz") ]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", result.asObj()));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    const s1: *value.ObjString = @alignCast(@fieldParentPtr("obj", arr_obj.items.items[0].asObj()));
    try testing.expectEqualStrings("HELLO", s1.chars);

    const s2: *value.ObjString = @alignCast(@fieldParentPtr("obj", arr_obj.items.items[1].asObj()));
    try testing.expectEqualStrings("world", s2.chars);

    const s3: *value.ObjString = @alignCast(@fieldParentPtr("obj", arr_obj.items.items[2].asObj()));
    try testing.expectEqualStrings("baz bar", s3.chars);
}

test "VM: Stack does not leak on local variable assignments inside loops" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // The script initializes 'i', then loops 10 times.
    // Inside the loop, it declares a brand new local variable 'temp'.
    // If the compiler emits `op_nil` dynamically here, the stack will leak by +10.
    const source =
        \\i = 0
        \\while (i < 10)
        \\  temp = i * 2
        \\  i = i + 1
        \\end
        \\i
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // The stack must contain EXACTLY 1 item (the final result: 10.0).
    // Before the fix, stack_top would be 11 (10 leaked nils + 1 result).
    try testing.expectEqual(@as(f64, 10.0), result.asNumber());
}

test "VM: GC correctly marks executing closures and primitive classes" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Bind a native function to aggressively force a GC cycle mid-execution
    const force_gc = struct {
        fn run(vm_opaque: *anyopaque, call: value.NativeArgs) anyerror!value.Value {
            const arg_count = call.count;
            const args = call.ptr;
            _ = arg_count;
            _ = args;
            const v: *VM = @ptrCast(@alignCast(vm_opaque));
            v.gc.collectGarbage(v, false);
            return value.Value.initNil();
        }
    }.run;
    try vm.defineNative("force_gc", force_gc);

    const source =
        \\(def ()
        \\  force_gc()
        \\  [1, 2, 3].length()
        \\end)()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // If we reach here without a panic or segfault, the GC roots are watertight!
    try testing.expectEqual(@as(f64, 3.0), result.asNumber());
}

test "VM: Safe navigation chaining on nil short-circuits without stack leak" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\part = nil
        \\res = part&.translate(10, 20, 30)&.rotate(x: 45)&.bbox()
        \\res.nil?
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(true, result.asBool());
}

test "VM: GC sweep during dynamic map and array splat expansion" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\base_map = { a: 1, b: 2 }
        \\base_arr = [10, 20]
        \\# Force GC mid-expression via method chain using the native GC module
        \\merged_map = { **base_map, c: 3 }.tap { GC.collect() }
        \\merged_arr = [ *base_arr, 30 ].tap { GC.collect() }
        \\[ merged_map[:c], merged_arr[2] ]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[1].asNumber());
}

test "VM: GC module collect and bytes_allocated methods" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\bytes_before = GC.bytes_allocated()
        \\GC.collect()
        \\bytes_after = GC.bytes_allocated()
        \\[bytes_before, bytes_after]
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
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expect(arr_obj.items.items[0].isNumber());
    try testing.expect(arr_obj.items.items[1].isNumber());
    try testing.expect(arr_obj.items.items[0].asNumber() > 0.0);
    try testing.expect(arr_obj.items.items[1].asNumber() > 0.0);
}

test "VM ARC: Arrays containing Geometry objects do not leak on GC sweep" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Creates geometries, packs them in an array, and discards them.
    // If memory.zig `freeObject` lacks `releaseValue` for array items,
    // Zig's testing allocator will flag a leak here.
    const source =
        \\def build_array()
        \\  [cube(10), sphere(5), square(2)]
        \\end
        \\build_array()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
}

test "VM ARC: Stack unwinds and frees Geometry safely during Exceptions" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Creates a geometry, pushes it to the stack, then raises an error.
    // If the VM's `executeThrow` unwinder doesn't release dead stack slots, it will leak.
    const source =
        \\begin
        \\  c = cube(10)
        \\  raise("Force Unwind")
        \\rescue => e
        \\  1
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
}

test "VM ARC: Native Operator exceptions prevent double-free and leaks" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Mixed 3D and 2D triggers a native RuntimeError inside cadBinaryHandler.
    // If executeBinaryArithmetic mismanages `releaseValue`, this will either leak or ABRT crash.
    const source =
        \\begin
        \\  cube(10) + square(5)
        \\rescue => e
        \\  1
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
}

test "VM: Dynamic call stack growth supports deep recursion" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Deep recursion (1,500 frames deep) exceeds the former 1,024 static frame limit
    const source =
        \\def count_down(n)
        \\  if (n <= 0)
        \\    return 42
        \\  end
        \\  count_down(n - 1)
        \\end
        \\count_down(1500)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());
}

test "VM GC: Geometry lifecycle triggers C++ destructor upon sweep" {
    mock_destructor_called = false;
    mock_last_destroyed_handle = null;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.host.mesh_destructor = mockMeshDestructor;

    const test_ptr: *anyopaque = @ptrFromInt(0xDEADBEEF);
    const handle = geom.GeometryHandle{ .engine = .manifold, .ptr = test_ptr };

    const mesh_val = try vm.allocateGeometry(.{ .concrete = handle });

    vm.push(mesh_val);
    vm.gc.collectGarbage(&vm, false);
    try testing.expect(!mock_destructor_called);

    _ = vm.pop();
    vm.gc.collectGarbage(&vm, false);

    try testing.expect(mock_destructor_called);
    try testing.expectEqual(.manifold, mock_last_destroyed_handle.?.engine);
    try testing.expectEqual(test_ptr, mock_last_destroyed_handle.?.ptr);
}

test "VM GC: Workplanes successfully trace and keep their parent Geometry alive" {
    mock_destructor_called = false;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.host.mesh_destructor = mockMeshDestructor;

    const handle = geom.GeometryHandle{ .engine = .manifold, .ptr = @as(*anyopaque, @ptrFromInt(0x1234)) };
    const parent_val = try vm.allocateGeometry(.{ .concrete = handle });

    vm.push(parent_val);
    const wp_val = try vm.allocateWorkplane(parent_val.asGeometry(), .{ 0, 0, 0 }, .{ 0, 0, 1 });
    _ = vm.pop();

    vm.push(wp_val);
    vm.gc.collectGarbage(&vm, false);
    try testing.expect(!mock_destructor_called);

    _ = vm.pop();
    vm.gc.collectGarbage(&vm, false);
    try testing.expect(mock_destructor_called);
}

test "VM GC: CAD object allocations respect Sandbox memory limits" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Capture the static 84-byte initialization memory
    const baseline_mem = vm.gc.bytes_allocated;

    try testing.expectEqual(baseline_mem, vm.gc.bytes_allocated);
    const geom_val = try vm.allocateGeometry(.{ .symbolic = 1 });
    vm.push(geom_val);

    try testing.expect(vm.gc.bytes_allocated > baseline_mem);
    vm.gc.max_memory_limit = vm.gc.bytes_allocated;

    const result = vm.allocateGeometry(.{ .symbolic = 2 });
    try testing.expectError(error.OutOfMemory, result);
}

test "VM: Gas limit perfectly triggers inside deeply nested loop contexts, preventing host hang" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    // Set a strict gas limit
    vm.hooks.setLimit(100);

    // Deeply nested infinite loop to test the bounds of the interpreter's safety constraints
    const source =
        \\def run_forever()
        \\  [1].each do |x|
        \\    while true
        \\      x = x + 1
        \\    end
        \\  end
        \\end
        \\run_forever()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    // The compiler will not hang because AST traversal is purely acyclic
    try comp.compile(doc.tree.root);

    // The VM will not hang because `runUntil` explicitly enforces the instruction_limit
    // at the very top of the execution loop!
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.execution_limit_exceeded, result);
}

test "VM: Gas limit triggers securely through native op_yield re-entrancy" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.hooks.setLimit(50);

    const source =
        \\def infinite_yielder
        \\  yield
        \\end
        \\infinite_yielder do
        \\  while true
        \\    x = 1
        \\  end
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.execution_limit_exceeded, result);
}

test "VM: Modules accurately namespace nested classes and prevent global leaks" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\module Factory
        \\  class Gear
        \\    def self.size
        \\      42
        \\    end
        \\  end
        \\end
        \\
        \\res1 = Factory::Gear.size
        \\res2 = defined?(Gear) # Should be nil because Gear didn't leak globally!
        \\[res1, res2.nil?]
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

    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(true, arr_obj.items.items[1].asBool()); // defined?(Gear) is nil
}

test "VM: fmtScratch safely formats short strings" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const result = try vm.fmtScratch("Hello {s}, value is {d}", .{ "World", 42 });
    try testing.expectEqualStrings("Hello World, value is 42", result);
}

test "VM: fmtScratch dynamically allocates strings exceeding 256 bytes without truncation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Create a massive string (300 characters of 'A')
    var massive_buf: [300]u8 = undefined;
    @memset(&massive_buf, 'A');
    const massive_str = &massive_buf;

    // Format it into a new string
    const result = try vm.fmtScratch("Error Context: {s}", .{massive_str});

    // "Error Context: " is 15 characters + 300 'A's = 315 characters total
    try testing.expectEqual(@as(usize, 315), result.len);

    // Verify the prefix and suffix are completely intact
    try testing.expect(std.mem.startsWith(u8, result, "Error Context: AAAAA"));
    try testing.expect(std.mem.endsWith(u8, result, "AAAAA"));
}

test "VM: Bound CAD methods retain ARC geometry correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\c = cube(10)
        \\trans = c.method(:translate)
        \\shifted = trans.call(5, 0, 0)
        \\shifted.volume
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    _ = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expectEqual(@as(f64, 1000.0), vm.stack[0].asNumber());
}

test "VM CAD: helix sweeps a 2D profile with a twist" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.host.print_handler = null;

    // Twist a 10x10 square 360 degrees over a 20mm extrusion
    const source =
        \\sq = square(10, center: true)
        \\part = sq.helix(20, 360, 32)
        \\part.volume
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isNumber());

    // A twisted 10x10 square extruded by 20 should maintain a volume close to 2000
    const vol = result.asNumber();
    try testing.expect(vol > 1500.0 and vol < 2500.0);
}

test "VM: DAG Evaluator prevents C-stack overflow on deep recursion" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Script builds a heavily unbalanced, deeply nested CSG tree (2,500 levels deep),
    // and then forces the DAG evaluator to materialize it via `.bbox()`.
    const source =
        \\c = cube(10)
        \\i = 0
        \\while i < 2500
        \\  c = c + cube(10)
        \\  i = i + 1
        \\end
        \\c.bbox()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    // Successfully evaluates massive trees thanks to dynamic arrays
    try testing.expectEqual(.ok, result);
}

test "VM: GC marks unwind_err_val during native unwind" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Park an un-rooted error string in unwind_err_val
    const err_str = try vm.allocateString("Unwind error protection");
    try vm.unwind_stack.append(testing.allocator, .{ .err_val = err_str, .stack_top = 0 });

    // Force GC cycle
    vm.gc.collectGarbage(&vm, false);

    // Verify error string was marked and preserved in strings table
    try testing.expect(vm.strings.contains("Unwind error protection"));
}

test "VM: op_interpolate resets scratch arena memory and maintains stack equilibrium" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\name = "World"
        \\"Hello #{name}!"
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isString());
    try testing.expectEqualStrings("Hello World!", result.asString().chars);
}

test "VM: Repeated string interpolation loop recycles scratch arena" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\i = 0
        \\while i < 1000
        \\  str = "Iteration #{i}"
        \\  i += 1
        \\end
        \\i
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 1000.0), result.asNumber());
}

test "VM: Repeated string addition (+ operator) recycles scratch arena" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\s = ""
        \\i = 0
        \\while i < 1000
        \\  s += "a"
        \\  i += 1
        \\end
        \\s.length
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 1000.0), result.asNumber());
}

test "VM: GC gray stack accurately sizes capacity without panicking" {
    // We allocate thousands of distinct objects (strings, arrays, numbers)
    // to ensure the gray_stack capacity math correctly accounts for all of
    // them during the mark phase.
    const source =
        \\arr = []
        \\i = 0
        \\while i < 1000 do
        \\  arr.push([i, "test", true])
        \\  i = i + 1
        \\end
        \\arr # Leave the array on the stack so it stays rooted!
    ;

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();

    // Register standard library so we have Array methods
    try registry.registerStandardLibrary(&vm);

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();
    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&main_chunk);
    try std.testing.expectEqual(.ok, result);

    // Force a full garbage collection sweep.
    // If our `worst_case_size` math missed any object types,
    // `appendAssumeCapacity` will trigger an out-of-bounds panic right here
    vm.gc.collectGarbage(&vm, true);
}

test "VM: Scratch Arena is preserved during complex nested string formatting" {
    // If the arena resets prematurely inside `+`, the outer `#{}` interpolation
    // will read corrupted/freed memory for the first string fragment.
    const source =
        \\ a = "hello"
        \\ b = "world"
        \\ "#{a + " " + b}!"
    ;

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Use our strict stack helper to ensure zero memory leaks
    const final_val = try executeAndAssertStack(&vm, &main_chunk, 1);

    try std.testing.expect(final_val.isString());
    try std.testing.expectEqualStrings("hello world!", final_val.asString().chars);
}

test "VM: DOD array operations (build, spread, pack, unpack) transfer memory losslessly" {
    const source =
        \\ base = [2, 3, 4]
        \\ expanded = [1, *base, 5]
        \\ expanded
    ;

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const final_val = try executeAndAssertStack(&vm, &main_chunk, 1);

    try std.testing.expect(final_val.isArray());
    const result_arr = final_val.asArray().items.items;

    try std.testing.expectEqual(@as(usize, 5), result_arr.len);
    try std.testing.expectEqual(@as(f64, 1.0), result_arr[0].asNumber());
    try std.testing.expectEqual(@as(f64, 2.0), result_arr[1].asNumber());
    try std.testing.expectEqual(@as(f64, 5.0), result_arr[4].asNumber());
}

test "VM: DOD map operations (build, insert, spread) transfer memory losslessly" {
    const source =
        \\ base_map = { "x": 10, "y": 20 }
        \\ expanded = { "a": 1, **base_map, "z": 30 }
        \\ expanded["w"] = 40
        \\ expanded
    ;

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const final_val = try executeAndAssertStack(&vm, &main_chunk, 1);

    try std.testing.expect(final_val.isMap());
    const result_map = final_val.asMap();

    try std.testing.expectEqual(@as(usize, 5), result_map.map.count());

    const key_w = try vm.allocateString("w");
    const val_w = result_map.map.get(key_w).?;
    try std.testing.expectEqual(@as(f64, 40.0), val_w.asNumber());

    const key_x = try vm.allocateString("x");
    const val_x = result_map.map.get(key_x).?;
    try std.testing.expectEqual(@as(f64, 10.0), val_x.asNumber());
}

test "VM: DOD method splat packing and unpacking transfer memory losslessly" {
    // We test both `executePackSplat` (method parameters) and
    // `executeUnpackSplat` (multiple assignment) securely.
    const source =
        \\ def pack_test(first, *rest)
        \\   rest
        \\ end
        \\
        \\ # 1. Test executeUnpackSplat via Multiple Assignment
        \\ a, *b, c = [1, 2, 3, 4, 5]
        \\
        \\ # 2. Test executePackSplat via Function Invocation
        \\ packed = pack_test(1, 2, 3, 4, 5)
        \\
        \\ [b, packed]
    ;

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Tests that stack_top is completely restored after the complex memory shifts
    const final_val = try executeAndAssertStack(&vm, &main_chunk, 1);

    try std.testing.expect(final_val.isArray());
    const result_arr = final_val.asArray().items.items;

    // --- Verify executeUnpackSplat (b) ---
    const unpacked_arr = result_arr[0].asArray().items.items;
    try std.testing.expectEqual(@as(usize, 3), unpacked_arr.len);
    try std.testing.expectEqual(@as(f64, 2.0), unpacked_arr[0].asNumber());
    try std.testing.expectEqual(@as(f64, 4.0), unpacked_arr[2].asNumber());

    // --- Verify executePackSplat (packed) ---
    const packed_arr = result_arr[1].asArray().items.items;
    try std.testing.expectEqual(@as(usize, 4), packed_arr.len);
    try std.testing.expectEqual(@as(f64, 2.0), packed_arr[0].asNumber());
    try std.testing.expectEqual(@as(f64, 5.0), packed_arr[3].asNumber());
}

test "VM: uncaught raise of a number is a runtime error under stress GC" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    try testing.expectEqual(.runtime_error, try compileAndRunStressed(&vm, &out_chunk, "x = 1\nraise 42\nx = 2"));
    try testing.expectEqual(@as(f64, 1), vm.globals.get("x").?.asNumber());
}

test "VM: repeated raise and rescue of numbers under stress GC keeps every message" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Each iteration collects several times while a fresh exception is being built
    const source =
        \\matched = 0
        \\200.times do |i|
        \\  m = begin
        \\    raise i
        \\  rescue RuntimeError => e
        \\    e.message
        \\  end
        \\  if m == i.to_s
        \\    matched = matched + 1
        \\  end
        \\end
    ;
    try testing.expectEqual(.ok, try compileAndRunStressed(&vm, &out_chunk, source));
    try testing.expectEqual(@as(f64, 200), vm.globals.get("matched").?.asNumber());
}

test "VM: a native's scratch memory survives a backtrace and a nested run of its block" {
    // Both used to reset the shared scratch arena while the native was still using it.
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    try vm.defineNative("hold_scratch", holdScratch);

    var doc = try Document.parse(testing.allocator, "hold_scratch { [1, 2].map { |x| \"#{x}\" } }");
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.asBool());
}

test "VM: running out of memory for the stack is an error, not a panic" {
    // `push` grew the stack itself and panicked when it couldn't; frames now reserve their
    // compiled stack depth up front, where a failure is reported.
    var limit = @import("../core/limit_allocator.zig").LimitAllocator.init(testing.allocator, 4 * 1024 * 1024);
    var vm = try VM.init(limit.allocator(), testing.io);
    defer vm.deinit();
    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);

    var doc = try Document.parse(testing.allocator, "def f(n, a, b, c)\n  f(n + 1, a, b, c) + 1\nend\nf(0, 1, 2, 3)");
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(limit.allocator());
    var comp = Compiler.forDocument(limit.allocator(), &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    try testing.expectEqual(.runtime_error, vm.interpret(&out_chunk));
}

/// The address of the native's frame, as a Number: how deep the native stack is.
fn stackHere(_: *anyopaque, _: value.NativeArgs) anyerror!value.Value {
    return value.Value.initNumber(@floatFromInt(@frameAddress()));
}

test "VM: the nested runs the VM allows fit the native stack" {
    // Each run nested in a built-in's call (a block `map` calls, a raised class's
    // `initialize`) is native stack; MAX_NESTED_RUNS of the deepest kind must fit
    // NESTED_RUN_STACK_BUDGET, or a recursion through them crashes before the limit stops it.
    const levels = 50;
    const scripts = [_][]const u8{
        "def dive(n) = n == 0 ? stack_here() : [1].map { |x| dive(n - 1) }[0]\ntop = stack_here()\ndeep = dive(50)",
        "class Dive < RuntimeError\n  def initialize\n    $n -= 1\n    $deep = stack_here() if $n == 0\n    raise Dive if $n > 0\n  end\nend\n$n = 51\ntop = stack_here()\nbegin\n  raise Dive\nrescue Dive\nend\ndeep = $deep",
    };
    for (scripts) |src| {
        errdefer std.debug.print("script:\n{s}\n", .{src});
        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        vm.mute_errors = true;
        try registry.registerStandardLibrary(&vm);
        try vm.defineNative("stack_here", stackHere);
        try testing.expectEqual(InterpretResult.ok, try @import("../test_support.zig").runOn(&vm, src));
        const top = vm.globals.get("top").?.asNumber();
        const deep = vm.globals.get("deep").?.asNumber();
        const per_level = (top - deep) / levels; // the stack grows down
        errdefer std.debug.print("{d:.0} bytes a nested run: {d} of them take {d:.0} KiB\n", .{ per_level, VM.MAX_NESTED_RUNS, per_level * VM.MAX_NESTED_RUNS / 1024 });
        try testing.expect(per_level > 0);
        try testing.expect(per_level * VM.MAX_NESTED_RUNS <= NESTED_RUN_STACK_BUDGET);
    }
}
