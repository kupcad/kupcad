const std = @import("std");
const testing = std.testing;
const VM = @import("vm.zig").VM;
const kernel = @import("../kernel/kernel.zig");
const dag_evaluator = @import("dag_evaluator.zig");
const registry = @import("../stdlib/registry.zig");

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
    try testing.expectEqual(@as(f64, 6000.0), vol);

    // Clean up the C++ memory (Normally handled by ARC, but we skipped ARC here)
    kernel.destruct(handle);
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
    try testing.expectEqual(@as(f64, 2000.0), vol);

    kernel.destruct(handle);
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
    defer kernel.destruct(handle);

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
    const c2 = try vm.dag_builder.addSphere(5.0);
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
