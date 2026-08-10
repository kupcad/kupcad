const std = @import("std");
const testing = std.testing;
const VM = @import("vm.zig").VM;
const Host = @import("host.zig").Host;
const GeometryHandle = @import("../kernel/geometry_handle.zig").GeometryHandle;
const value = @import("../core/value.zig");
const chunk = @import("chunk.zig");

// --- Mock Callback Trackers ---
var mock_destructor_called: bool = false;
var mock_last_destroyed_handle: ?GeometryHandle = null;
var mock_binary_called: bool = false;

fn mockMeshDestructor(handle: GeometryHandle) void {
    mock_destructor_called = true;
    mock_last_destroyed_handle = handle;
}

fn mockBinaryHandler(vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value {
    _ = a;
    _ = b;
    _ = op;
    mock_binary_called = true;
    return try vm.allocateString("mock_csg_result");
}

test "Host Interface: GC correctly passes GeometryHandle value to host.mesh_destructor" {
    mock_destructor_called = false;
    mock_last_destroyed_handle = null;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    vm.host.mesh_destructor = mockMeshDestructor;

    const test_ptr = @as(*anyopaque, @ptrFromInt(0xDEADBEEF));
    const handle = GeometryHandle{ .engine = .manifold, .ptr = test_ptr };

    // Allocate mesh on VM heap
    const mesh_val = try vm.allocateMesh(handle, &[_]value.Vec3{}, &[_][3]u32{});

    // Push and pop to make it unreachable by GC
    vm.push(mesh_val);
    _ = vm.pop();

    // Trigger sweep
    vm.gc.collectGarbage(&vm, false);

    // Verify callback received the exact value-copied GeometryHandle
    try testing.expect(mock_destructor_called);
    try testing.expectEqual(.manifold, mock_last_destroyed_handle.?.engine);
    try testing.expectEqual(test_ptr, mock_last_destroyed_handle.?.ptr);
}

test "Host Interface: binary_handler intercepts custom operator overloading" {
    mock_binary_called = false;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    vm.host.binary_handler = mockBinaryHandler;

    // Create execution chunk: push two meshes, perform '+'
    var test_chunk = chunk.Chunk.init();
    defer test_chunk.free(testing.allocator);

    const dummy_mesh1 = try vm.allocateMesh(null, &[_]value.Vec3{}, &[_][3]u32{});
    const dummy_mesh2 = try vm.allocateMesh(null, &[_]value.Vec3{}, &[_][3]u32{});

    const idx1 = try test_chunk.addConstant(testing.allocator, dummy_mesh1);
    const idx2 = try test_chunk.addConstant(testing.allocator, dummy_mesh2);

    try test_chunk.writeOp(testing.allocator, .op_constant, 1);
    try test_chunk.write(testing.allocator, idx1, 1);
    try test_chunk.writeOp(testing.allocator, .op_constant, 1);
    try test_chunk.write(testing.allocator, idx2, 1);
    try test_chunk.writeOp(testing.allocator, .op_add, 1);
    try test_chunk.writeOp(testing.allocator, .op_return, 1);
    test_chunk.max_stack_slots = 4;

    const result = vm.interpret(&test_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expect(mock_binary_called);
    try testing.expect(vm.stack[0].isString());
}
