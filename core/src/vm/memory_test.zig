const std = @import("std");
const testing = std.testing;
const value = @import("../core/value.zig");
const VM = @import("vm.zig").VM;
const GC = @import("memory.zig").GC;

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

    _ = try vm.allocateString("I am dead");

    const alive_val = try vm.allocateString("I am alive");
    vm.push(alive_val); // Drop `try`

    try testing.expectEqual(@as(usize, 3), countObjects(&vm.gc));
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(usize, 2), countObjects(&vm.gc));
}

test "GC: ObjMesh allocation and lifecycle tracking" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const dummy_handle: ?*anyopaque = @ptrFromInt(0xDEADBEEF);
    const mesh_val = try vm.allocateMesh(dummy_handle, 8, 12);

    vm.push(mesh_val); // Drop `try`

    try testing.expectEqual(@as(usize, 2), countObjects(&vm.gc));
    try testing.expect(mesh_val.isMesh());

    const mesh = mesh_val.asMesh();
    try testing.expectEqual(@as(usize, 8), mesh.vertex_count);
    try testing.expectEqual(@as(usize, 12), mesh.face_count);
    try testing.expectEqual(dummy_handle, mesh.kernel_handle);

    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(usize, 2), countObjects(&vm.gc));

    _ = vm.pop();

    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(usize, 1), countObjects(&vm.gc));
}
