const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const dag_evaluator = @import("dag_evaluator.zig");
const VM = @import("vm.zig").VM;
const GC = @import("memory.zig").GC;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../frontend/document.zig").Document;

fn countObjects(gc: *GC) usize {
    var count: usize = 0;

    // Sum the length of every segregated object pool
    count += gc.strings.items.len;
    count += gc.symbols.items.len;
    count += gc.arrays.items.len;
    count += gc.maps.items.len;
    count += gc.json_objects.items.len;
    count += gc.functions.items.len;
    count += gc.classes.items.len;
    count += gc.modules.items.len;
    count += gc.instances.items.len;
    count += gc.closures.items.len;
    count += gc.upvalues.items.len;
    count += gc.bound_methods.items.len;
    count += gc.ranges.items.len;
    count += gc.geometries.items.len;
    count += gc.cross_sections.items.len;
    count += gc.workplanes.items.len;

    return count;
}

/// For a test that counts objects between the collections it makes itself: none at an
/// allocation, whatever the build (-Dgc-stress collects at every one) or the heap's growth.
fn collectOnlyWhenAsked(vm: *VM) void {
    vm.gc.stress = false;
    vm.gc.next_gc_threshold = std.math.maxInt(usize);
}

test "GC: Mark and Sweep reclaims unreferenced primitive objects" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    collectOnlyWhenAsked(&vm);
    try registry.registerStandardLibrary(&vm);

    _ = try vm.allocateString("I am dead");
    const alive_val = try vm.allocateString("I am alive");

    vm.push(alive_val);

    const count_before = countObjects(&vm.gc);
    vm.gc.collectGarbage(&vm, false);
    const count_after = countObjects(&vm.gc);

    try testing.expect(count_before > count_after);
}

test "GC: allocateRange correctly registers and sweeps" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const count_before = countObjects(&vm.gc); // Should equal 3

    // Allocate a new range primitive
    const range = try vm.gc.allocateRange(&vm, 1.0, 10.0, 1.0, false);

    // Verify it was added to the GC linked list
    try testing.expectEqual(count_before + 1, countObjects(&vm.gc));
    try testing.expectEqual(@as(f64, 1.0), range.start);
    try testing.expectEqual(@as(f64, 10.0), range.end);
    try testing.expectEqual(false, range.is_exclusive);

    // Trigger a garbage collection cycle.
    // Because we NEVER pushed the range to the VM Stack (vm.push),
    // the GC's markRoots phase will see it as unreachable/dead memory.
    vm.gc.collectGarbage(&vm, false);

    // Verify it was cleanly swept from the heap
    try testing.expectEqual(count_before, countObjects(&vm.gc));
}

test "GC: Basic sweep of unrooted objects" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    collectOnlyWhenAsked(&vm);

    _ = try vm.gc.allocateString(&vm, "unrooted1");
    _ = try vm.gc.allocateArray(&vm);

    // We allocated 5 objects
    try testing.expectEqual(@as(usize, 5), countObjects(&vm.gc));

    vm.gc.collectGarbage(&vm, false);

    // Neither were pushed to the VM stack, so the sweep MUST destroy both
    try testing.expectEqual(@as(usize, 3), countObjects(&vm.gc));
}

test "GC: Rooted objects survive the sweep" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const str_obj = try vm.gc.allocateString(&vm, "rooted");
    vm.push(value.Value.initObj(&str_obj.obj)); // Root it to the stack!

    _ = try vm.gc.allocateArray(&vm); // Leave unrooted

    try testing.expectEqual(@as(usize, 5), countObjects(&vm.gc));

    vm.gc.collectGarbage(&vm, false);

    // The string was pushed to the stack, so it survives. The array dies.
    try testing.expectEqual(@as(usize, 4), countObjects(&vm.gc));
    try testing.expectEqual(@as(usize, 4), vm.gc.strings.items.len);
    try testing.expectEqual(@as(usize, 0), vm.gc.arrays.items.len);
}

test "GC Stress: High volume allocations and segmented sweeps" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    collectOnlyWhenAsked(&vm);

    // We will allocate 10,000 Arrays and 10,000 Strings (20,000 total objects)
    const total_allocs = 10_000;

    // We will only root exactly 500 of each type
    const rooted_amount = 500;

    for (0..total_allocs) |i| {
        // Allocate unique strings to bypass the intern cache
        var buf: [16]u8 = undefined;
        const str_val = std.mem.print(&buf, "str{d}", .{i}) catch unreachable;

        // Take ownership of a duped string
        const s = try vm.gc.takeString(&vm, try vm.gc.trackingAllocator().dupe(u8, str_val));

        // Allocate empty array
        const a = try vm.gc.allocateArray(&vm);

        // Root only the first `rooted_amount` objects
        if (i < rooted_amount) {
            vm.push(value.Value.initObj(&s.obj));
            vm.push(value.Value.initObj(&a.obj));
        }
    }

    // Verify pre-GC counts. We should have exactly 20,000 + 3 objects in memory.
    try testing.expectEqual((total_allocs * 2) + 3, countObjects(&vm.gc));

    // The specific DOD tracking arrays must match exactly
    try testing.expectEqual(total_allocs + 3, vm.gc.strings.items.len);
    try testing.expectEqual(total_allocs, vm.gc.arrays.items.len);

    // Run the massive Sweep
    vm.gc.collectGarbage(&vm, false);

    // Verify post-GC counts precisely match the rooted amounts!
    // The GC should have deleted exactly 19,000 objects in a fraction of a millisecond.
    try testing.expectEqual((rooted_amount * 2) + 3, countObjects(&vm.gc));

    // The segregated arrays must have shrunk using `swapRemove` down to 500.
    try testing.expectEqual(rooted_amount + 3, vm.gc.strings.items.len);
    try testing.expectEqual(rooted_amount, vm.gc.arrays.items.len);
}

test "GC: Nested objects (Arrays) survive sweep if parent is rooted" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const parent_arr = try vm.gc.allocateArray(&vm);
    vm.push(value.Value.initObj(&parent_arr.obj)); // Root the parent array

    const child_str = try vm.gc.allocateString(&vm, "child_string");
    // Do NOT push child_str to the stack. Add it directly to the array.
    try parent_arr.items.append(vm.gc.trackingAllocator(), value.Value.initObj(&child_str.obj));

    const count_before = countObjects(&vm.gc);
    vm.gc.collectGarbage(&vm, false);
    const count_after = countObjects(&vm.gc);

    // Both the array and the string inside it must survive because `blackenObject` traces nested items
    try testing.expectEqual(count_before, count_after);
    try testing.expectEqual(@as(usize, 4), vm.gc.strings.items.len); // 3 statics + 1 child_string
}

test "GC: String interning prevents duplicate allocations" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const str1 = try vm.gc.allocateString(&vm, "intern_me");
    const str2 = try vm.gc.allocateString(&vm, "intern_me");

    // Must return the exact same memory pointer from the VM's StringHashMap
    try testing.expectEqual(str1, str2);

    // Only 1 string should be physically allocated (+ the static true/false/nil strings)
    try testing.expectEqual(@as(usize, 4), vm.gc.strings.items.len);
}

test "GC Sandbox: Enforces max_memory_limit strictly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Set limit extremely tight (just current allocation footprint + 5 bytes)
    vm.gc.max_memory_limit = vm.gc.bytes_allocated + 5;

    // Attempting to allocate a large string should hit the sandbox threshold immediately
    const result = vm.gc.allocateString(&vm, "this is way too large for the sandbox");

    // The allocator should intercept it and yield an error to halt the VM
    try testing.expectError(error.OutOfMemory, result);
}

test "GC: Mass allocation and sweep underflow protection" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.hooks.setZealousGc(true);

    // Allocate and free multiple batches of dynamic strings and closures
    for (0..500) |i| {
        const str_buf = try testing.allocator.print("tmp_string_{d}", .{i});
        defer testing.allocator.free(str_buf);

        _ = try vm.allocateString(str_buf);
        if (i % 10 == 0) {
            vm.gc.collectGarbage(&vm, false);
        }
    }

    // Force full sweep and ensure byte counter didn't wrap around
    vm.gc.collectGarbage(&vm, true);
    try testing.expect(vm.gc.bytes_allocated < 1000);
}

test "GC: successfully sweeps orphaned DAG cache handles" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const cube_idx = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);

    // 1. Evaluate and cache the cube
    _ = try dag_evaluator.evaluateDAG(&vm, cube_idx);
    try testing.expect(vm.dag_cache.count() == 1);

    // 2. Clear all VM references to geometries (simulating variable going out of scope)
    vm.resetStack();
    vm.display_list.clearRetainingCapacity();
    vm.gc.geometries.clearRetainingCapacity();

    // 3. Force a full Mark-and-Sweep
    vm.gc.collectGarbage(&vm, true);

    // 4. The cache should be empty, and no C++ leaks should occur
    try testing.expect(vm.dag_cache.count() == 0);
}

test "GC: Unrooted objects are cleanly swept without double-frees" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const initial_strings = vm.gc.strings.items.len;

    // 1. Allocate a string but DO NOT push it to the VM stack.
    // This simulates an object that was allocated and added to the tracking list,
    // but failed to fully register (e.g., if a hash map insertion threw OutOfMemory).
    _ = try vm.gc.allocateString(&vm, "transient_leak_test");

    // 2. Verify the GC is tracking the newly allocated memory
    try std.testing.expectEqual(initial_strings + 1, vm.gc.strings.items.len);

    // 3. Force a full Garbage Collection sweep.
    // If we had manually called `destroyObject` earlier, this sweep would trigger a fatal Use-After-Free crash.
    vm.gc.collectGarbage(&vm, false);

    // 4. Verify the unrooted string was perfectly cleaned up by the tracker
    try std.testing.expectEqual(initial_strings, vm.gc.strings.items.len);
}

test "GC Edge Case: Sweep handles OutOfMemory gracefully without panicking" {
    // This allocator will fail immediately on its first request
    var fail_alloc = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Populate DAG cache
    const cube_idx = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    _ = try dag_evaluator.evaluateDAG(&vm, cube_idx);

    // Unroot geometry
    vm.resetStack();
    vm.display_list.clearRetainingCapacity();
    vm.gc.geometries.clearRetainingCapacity();

    // Swap the GC allocator to the failing allocator right before sweeping
    vm.gc.allocator = fail_alloc.allocator();

    // The sweep should fail to allocate `live_hashes`, skip eviction, and NOT panic!
    vm.gc.collectGarbage(&vm, true);

    // Restore standard allocator so deinit() can clean up successfully
    vm.gc.allocator = testing.allocator;

    // The cache item should survive because eviction was aborted
    try testing.expectEqual(@as(usize, 1), vm.dag_cache.count());
}

// --- Constants of a chunk under compilation must be GC roots ---

fn expectGlobalString(vm: *VM, name: []const u8, expected: []const u8) !void {
    const val = vm.globals.get(name) orelse return error.MissingGlobal;
    try testing.expect(val.isString());
    try testing.expectEqualStrings(expected, val.asString().chars);
}

test "GC: string constants survive collections triggered during compilation" {
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
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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

test "GC: an object whose list entry can't be allocated is freed, not leaked" {
    // allocateObject created the object, then appended it to its type's list; a failed
    // append returned OutOfMemory with the object unreachable by the sweep.
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try testing.expectEqual(@as(usize, 0), vm.gc.bboxes.items.len);

    // The first allocation is the object, the second its list's storage.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    vm.gc.allocator = failing.allocator();
    const before = vm.gc.bytes_allocated;
    try testing.expectError(error.OutOfMemory, vm.gc.allocateBBox(&vm, 0, 0, 0, 1, 1, 1));
    vm.gc.allocator = testing.allocator;
    try testing.expectEqual(before, vm.gc.bytes_allocated);
    try testing.expectEqual(@as(usize, 0), vm.gc.bboxes.items.len);
    // testing.allocator reports the object as leaked at deinit if it wasn't destroyed.
}

test "GC: a script past its memory limit stops with an OutOfMemoryError" {
    // The GC had the cap all along, but nothing ever set it.
    const support = @import("../test_support.zig");
    for ([_]struct { limit: ?usize, outcome: @import("vm.zig").InterpretResult }{
        .{ .limit = 64 * 1024, .outcome = .runtime_error },
        .{ .limit = null, .outcome = .ok },
    }) |case| {
        var vm = try support.initVm();
        defer vm.deinit();
        vm.setMemoryLimit(case.limit);
        try std.testing.expectEqual(case.outcome, try support.runOn(&vm, "a = []\n2000.times { |i| a.push(\"item number #{i}\") }\nr = a.length"));
        // The error itself, naming the limit: it used to be a "Sandbox Error" the GC logged
        // first, and "Array#push ran out of memory" where a built-in's allocation failed.
        if (case.limit) |limit| {
            var buf: [96]u8 = undefined;
            const expected = try std.mem.print(&buf, "OutOfMemoryError: the script exceeded its memory limit of {d} bytes", .{limit});
            try std.testing.expect(std.mem.startsWith(u8, vm.last_error orelse "", expected));
        }
    }
}

test "GC: a heap filled by small allocations still raises an OutOfMemoryError it can rescue" {
    // Filled to the byte, the heap had no room left for the error itself: the run ended with
    // "out of memory while raising an error", which no rescue sees.
    const support = @import("../test_support.zig");
    for ([_][]const u8{
        "a = []\nwhile true\n    a = [a, a]\n  end", // objects
        "a = []\nwhile true\n    a.push(\"item #{a.length}\")\n  end", // an array's growth, and strings
    }) |body| {
        errdefer std.debug.print("body: {s}\n", .{body});
        var vm = try support.initVm();
        defer vm.deinit();
        const limit = vm.gc.bytes_allocated + 256 * 1024;
        vm.setMemoryLimit(limit);
        var buf: [256]u8 = undefined;
        const source = try std.mem.print(&buf, "r = begin\n  {s}\nrescue OutOfMemoryError => e\n  e.message\nend\na = nil\nafter = \"ran on\"", .{body});
        try std.testing.expectEqual(.ok, try support.runOn(&vm, source));
        var message: [96]u8 = undefined;
        const expected = try std.mem.print(&message, "the script exceeded its memory limit of {d} bytes", .{limit});
        try std.testing.expect(std.mem.startsWith(u8, vm.globals.get("r").?.asString().chars, expected));
        try support.expectValue(.{ .str = "ran on" }, vm.globals.get("after").?);
    }
}

test "GC: the reserve an OutOfMemoryError is raised with caps the heap, kept errors and all" {
    // Each error a script rescues and keeps takes some of the reserve; once it is gone the run
    // stops, the heap never past the limit by more than the reserve.
    const support = @import("../test_support.zig");
    const OUT_OF_MEMORY_RESERVE = @import("memory.zig").OUT_OF_MEMORY_RESERVE;
    var vm = try support.initVm();
    defer vm.deinit();
    const limit = vm.gc.bytes_allocated + 128 * 1024;
    vm.setMemoryLimit(limit);
    const source =
        \\kept = []
        \\while true
        \\  begin
        \\    kept.push([kept.length, "item #{kept.length}"])
        \\  rescue OutOfMemoryError => e
        \\    kept.push(e)
        \\  end
        \\end
    ;
    try std.testing.expectEqual(.runtime_error, try support.runOn(&vm, source));
    try std.testing.expect(vm.gc.bytes_allocated <= limit + OUT_OF_MEMORY_RESERVE);
}

test "GC: garbage is collected before the memory limit stops a script" {
    // Collection ran only past the 1 MB growth threshold, so under a lower limit (or near a
    // 1 GiB one) a loop that kept nothing stopped with a Sandbox Error once its garbage
    // reached the limit. Ranges are objects alone, so each allocation meets the check.
    const support = @import("../test_support.zig");
    var vm = try support.initVm();
    defer vm.deinit();
    const headroom = 256 * 1024;
    vm.setMemoryLimit(vm.gc.bytes_allocated + headroom);
    // Garbage enough to fill the limit four times over.
    var buf: [64]u8 = undefined;
    const source = try std.mem.print(&buf, "i = 0\nwhile i < {d}\n  g = (0..i)\n  i += 1\nend", .{4 * headroom / @sizeOf(value.ObjRange)});
    try std.testing.expectEqual(.ok, try support.runOn(&vm, source));
}

test "GC: an allocation the memory limit refuses raises an error the script can rescue" {
    // The dispatch loop ended the run with no message when an allocation failed.
    const support = @import("../test_support.zig");
    var vm = try support.initVm();
    defer vm.deinit();
    const limit = vm.gc.bytes_allocated + 256 * 1024;
    vm.setMemoryLimit(limit);
    const source =
        \\s = "x"
        \\r = begin
        \\  while true
        \\    s = s + s
        \\  end
        \\rescue OutOfMemoryError => e
        \\  e.message
        \\end
    ;
    try std.testing.expectEqual(.ok, try support.runOn(&vm, source));
    var buf: [96]u8 = undefined;
    try support.expectValue(.{ .str = try std.mem.print(&buf, "the script exceeded its memory limit of {d} bytes", .{limit}) }, vm.globals.get("r").?);
}

test "GC: a rescued allocation failure goes on in the handler, not out of the run" {
    // An instruction whose own allocation failed (spreading an array here) returned the
    // rescue's result from the run itself: a rescued OutOfMemoryError ended the script as if
    // it had finished, before the handler and everything after it.
    const support = @import("../test_support.zig");
    var vm = try support.initVm();
    defer vm.deinit();
    vm.setMemoryLimit(vm.gc.bytes_allocated + 256 * 1024);
    const source =
        \\big = (1..20000).to_a
        \\r = begin
        \\  both = [*big, *big]
        \\  "no error"
        \\rescue OutOfMemoryError => e
        \\  "rescued"
        \\end
        \\after = "ran on"
    ;
    const result = try support.runOn(&vm, source);
    errdefer std.debug.print("last error: {s}\n", .{vm.last_error orelse "-"});
    try std.testing.expectEqual(.ok, result);
    try support.expectValue(.{ .str = "rescued" }, vm.globals.get("r") orelse return error.MissingGlobal);
    try support.expectValue(.{ .str = "ran on" }, vm.globals.get("after") orelse return error.MissingGlobal);
}

test "GC: the standard library's natives and names live with the VM, outside the sweep" {
    // Each native and each name was its own GC allocation, freed at teardown: a VM cost about
    // 850 allocations before running anything, and the test suite most of its time.
    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var vm = try VM.init(counting.allocator(), testing.io);
    defer vm.deinit();
    const before = counting.allocations;
    try registry.registerStandardLibrary(&vm);
    try testing.expect(counting.allocations - before < 200);

    // None of them is in a list the sweep walks, so a collection keeps every one.
    const strings_before = vm.gc.strings.items.len;
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(strings_before, vm.gc.strings.items.len);
    try testing.expect(vm.globals.get("cube").?.isNative());

    // A script string with a built-in name's text is that static string, unharmed by
    // collections (a freed string's bytes are overwritten).
    const union_name = try vm.allocateString("union");
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(union_name.asObj(), (try vm.allocateString("union")).asObj());
    try testing.expectEqualStrings("union", union_name.asString().chars);
}

test "GC: a script runs as before on a VM collected after registering the library" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.gc.collectGarbage(&vm, false);

    var doc = try Document.parse(testing.allocator, "r = [3, 1, 2].sort.map { |v| v * cube(1).volume }\nm = Math::PI.round(2)\n");
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    vm.gc.stress = true; // collect on every allocation while it runs
    defer vm.gc.stress = false;
    try testing.expectEqual(.ok, vm.interpret(&out_chunk));
    try testing.expectEqual(@as(usize, 3), vm.globals.get("r").?.asArray().items.items.len);
    try testing.expectApproxEqAbs(@as(f64, 3.14), vm.globals.get("m").?.asNumber(), 1e-9);
}

test "GC: a top-level def outlives the chunk it ran from, and a collection then reads no freed chunk" {
    // Every top-level function holds the script closure as its `self`; that closure pointed
    // at the chunk the caller freed (a session frees each module's), so the next collection
    // read freed memory: the nightly GC-stress run crashed on a session's second evaluation.
    const support = @import("../test_support.zig");
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, "def f = 1\ng = -> { 2 }"));
    const g = vm.globals.get("g").?.asClosure();
    try testing.expect(g.home_self.asClosure().function.chunk == null);
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(.ok, try support.runOn(&vm, "r = f() + g.call"));
    try support.expectValue(.{ .num = 3 }, vm.globals.get("r").?);
}
