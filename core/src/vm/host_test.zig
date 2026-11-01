const std = @import("std");
const testing = std.testing;
const VM = @import("vm.zig").VM;
const GeometryHandle = @import("../core/geometry_handle.zig").GeometryHandle;
const value = @import("../core/value.zig");
const chunk = @import("chunk.zig");

/// A VM and whether its binary handler was called, kept beside it: the handler is given the
/// VM alone, and finds the flag by it (@fieldParentPtr), so none outlives its test.
const Handled = struct {
    vm: VM,
    called: bool = false,
};

fn mockBinaryHandler(vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value {
    _ = a;
    _ = b;
    _ = op;
    const handled: *Handled = @fieldParentPtr("vm", vm);
    handled.called = true;
    return try vm.allocateString("mock_csg_result");
}

test "Host Interface: binary_handler intercepts custom operator overloading" {
    var handled: Handled = .{ .vm = try VM.init(testing.allocator, testing.io) };
    const vm = &handled.vm;
    defer vm.deinit();
    vm.host.binary_handler = mockBinaryHandler;

    // Create execution chunk: push two meshes, perform '+'
    var test_chunk = chunk.Chunk.init();
    defer test_chunk.free(testing.allocator);

    const dag1 = try vm.dag_builder.addCube(1.0, 1.0, 1.0, true);
    const dag2 = try vm.dag_builder.addCube(1.0, 1.0, 1.0, true);

    const dummy_mesh1 = try vm.allocateGeometry(.{ .symbolic = dag1 });
    const dummy_mesh2 = try vm.allocateGeometry(.{ .symbolic = dag2 });

    const idx1 = try test_chunk.addConstant(testing.allocator, dummy_mesh1);
    const idx2 = try test_chunk.addConstant(testing.allocator, dummy_mesh2);

    try test_chunk.writeOp(testing.allocator, .op_constant, 0);
    try test_chunk.write(testing.allocator, @intCast(idx1), 0);
    try test_chunk.writeOp(testing.allocator, .op_constant, 0);
    try test_chunk.write(testing.allocator, @intCast(idx2), 0);
    try test_chunk.writeOp(testing.allocator, .op_add, 0);
    try test_chunk.writeOp(testing.allocator, .op_return, 0);

    test_chunk.max_stack_slots = 4;

    const result = vm.interpret(&test_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expect(handled.called);
    try testing.expect(vm.stack[0].isString());
}
