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
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    _ = try vm.allocateString("I am dead");

    const alive_val = try vm.allocateString("I am alive");
    vm.push(alive_val); // Drop `try`

    try testing.expectEqual(@as(usize, 4), countObjects(&vm.gc));
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(usize, 3), countObjects(&vm.gc));
}

test "GC: ObjMesh allocation and lifecycle tracking" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const dummy_handle: ?*anyopaque = null;
    const mock_vertices = [_]value.Vec3{};
    const mock_faces = [_][3]u32{};
    const mesh_val = try vm.allocateMesh(dummy_handle, &mock_vertices, &mock_faces);

    vm.push(mesh_val);

    try testing.expectEqual(@as(usize, 3), countObjects(&vm.gc));
    try testing.expect(mesh_val.isMesh());

    const mesh = mesh_val.asMesh();
    try testing.expectEqual(@as(usize, 0), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 0), mesh.faces.len);
    try testing.expectEqual(dummy_handle, mesh.kernel_handle);

    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(usize, 3), countObjects(&vm.gc));

    _ = vm.pop();

    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(usize, 2), countObjects(&vm.gc));
}
