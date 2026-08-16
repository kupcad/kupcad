const std = @import("std");
const testing = std.testing;
const VM = @import("vm.zig").VM;
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
    const vol = vm.active_kernel.?.volume(handle);
    try testing.expectEqual(@as(f64, 6000.0), vol);

    // Clean up the C++ memory (Normally handled by ARC, but we skipped ARC here)
    vm.active_kernel.?.destruct(handle);
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
    const vol = vm.active_kernel.?.volume(handle);
    try testing.expectEqual(@as(f64, 2000.0), vol);

    vm.active_kernel.?.destruct(handle);
}
