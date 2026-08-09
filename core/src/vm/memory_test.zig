const std = @import("std");
const testing = std.testing;
const value = @import("../core/value.zig");
const VM = @import("vm.zig").VM;
const GC = @import("memory.zig").GC;

// Helper to count objects in the intrusive linked list
fn countObjects(gc: *GC) usize {
    var count: usize = 0;
    var current = gc.first_object;
    while (current) |obj| {
        count += 1;
        current = obj.next;
    }
    return count;
}

test "GC: Mark and Sweep reclaims unreferenced objects" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    // Note: VM.init() registers the "cube" native function (1 object)

    // 1. Allocate a string but DO NOT push it to the stack
    _ = try vm.allocateString("I am dead");

    // 2. Allocate a string and DO push it to the stack (keeping it alive)
    const alive_val = try vm.allocateString("I am alive");
    try vm.push(alive_val);

    // Verify both strings + global "cube" native are in the linked list (3 total)
    try testing.expectEqual(@as(usize, 3), countObjects(&vm.gc));

    // 3. Run the Garbage Collector
    vm.gc.collectGarbage(&vm, false);

    // 4. Verify the orphaned string was destroyed, but stacked & global survived (2 total)
    try testing.expectEqual(@as(usize, 2), countObjects(&vm.gc));
}

test "GC: ObjMesh allocation and lifecycle tracking" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Simulate a mock pointer from a C/C++ CAD Kernel
    const dummy_handle: ?*anyopaque = @ptrFromInt(0xDEADBEEF);

    // Allocate the mesh and keep it alive by pushing it to the stack
    const mesh_val = try vm.allocateMesh(dummy_handle, 8, 12);
    try vm.push(mesh_val);

    // Verify it was registered in the GC linked list (1 mesh + 1 global = 2 total)
    try testing.expectEqual(@as(usize, 2), countObjects(&vm.gc));

    // Verify properties
    try testing.expect(mesh_val.isMesh());
    const mesh = mesh_val.asMesh();
    try testing.expectEqual(@as(usize, 8), mesh.vertex_count);
    try testing.expectEqual(@as(usize, 12), mesh.face_count);
    try testing.expectEqual(dummy_handle, mesh.kernel_handle);

    // Run GC. The mesh should survive because it's on the stack.
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(usize, 2), countObjects(&vm.gc));

    // Pop the mesh off the stack, making it unreachable
    _ = vm.pop();

    // Run GC again. The orphaned mesh should be swept. Only "cube" global survives.
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(usize, 1), countObjects(&vm.gc));
}
