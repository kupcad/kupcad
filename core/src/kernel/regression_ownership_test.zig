//! Regression tests for issues found in the Oct 2026 audit.
//!
//! Geometry handle ownership (single-owner rule), engine-tag confusion and DAG
//! CSE deduplication.

const std = @import("std");
const testing = std.testing;
const kernel = @import("kernel.zig");
const geom = @import("geometry_handle.zig");
const dag = @import("../vm/dag.zig");
const dag_evaluator = @import("../vm/dag_evaluator.zig");
const VM = @import("../vm/vm.zig").VM;
const InterpretResult = @import("../vm/vm.zig").InterpretResult;
const chunk = @import("../vm/chunk.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("../stdlib/registry.zig");
const ScriptSession = @import("../daemon/session.zig").ScriptSession;

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

fn runScript(source: []const u8) !InterpretResult {
    var vm = try initVm();
    defer vm.deinit(); // double frees used to crash here
    return runOn(&vm, source);
}

// --- Finding 1: drivers must never return their input handle ---

test "Regression ownership: brep no-op ops return new handles, never their input" {
    const cube = kernel.cube(.brep_native, 10, 10, 10, false) orelse return error.KernelFailed;
    defer kernel.destruct(cube);

    const mat = kernel.setMaterial(cube, 1) orelse return error.KernelFailed;
    defer kernel.destruct(mat);
    try testing.expect(mat.ptr != cube.ptr);

    const simp = kernel.simplify(cube, 0.01) orelse return error.KernelFailed;
    defer kernel.destruct(simp);
    try testing.expect(simp.ptr != cube.ptr);

    const parts = kernel.decompose(testing.allocator, cube) orelse return error.KernelFailed;
    defer {
        for (parts) |p| kernel.destruct(p);
        testing.allocator.free(parts);
    }
    for (parts) |p| try testing.expect(p.ptr != cube.ptr);

    const single = kernel.batchBoolean(testing.allocator, &.{cube}, .union_op) orelse return error.KernelFailed;
    defer kernel.destruct(single);
    try testing.expect(single.ptr != cube.ptr);

    // B-Rep offset is unimplemented and used to return its input cross-section.
    const sq = kernel.square(.brep_native, 10, 10, false) orelse return error.KernelFailed;
    defer kernel.destructCrossSection(sq);
    const off = kernel.offset(sq, 1, 0) orelse return error.KernelFailed;
    defer kernel.destructCrossSection(off);
    try testing.expect(off.ptr != sq.ptr);
}

test "Regression ownership: brep scripts using material/decompose/simplify do not double free" {
    try testing.expectEqual(InterpretResult.ok, try runScript(
        \\CAD.config(engine: :brep)
        \\part = cube(10).material(color: "#FF0000")
        \\part.volume
    ));
    try testing.expectEqual(InterpretResult.ok, try runScript(
        \\CAD.config(engine: :brep)
        \\part = cube(10).decompose[0]
        \\part.volume
    ));
    try testing.expectEqual(InterpretResult.ok, try runScript(
        \\CAD.config(engine: :brep)
        \\part = cube(10).simplify
        \\part.volume
    ));
}

// --- Finding 2: evaluation errors must not free cache-owned handles ---

test "Regression ownership: evaluation error keeps cache-owned operands alive" {
    var vm = try initVm();
    defer vm.deinit(); // the cached cube used to be freed twice here

    const cube_idx = try vm.dag_builder.addCube(1, 1, 1, false);
    const sphere_idx = try vm.dag_builder.addSphere(5);
    const union_idx = try vm.dag_builder.addBinary(.union_op, cube_idx, sphere_idx);

    // Cache the cube, then make the sphere blow the vertex budget.
    const cube_h = try dag_evaluator.evaluateDAG(&vm, cube_idx);
    vm.config_stack.items[vm.config_stack.items.len - 1].max_vertices = 100;

    try testing.expectError(error.RamBudgetExceeded, dag_evaluator.evaluateDAG(&vm, union_idx));

    // The cached cube must still be the live, cache-owned handle.
    const again = try dag_evaluator.evaluateDAG(&vm, cube_idx);
    try testing.expectEqual(cube_h.ptr, again.ptr);
    try testing.expectApproxEqAbs(@as(f64, 1.0), kernel.volume(again), 1e-9);
}

// --- Finding 3: engine tags ---

test "Regression ownership: dag cache is keyed by engine" {
    var vm = try initVm();
    defer vm.deinit();

    const small = try vm.dag_builder.addCube(10, 10, 10, false);
    const big = try vm.dag_builder.addCube(20, 20, 20, false);
    const diff = try vm.dag_builder.addBinary(.difference_op, big, small);

    const m = try dag_evaluator.evaluateDAG(&vm, small);
    try testing.expectEqual(geom.EngineType.manifold, m.engine);

    vm.config_stack.items[vm.config_stack.items.len - 1].engine = .brep_native;

    // Before the fix this was a cache hit returning the Manifold handle.
    const b = try dag_evaluator.evaluateDAG(&vm, small);
    try testing.expectEqual(geom.EngineType.brep_native, b.engine);

    const d = try dag_evaluator.evaluateDAG(&vm, diff);
    try testing.expectEqual(geom.EngineType.brep_native, d.engine);
}

test "Regression ownership: GC keeps the B-Rep cache entry of live geometry" {
    var vm = try initVm();
    defer vm.deinit();

    // `a` stays rooted as a global, so its cached handle must survive GC.
    try testing.expectEqual(InterpretResult.ok, try runOn(&vm,
        \\CAD.config(engine: :brep)
        \\a = cube(10)
        \\a.volume
    ));
    const cached = vm.dag_cache.count();
    try testing.expect(cached > 0);

    // Eviction must strip the engine salt from the key before the liveness
    // check, or every B-Rep entry looks dead and is freed.
    vm.resetStack();
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(cached, vm.dag_cache.count());
}

test "Regression ownership: mixed-engine operands are rejected at runtime" {
    const m = kernel.cube(.manifold, 10, 10, 10, false) orelse return error.KernelFailed;
    defer kernel.destruct(m);
    const b = kernel.cube(.brep_native, 20, 20, 20, false) orelse return error.KernelFailed;
    defer kernel.destruct(b);

    try testing.expect(kernel.boolean(b, m, .difference_op) == null);
    try testing.expect(kernel.boolean(m, b, .union_op) == null);
    try testing.expect(kernel.minkowski(m, b) == null);
    try testing.expect(kernel.batchBoolean(testing.allocator, &.{ m, b }, .union_op) == null);
    try testing.expect(kernel.batchHull(testing.allocator, &.{ b, m }) == null);
    try testing.expectEqual(@as(f64, 0.0), kernel.minGap(m, b, 1.0));
}

test "Regression ownership: evaluator rejects a DAG mixing engines" {
    // A decompose result is a `.concrete` leaf that keeps its Manifold handle
    // after the engine switches, so the union below has mixed operands.
    try testing.expectEqual(InterpretResult.runtime_error, try runScript(
        \\part = cube(10).decompose[0]
        \\CAD.config(engine: :brep)
        \\(part + cube(1)).volume
    ));
}

// --- Finding 4: CSE dedup ---

test "Regression ownership: even-odd polygons with different contour splits are distinct" {
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

test "Regression ownership: polyhedron hash separates points and faces" {
    var b1 = dag.DAGBuilder.init(testing.allocator);
    defer b1.deinit();
    var b2 = dag.DAGBuilder.init(testing.allocator);
    defer b2.deinit();

    // The last point of `pts1` has the exact bytes of the first two faces of
    // `faces2`, so both pts++faces byte streams are identical.
    const shifted = [2][3]u32{ .{ 0, 1, 2 }, .{ 3, 4, 5 } };
    const as_point: [3]f64 = @bitCast(shifted);
    const pts1 = [_][3]f64{ .{ 0, 0, 0 }, as_point };
    const faces1 = [_][3]u32{.{ 6, 7, 8 }};
    const pts2 = [_][3]f64{.{ 0, 0, 0 }};
    const faces2 = [_][3]u32{ shifted[0], shifted[1], .{ 6, 7, 8 } };

    // Separate builders, so a structural-equality fallback cannot hide a collision.
    const p1 = try b1.addPolyhedron(&pts1, &faces1);
    const p2 = try b2.addPolyhedron(&pts2, &faces2);
    try testing.expect(b1.node_hashes.items[p1] != b2.node_hashes.items[p2]);
}

test "Regression ownership: a raw hash collision does not merge different nodes" {
    // Learn the hash cube(2) will get, using a scratch builder (hashing is content-based).
    var scratch = dag.DAGBuilder.init(testing.allocator);
    defer scratch.deinit();
    const c2_scratch = try scratch.addCube(2, 2, 2, false);
    const c2_hash = scratch.node_hashes.items[c2_scratch];

    var builder = dag.DAGBuilder.init(testing.allocator);
    defer builder.deinit();
    const c1 = try builder.addCube(1, 1, 1, false);

    // Simulate a 64-bit collision: cube(2)'s hash already maps to cube(1).
    try builder.dedup_map.put(builder.arena.allocator(), c2_hash, c1);

    const c2 = try builder.addCube(2, 2, 2, false);
    try testing.expect(c2 != c1);
    try testing.expect(builder.node_hashes.items[c2] != builder.node_hashes.items[c1]);
    try testing.expect(builder.node_hashes.items[c2] != c2_hash);

    // Identical nodes still deduplicate (via the probed hash).
    try testing.expectEqual(c2, try builder.addCube(2, 2, 2, false));
}

// --- Finding 5: borrowed handles in session / display list ---

test "Regression ownership: session stores its own copy of the module output" {
    var session = try ScriptSession.init(testing.allocator, testing.io);
    defer session.deinit(); // the cache-owned handle used to be freed twice here

    const file_path = "model.kup";
    const mod_id = try session.workspace.addModule(file_path, "c = cube(10.0)");
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();
    try session.evaluateModule(mod_id);

    const node = &session.nodes.items[@backingInt(mod_id)];
    const first = node.cached_handle orelse return error.NoHandle;

    // The session copy must survive the DAG cache dropping its entry (what GC
    // eviction does once no ObjGeometry references the node).
    var it = session.vm.dag_cache.valueIterator();
    while (it.next()) |h| kernel.destruct(h.*);
    session.vm.dag_cache.clearRetainingCapacity();
    try testing.expectApproxEqAbs(@as(f64, 1000.0), kernel.volume(first), 1e-6);

    // Changing the output destroys the old copy (not the cache's handle).
    var mod = &session.workspace.modules.items[@backingInt(mod_id)];
    testing.allocator.free(mod.source);
    mod.source = try testing.allocator.dupe(u8, "c = cube(20.0)");
    try session.markFileEdited(file_path);
    try session.evaluateModule(mod_id);

    const second = session.nodes.items[@backingInt(mod_id)].cached_handle orelse return error.NoHandle;
    try testing.expectApproxEqAbs(@as(f64, 8000.0), kernel.volume(second), 1e-6);
}

test "Regression ownership: ghost display list survives garbage collection" {
    var vm = try initVm();
    defer vm.deinit();

    try testing.expectEqual(InterpretResult.ok, try runOn(&vm, "cube(10).ghost\nnil"));
    try testing.expectEqual(@as(usize, 1), vm.display_list.items.len);

    // Nothing roots the ghost geometry; a GC evicts its dag_cache entry.
    vm.resetStack();
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(u32, 0), vm.dag_cache.count());

    try testing.expectApproxEqAbs(@as(f64, 1000.0), kernel.volume(vm.display_list.items[0]), 1e-6);
}

// --- Finding 6: leaks / unsafe cleanup on partial failure ---

test "Regression ownership: polygonsEvenOdd survives partial allocation failure" {
    const tri = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } };
    const contours = [_][]const [2]f64{ &tri, &tri, &tri };

    // Fail each allocation in turn; freeing uninitialized slots used to crash.
    var fail_index: usize = 0;
    while (fail_index < 4) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        if (kernel.polygonsEvenOdd(.manifold, failing.allocator(), &contours)) |cs| kernel.destructCrossSection(cs);
    }
}

// --- Concrete (decompose/simplify) results used in later DAG ops ---

fn evalVolume(vm: *VM, source: []const u8) !f64 {
    try testing.expectEqual(InterpretResult.ok, try runOn(vm, source));
    const result = vm.globals.get("result") orelse return error.NoResult;
    return result.asNumber();
}

test "Regression ownership: decompose/simplify results feed later DAG ops" {
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

test "Regression ownership: DAG builder rejects the concrete sentinel as a child" {
    var builder = dag.DAGBuilder.init(testing.allocator);
    defer builder.deinit();
    const c = try builder.addCube(1, 1, 1, false);
    try testing.expectError(error.InvalidDAGNode, builder.addTranslate(dag.CONCRETE_NODE_SENTINEL, 1, 0, 0));
    try testing.expectError(error.InvalidDAGNode, builder.addBinary(.union_op, c, dag.CONCRETE_NODE_SENTINEL));
    try testing.expectError(error.InvalidDAGNode, builder.addBatchUnion(&.{ c, dag.CONCRETE_NODE_SENTINEL }));
    // Rollback leaves the builder usable.
    try testing.expectEqual(@as(usize, 1), builder.nodes.items.len);
}
