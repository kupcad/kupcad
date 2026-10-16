const std = @import("std");
const testing = std.testing;
const VM = @import("vm.zig").VM;
const kernel = @import("../kernel/kernel.zig");
const dag = @import("dag.zig");
const geom = @import("../kernel/geometry_handle.zig");
const dag_evaluator = @import("dag_evaluator.zig");
const registry = @import("../stdlib/registry.zig");
const InterpretResult = @import("vm.zig").InterpretResult;
const chunk = @import("chunk.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;

fn initVm() !VM {
    var vm = try VM.init(testing.allocator, testing.io);
    errdefer vm.deinit();
    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);
    return vm;
}

/// Compiles and runs `source` on an existing VM.
fn runOn(vm: *VM, source: []const u8) !InterpretResult {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    return vm.interpret(&out_chunk);
}

fn evalVolume(vm: *VM, source: []const u8) !f64 {
    try testing.expectEqual(InterpretResult.ok, try runOn(vm, source));
    const result = vm.globals.get("result") orelse return error.NoResult;
    return result.asNumber();
}

test "DAG Evaluator: correctly evaluates 3D primitive (Cube)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Injects the active_kernel (manifold_driver)
    try registry.registerStandardLibrary(&vm);

    // 1. Manually build a DAG node without writing a script
    const cube_idx = try vm.dag_builder.addCube(10.0, 20.0, 30.0, true);

    // 2. Evaluate the node directly
    const handle = try dag_evaluator.evaluateDAG(&vm, cube_idx);

    // 3. Verify the C++ kernel materialized it correctly
    try testing.expectEqual(.manifold, handle.engine);

    // Verify physics to prove the Manifold C++ object is a 10x20x30 cube
    const vol = kernel.volume(handle);
    try testing.expectApproxEqAbs(@as(f64, 6000.0), vol, 1e-6);
}

test "DAG Evaluator: correctly evaluates CSG tree (Union)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Build DAG: cube(10) + cube(10).translate(10, 0, 0)
    const c1 = try vm.dag_builder.addCube(10.0, 10.0, 10.0, false);
    const c2 = try vm.dag_builder.addCube(10.0, 10.0, 10.0, false);
    const t2 = try vm.dag_builder.addTranslate(c2, 10.0, 0.0, 0.0);
    const union_idx = try vm.dag_builder.addBinary(.union_op, c1, t2);

    // Evaluate
    const handle = try dag_evaluator.evaluateDAG(&vm, union_idx);

    // Two 10x10x10 cubes side-by-side should be exactly 2000 volume
    const vol = kernel.volume(handle);
    try testing.expectApproxEqAbs(@as(f64, 2000.0), vol, 1e-6);
}

test "DAG Evaluator: a chain of unions is one batch, and its links still evaluate on their own" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // acc = a; acc = acc + b; acc = acc + c; acc = acc + d, four unit cubes in a row.
    var cubes: [5]u32 = undefined;
    for (&cubes, 0..) |*c, i| c.* = try vm.dag_builder.addTranslate(try vm.dag_builder.addCube(1, 1, 1, false), @floatFromInt(2 * i), 0, 0);
    const ab = try vm.dag_builder.addBinary(.union_op, cubes[0], cubes[1]);
    const abc = try vm.dag_builder.addBinary(.union_op, ab, cubes[2]);
    const abcd = try vm.dag_builder.addBinary(.union_op, abc, cubes[3]);

    try testing.expectApproxEqAbs(@as(f64, 4), kernel.volume(try dag_evaluator.evaluateDAG(&vm, abcd)), 1e-9);
    // The links were not evaluated for the batch, so they are not in the cache; asked for,
    // they are evaluated as the chains they are.
    try testing.expect(!vm.dag_cache.contains(vm.dag_builder.node_hashes.items[abc]));
    try testing.expectApproxEqAbs(@as(f64, 2), kernel.volume(try dag_evaluator.evaluateDAG(&vm, ab)), 1e-9);
    // A cached link is one operand of the chain above it.
    const abcde = try vm.dag_builder.addBinary(.union_op, abcd, cubes[4]);
    try testing.expectApproxEqAbs(@as(f64, 5), kernel.volume(try dag_evaluator.evaluateDAG(&vm, abcde)), 1e-9);
}

test "DAG Evaluator: a transform of a solid over the vertex budget is still refused" {
    // The result checks are skipped after a pure transform (the solid is its operand's);
    // the operand itself is checked, so nothing over the budget gets through.
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    try vm.setConfig(.{ .max_vertices = 10 });
    const moved = try vm.dag_builder.addTranslate(try vm.dag_builder.addSphere(10.0, 0), 1, 0, 0);
    try testing.expectError(error.RamBudgetExceeded, dag_evaluator.evaluateDAG(&vm, moved));

    // A transform keeps the operand's vertices, and is cached like any other result.
    try vm.setConfig(.{ .max_vertices = 1_000_000 });
    const cube_idx = try vm.dag_builder.addCube(1, 1, 1, false);
    const moved_cube = try vm.dag_builder.addRotate(try vm.dag_builder.addTranslate(cube_idx, 5, 0, 0), 0, 0, 45);
    const handle = try dag_evaluator.evaluateDAG(&vm, moved_cube);
    try testing.expectEqual(@as(usize, 8), kernel.numVerts(handle));
    try testing.expect(vm.dag_cache.contains(vm.dag_builder.node_hashes.items[moved_cube]));
}

test "DAG Builder: CSE Deduplication perfectly reuses identical nodes" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Create a 10x10x10 cube
    const c1 = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);

    // Create the exact same cube again
    const c2 = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);

    // Create a slightly different cube
    const c3 = try vm.dag_builder.addCube(10.0, 10.0, 10.0, false);

    // The DAG should map both c1 and c2 to the EXACT same memory node index!
    try testing.expectEqual(c1, c2);

    // c3 has a different flag (center: false), so it must be a unique node
    try testing.expect(c1 != c3);

    // Physical array length should only be 2, even though we requested 3 cubes
    try testing.expectEqual(@as(usize, 2), vm.dag_builder.nodes.items.len);
}

test "DAG Evaluator: correctly evaluates 2D extrusion to 3D" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Draw a 10x10 2D square
    const sq_idx = try vm.dag_builder.addSquare(10.0, 10.0, true);

    // 2. Extrude it by 20 units into 3D
    const ext_idx = try vm.dag_builder.addExtrude(sq_idx, 20.0, 0, 0.0, 1.0, 1.0);

    // 3. Evaluate the 3D extrusion DAG node
    const handle = try dag_evaluator.evaluateDAG(&vm, ext_idx);

    try testing.expectEqual(.manifold, handle.engine);

    // 10 * 10 * 20 = 2000 volume
    const vol = kernel.volume(handle);
    try testing.expectApproxEqAbs(@as(f64, 2000.0), vol, 1e-5);
}

test "DAG Evaluator: bounds checking prevents infinite recursion or crashes" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    // Provide a wildly out-of-bounds index
    const bad_idx: u32 = 9999;

    // Actually evaluate it!
    const result = dag_evaluator.evaluateDAG(&vm, bad_idx);

    // It must return our controlled RuntimeError instead of triggering an OS-level segfault/panic
    try testing.expectError(error.RuntimeError, result);
}

test "DAG Builder: Hash correctly distinguishes similar but distinct parameters" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const base = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);

    // Exact same translation
    const t1 = try vm.dag_builder.addTranslate(base, 5.0, 0.0, 0.0);
    const t2 = try vm.dag_builder.addTranslate(base, 5.0, 0.0, 0.0);
    try testing.expectEqual(t1, t2);

    // Slightly different translation (prevents false cache hits)
    const t3 = try vm.dag_builder.addTranslate(base, 5.0001, 0.0, 0.0);
    try testing.expect(t1 != t3);

    // Different operation, exact same parameters
    const r1 = try vm.dag_builder.addRotate(base, 5.0, 0.0, 0.0);
    try testing.expect(t1 != r1);
}

test "DAG Builder: Deep deduplication prevents redundant branch explosion" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Branch A
    const a_cube = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    const a_cyl = try vm.dag_builder.addCylinder(5.0, 5.0, 20.0, true, 32);
    const a_union = try vm.dag_builder.addBinary(.union_op, a_cube, a_cyl);

    // Branch B (Identical sequence built independently)
    const b_cube = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    const b_cyl = try vm.dag_builder.addCylinder(5.0, 5.0, 20.0, true, 32);
    const b_union = try vm.dag_builder.addBinary(.union_op, b_cube, b_cyl);

    // The top-level union indices must be perfectly identical
    try testing.expectEqual(a_union, b_union);

    // Total physical nodes allocated should be EXACTLY 3 (cube, cylinder, union) instead of 6
    try testing.expectEqual(@as(usize, 3), vm.dag_builder.nodes.items.len);
}

test "DAG Builder: Batch operations deduplicate securely based on array contents" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const c1 = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    const c2 = try vm.dag_builder.addSphere(5.0, 0);
    const c3 = try vm.dag_builder.addCylinder(2.0, 2.0, 10.0, true, 16);

    const batch1 = try vm.dag_builder.addBatchUnion(&.{ c1, c2, c3 });
    const batch2 = try vm.dag_builder.addBatchUnion(&.{ c1, c2, c3 });

    // Different array order must yield a different node hash
    const batch3 = try vm.dag_builder.addBatchUnion(&.{ c3, c2, c1 });

    try testing.expectEqual(batch1, batch2);
    try testing.expect(batch1 != batch3);
}

test "DAG Builder: Dynamic array payloads (Polygons) hash correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var pts1 = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 } };
    var pts2 = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 } };
    var pts3 = [_][2]f64{ .{ 0, 0 }, .{ 10.1, 0 }, .{ 0, 10 } };

    const p1 = try vm.dag_builder.addPolygon(&pts1);
    const p2 = try vm.dag_builder.addPolygon(&pts2);
    const p3 = try vm.dag_builder.addPolygon(&pts3);

    // Identical points array must deduplicate
    try testing.expectEqual(p1, p2);
    // Altered coordinate must break the hash collision
    try testing.expect(p1 != p3);
}

test "DAG Builder: even-odd polygons with different contour splits are distinct" {
    var vm = try initVm();
    defer vm.deinit();

    const pts = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 }, .{ 20, 20 }, .{ 30, 20 }, .{ 30, 30 }, .{ 20, 30 }, .{ 40, 40 } };

    // The hash itself must differ (per-contour lengths), not just the
    // structural check behind it. Fresh builders: hashes are content-based.
    var scratch_a = dag.DAGBuilder.init(testing.allocator);
    defer scratch_a.deinit();
    var scratch_b = dag.DAGBuilder.init(testing.allocator);
    defer scratch_b.deinit();
    const ha = scratch_a.node_hashes.items[try scratch_a.addPolygonsEvenOdd(&.{ pts[0..3], pts[3..8] })];
    const hb = scratch_b.node_hashes.items[try scratch_b.addPolygonsEvenOdd(&.{ pts[0..4], pts[4..8] })];
    try testing.expect(ha != hb);

    const a_idx = try vm.dag_builder.addPolygonsEvenOdd(&.{ pts[0..3], pts[3..8] });
    const b_idx = try vm.dag_builder.addPolygonsEvenOdd(&.{ pts[0..4], pts[4..8] });
    try testing.expect(a_idx != b_idx);

    const a_ext = try vm.dag_builder.addExtrude(a_idx, 1, 1, 0, 1, 1);
    const b_ext = try vm.dag_builder.addExtrude(b_idx, 1, 1, 0, 1, 1);
    try testing.expectApproxEqAbs(@as(f64, 150.0), kernel.volume(try dag_evaluator.evaluateDAG(&vm, a_ext)), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 200.0), kernel.volume(try dag_evaluator.evaluateDAG(&vm, b_ext)), 1e-6);
}

test "DAG: Builder cleans up payload arrays on OutOfMemory" {
    // Use a FixedBufferAllocator so we can reliably OOM the Arena
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var builder = dag.DAGBuilder.init(fba.allocator());
    defer builder.deinit();

    var i: f64 = 0;
    var last_good_extra: usize = 0;

    while (true) : (i += 1.0) {
        // Create a unique cube node each loop so CSE deduplication does not short-circuit
        const c = builder.addCube(i, 10.0, 10.0, true) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            break;
        };

        const dummy_targets: [20]dag.DAGNodeIndex = @splat(c);
        last_good_extra = builder.extra_data.items.len;

        _ = builder.addBatchUnion(&dummy_targets) catch |err| {
            // Assert that we successfully triggered an OOM
            try testing.expectEqual(error.OutOfMemory, err);
            // Verify that extra_data was rolled back to its exact pre-call length
            try testing.expectEqual(last_good_extra, builder.extra_data.items.len);
            break;
        };
    }
}

test "DAG Evaluator: iterative engine handles extreme depths without C-stack overflow" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Create a base cube
    var current_node = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);

    // 2. Chain 1,000 translations sequentially.
    // In a recursive evaluator, a depth of 1,000 would instantly cause a C-stack overflow / segfault.
    // The new `EvaluationFrameStack` handles this entirely on the heap iteratively.
    const depth = 1000;
    for (0..depth) |_| {
        current_node = try vm.dag_builder.addTranslate(current_node, 1.0, 0.0, 0.0);
    }

    // 3. Evaluate the extremely deep DAG
    const handle = try dag_evaluator.evaluateDAG(&vm, current_node);

    // 4. Verify the geometry survived the traversal intact
    const vol = kernel.volume(handle);
    try testing.expectApproxEqAbs(@as(f64, 1000.0), vol, 1e-5);
}

test "DAG Evaluator: correctly evaluates 2D primitive via evaluateCrossSectionDAG" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Build a 2D Square
    const sq_idx = try vm.dag_builder.addSquare(10.0, 10.0, true);

    // 2. Add a 2D Offset operation
    const offset_idx = try vm.dag_builder.addOffset(sq_idx, 2.0, 0);

    // 3. Evaluate explicitly requesting a 2D CrossSectionHandle
    const handle = try dag_evaluator.evaluateCrossSectionDAG(&vm, offset_idx);
    defer kernel.destructCrossSection(handle);

    try testing.expectEqual(.manifold, handle.engine);

    // Base area 10x10 = 100. Expanding by 2 on all sides makes it 14x14 = 196
    const bounds = kernel.crossSectionBounds(handle);
    try testing.expectApproxEqAbs(@as(f64, -7.0), bounds.min[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 7.0), bounds.max[0], 1e-5);
}

test "DAG Evaluator: safely traps cross-section vs geometry type mismatch and cleans up memory" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Build a 2D Square
    const sq_idx = try vm.dag_builder.addSquare(10.0, 10.0, true);

    // 2. Erroneously evaluate it as a 3D Geometry DAG
    const result = dag_evaluator.evaluateDAG(&vm, sq_idx);

    // 3. It must trap the mismatch and return RuntimeError. The 2D handle is
    // destroyed by evaluateDAG (cross-sections are never cached).
    try testing.expectError(error.RuntimeError, result);
    try testing.expectEqual(@as(u32, 0), vm.dag_cache.count());
}

test "DAG Evaluator: evaluateCrossSectionDAG traps 3D geometry mismatch" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Build a 3D Cube
    const cube_idx = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);

    // 2. Erroneously evaluate it as a 2D CrossSection DAG
    const result = dag_evaluator.evaluateCrossSectionDAG(&vm, cube_idx);

    // 3. Must return RuntimeError and safely drop the 3D handle
    try testing.expectError(error.RuntimeError, result);
}

test "DAG Evaluator: O(1) DAG Cache bypasses kernel evaluation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Build a basic node and evaluate it natively
    const c1 = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    const handle1 = try dag_evaluator.evaluateDAG(&vm, c1);

    // 2. Ensure it populated the VM's DAG cache under its node hash (which covers its settings)
    const hash = vm.dag_builder.node_hashes.items[c1];
    try testing.expect(vm.dag_cache.contains(hash));

    // 3. Evaluate the exact same node again. It MUST pull from cache.
    const handle2 = try dag_evaluator.evaluateDAG(&vm, c1);

    // The raw C++ FFI pointers must be perfectly identical (vm.deinit frees it once).
    try testing.expectEqual(handle1.ptr, handle2.ptr);
}

test "DAG Evaluator: a node is built with the settings it was made under" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const coarse_idx = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    const coarse = try dag_evaluator.evaluateDAG(&vm, coarse_idx);

    // The same cube made under another tolerance is another node, with its own result.
    try vm.pushConfig(.{ .tolerance = 1e-3 });
    const fine_idx = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    try testing.expect(fine_idx != coarse_idx);
    const fine = try dag_evaluator.evaluateDAG(&vm, fine_idx);
    try testing.expect(coarse.ptr != fine.ptr);
    // A node evaluated while other settings are in force keeps its own.
    try testing.expectEqual(coarse.ptr, (try dag_evaluator.evaluateDAG(&vm, coarse_idx)).ptr);
    vm.popConfig();

    try testing.expectEqual(@as(u32, 2), vm.dag_cache.count());
    try testing.expectEqual(fine.ptr, (try dag_evaluator.evaluateDAG(&vm, fine_idx)).ptr);
}

test "DAG Evaluator: RAM budgeting traps complex meshes" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Artificially lower the RAM budget to 10 vertices
    try vm.setConfig(.{ .max_vertices = 10 });

    // A high-segment sphere will easily exceed 10 vertices
    const sphere_idx = try vm.dag_builder.addSphere(10.0, 0);

    const result = dag_evaluator.evaluateDAG(&vm, sphere_idx);

    // Must return the specific budget error, not a generic panic
    try testing.expectError(error.RamBudgetExceeded, result);
}

test "DAG Evaluator: evaluation error keeps cache-owned operands alive" {
    var vm = try initVm();
    defer vm.deinit(); // the cached cube used to be freed twice here

    // Cache the cube, then make a sphere under a vertex budget it blows.
    const cube_idx = try vm.dag_builder.addCube(1, 1, 1, false);
    const cube_h = try dag_evaluator.evaluateDAG(&vm, cube_idx);
    try vm.setConfig(.{ .max_vertices = 100 });
    const sphere_idx = try vm.dag_builder.addSphere(5, 0);
    const union_idx = try vm.dag_builder.addBinary(.union_op, cube_idx, sphere_idx);

    try testing.expectError(error.RamBudgetExceeded, dag_evaluator.evaluateDAG(&vm, union_idx));

    // The cached cube must still be the live, cache-owned handle.
    const again = try dag_evaluator.evaluateDAG(&vm, cube_idx);
    try testing.expectEqual(cube_h.ptr, again.ptr);
    try testing.expectApproxEqAbs(@as(f64, 1.0), kernel.volume(again), 1e-9);
}

test "DAG Evaluator: B-Rep engine config yields a B-Rep cube" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Switch the active engine config to B-Rep
    try vm.setConfig(.{ .engine = .brep_native });

    const cube_idx = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    const handle = try dag_evaluator.evaluateDAG(&vm, cube_idx);

    try testing.expectEqual(geom.EngineType.brep_native, handle.engine);
    try testing.expectEqual(@as(usize, 8), kernel.numVerts(handle));
}

test "DAG Evaluator: the same shape under two engines is two nodes" {
    var vm = try initVm();
    defer vm.deinit();

    const small_mesh = try vm.dag_builder.addCube(10, 10, 10, false);
    const m = try dag_evaluator.evaluateDAG(&vm, small_mesh);
    try testing.expectEqual(geom.EngineType.manifold, m.engine);

    // It used to be one node, so the B-Rep evaluation was a cache hit on the Manifold handle.
    try vm.setConfig(.{ .engine = .brep_native });
    const small = try vm.dag_builder.addCube(10, 10, 10, false);
    try testing.expect(small != small_mesh);
    const b = try dag_evaluator.evaluateDAG(&vm, small);
    try testing.expectEqual(geom.EngineType.brep_native, b.engine);

    // A hull, since it is an operation both engines have.
    const big = try vm.dag_builder.addCube(20, 20, 20, false);
    const h = try dag_evaluator.evaluateDAG(&vm, try vm.dag_builder.addBatchHull(&.{ big, small }));
    try testing.expectEqual(geom.EngineType.brep_native, h.engine);
}

test "DAG Evaluator: GC keeps the B-Rep cache entry of live geometry" {
    var vm = try initVm();
    defer vm.deinit();

    // `a` stays rooted as a global, so its cached handle must survive GC.
    try testing.expectEqual(InterpretResult.ok, try runOn(&vm,
        \\CAD.config(engine: :brep)
        \\a = cube(10)
        \\a.simplify
    ));
    const cached = vm.dag_cache.count();
    try testing.expect(cached > 0);

    // Eviction must check the entry's node hash, not its key (which mixes in the
    // settings), or every B-Rep entry looks dead and is freed.
    vm.resetStack();
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(cached, vm.dag_cache.count());
}

test "DAG Evaluator: rejects a DAG mixing engines" {
    // A decompose result is a `.concrete` leaf that keeps its Manifold handle
    // after the engine switches, so the union below has mixed operands.
    var vm = try initVm();
    defer vm.deinit();
    try testing.expectEqual(InterpretResult.runtime_error, try runOn(&vm,
        \\part = cube(10).decompose[0]
        \\CAD.config(engine: :brep)
        \\(part + cube(1)).volume
    ));
}

test "DAG Evaluator: decompose/simplify results feed later DAG ops" {
    var vm = try initVm();
    defer vm.deinit();
    vm.zealous_gc = true; // concrete handles must survive collection of their ObjGeometry

    try testing.expectApproxEqAbs(@as(f64, 1000.0), try evalVolume(&vm, "result = cube(10).decompose[0].translate(x: 1).volume"), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1000.0), try evalVolume(&vm,
        \\a = cube(10)
        \\result = (a.simplify + cube(1)).volume
    ), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 999.0), try evalVolume(&vm,
        \\parts = cube(10).decompose
        \\result = (parts[0] - cube(1)).simplify.volume
    ), 1e-6);
}

test "DAG Evaluator: respects atomic cancellation token" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const cube_idx = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);

    // Simulate the LSP or UI triggering a cancel right before evaluation
    vm.cancel_token.store(true, .release);

    const result = dag_evaluator.evaluateDAG(&vm, cube_idx);

    try testing.expectError(error.Canceled, result);
}

test "DAG Evaluator: dynamic stacks handle massive batches without overflow" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Create a batch operation containing 5,000 distinct items (exceeding the old 4,096 cap)
    const count = 5000;
    var targets = try testing.allocator.alloc(dag.DAGNodeIndex, count);
    defer testing.allocator.free(targets);

    // Ensure we don't accidentally trip the RAM budget during the stress test
    try vm.setConfig(.{ .max_vertices = 50_000_000 });
    // Unit cubes in a row, apart: each is its own node (CSE can't merge them), and the
    // kernel has no overlaps to cut, so the test is about the stacks, not the boolean (5000
    // nested cubes of growing width made it the slowest test of the suite).
    const cube = try vm.dag_builder.addCube(1.0, 1.0, 1.0, false);
    for (0..count) |i| targets[i] = try vm.dag_builder.addTranslate(cube, 2.0 * @as(f64, @floatFromInt(i)), 0, 0);

    const batch_idx = try vm.dag_builder.addBatchUnion(targets);
    const handle = try dag_evaluator.evaluateDAG(&vm, batch_idx);
    try testing.expectEqual(geom.EngineType.manifold, handle.engine);
    try testing.expectApproxEqAbs(@as(f64, count), kernel.volume(handle), 1e-6);
}

test "DAG Builder: Polyhedron CSE uses O(1) precomputed hash correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const pts = [_][3]f64{
        .{ 0.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
    };
    const faces = [_][3]u32{
        .{ 0, 1, 2 },
        .{ 0, 3, 1 },
        .{ 0, 2, 3 },
        .{ 1, 3, 2 },
    };

    // Add the exact same polyhedron twice
    const node1 = try vm.dag_builder.addPolyhedron(&pts, &faces);
    const node2 = try vm.dag_builder.addPolyhedron(&pts, &faces);

    // Because the precomputed u64 hash is identical, the CSE engine should
    // perfectly deduplicate them.
    try testing.expectEqual(node1, node2);
    try testing.expectEqual(@as(usize, 1), vm.dag_builder.nodes.items.len);
}
