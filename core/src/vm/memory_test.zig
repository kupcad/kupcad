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

    // 1. Allocate a string but DO NOT push it to the stack
    // Pass string literals directly. The GC handles allocating its own heap memory.
    _ = try vm.allocateString("I am dead");

    // 2. Allocate a string and DO push it to the stack (keeping it alive)
    const alive_val = try vm.allocateString("I am alive");
    try vm.push(alive_val);

    // Verify both objects are in the linked list
    try testing.expectEqual(@as(usize, 2), countObjects(&vm.gc));

    // 3. Run the Garbage Collector
    vm.gc.collectGarbage(&vm, false);

    // 4. Verify the orphaned string was destroyed, but the stacked one survived
    try testing.expectEqual(@as(usize, 1), countObjects(&vm.gc));

    const surviving_obj = vm.gc.first_object.?;
    try testing.expectEqual(value.ObjType.string, surviving_obj.obj_type);
}

test "GC: ObjMesh allocation and lifecycle tracking" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Simulate a mock pointer from a C/C++ CAD Kernel
    const dummy_handle: ?*anyopaque = @ptrFromInt(0xDEADBEEF);

    // Allocate the mesh and keep it alive by pushing it to the stack
    const mesh_val = try vm.allocateMesh(dummy_handle, 8, 12);
    try vm.push(mesh_val);

    // Verify it was registered in the GC linked list
    try testing.expectEqual(@as(usize, 1), countObjects(&vm.gc));

    // Verify properties
    try testing.expect(mesh_val.isMesh());
    const mesh = mesh_val.asMesh();
    try testing.expectEqual(@as(usize, 8), mesh.vertex_count);
    try testing.expectEqual(@as(usize, 12), mesh.face_count);
    try testing.expectEqual(dummy_handle, mesh.kernel_handle);

    // Run GC. The mesh should survive because it's on the stack.
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(usize, 1), countObjects(&vm.gc));

    // Pop the mesh off the stack, making it unreachable
    _ = vm.pop();

    // Run GC again. The orphaned mesh should be swept and destroyed.
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(usize, 0), countObjects(&vm.gc));
}
