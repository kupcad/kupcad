const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("chunk.zig");
const value = @import("../core/value.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const VM = @import("vm.zig").VM;

test "VM: End-to-end compilation and execution of math expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // Build AST for: `(10 + 5) * -2`
    const ten = try b.number("10", 0);
    const five = try b.number("5", 0);
    const add_node = try b.binary(.add, ten, five, 0);

    const two = try b.number("2", 0);
    const neg_two = try b.unary(.negate, two, 0);

    const root_math = try b.binary(.multiply, add_node, neg_two, 0);

    // Initialize the VM FIRST so the Compiler can use it
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Compile to Bytecode
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Pass &vm as the 5th argument
    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &out_chunk, &vm);
    try comp.compile(root_math);

    // Execute in the VM
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);

    // Validate the Stack Result
    // The top of the stack should hold our final answer: (10 + 5) * -2 = -30
    // The stack contains our math result, followed by the compiler's implicit end-of-script `nil`
    try testing.expectEqual(@as(usize, 2), vm.stack_top);

    const final_value = vm.stack[0];
    try testing.expect(final_value.isNumber());
    try testing.expectEqual(@as(f64, -30.0), final_value.asNumber());

    const implicit_nil = vm.stack[1];
    try testing.expect(implicit_nil.isNil());
}

test "VM: Dynamic stack growth handles thousands of pushes without overflow" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Push 5,000 items (exceeding initial 1,024 capacity multiple times)
    const push_count: usize = 5000;
    for (0..push_count) |i| {
        try vm.push(value.Value.initNumber(@floatFromInt(i)));
    }

    // Verify stack grew dynamically
    try testing.expect(vm.stack.len >= push_count);
    try testing.expectEqual(push_count, vm.stack_top);

    // Verify LIFO order and data integrity after memory reallocations
    var i: usize = push_count;
    while (i > 0) {
        i -= 1;
        const val = vm.pop();
        try testing.expectEqual(@as(f64, @floatFromInt(i)), val.asNumber());
    }

    try testing.expectEqual(@as(usize, 0), vm.stack_top);
}

test "VM: Execute native CAD function (cube)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Setup global lookup constant for "cube"
    const cube_name = try vm.allocateString("cube");
    try vm.push(cube_name); // Protect from GC while building chunk
    const name_idx = try out_chunk.addConstant(testing.allocator, cube_name);
    _ = vm.pop();

    // Build bytecode to call `cube()`
    // GET_GLOBAL "cube"
    try out_chunk.writeOp(testing.allocator, .op_get_global, 1);
    try out_chunk.write(testing.allocator, name_idx, 1);

    // CALL 0 (0 arguments)
    try out_chunk.writeOp(testing.allocator, .op_call, 1);
    try out_chunk.write(testing.allocator, 0, 1);

    // RETURN
    try out_chunk.writeOp(testing.allocator, .op_return, 1);

    // Execute
    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Verify stack state
    // Top of stack should be our new ObjMesh.
    // (There is no implicit nil because we built the chunk manually)
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const returned_mesh = vm.stack[0];
    try testing.expect(returned_mesh.isMesh());

    const mesh = returned_mesh.asMesh();
    try testing.expectEqual(@as(usize, 8), mesh.vertex_count);
    try testing.expectEqual(@as(usize, 12), mesh.face_count);
}

test "VM: End-to-end compilation and execution of native CAD function (cube)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // Build AST for: `cube()`
    const cube_str = try b.intern("cube");
    const empty_args = try b.addNamedArgs(&.{});
    const cube_call = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);

    // Initialize the VM FIRST so the Compiler can use it
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Compile to Bytecode
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &out_chunk, &vm);
    try comp.compile(cube_call);

    // Execute in the VM
    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Validate the Stack Result
    // The stack contains our mesh result, followed by the compiler's implicit end-of-script `nil`
    try testing.expectEqual(@as(usize, 2), vm.stack_top);

    const returned_mesh = vm.stack[0];
    try testing.expect(returned_mesh.isMesh());

    const mesh = returned_mesh.asMesh();
    try testing.expectEqual(@as(usize, 8), mesh.vertex_count);
    try testing.expectEqual(@as(usize, 12), mesh.face_count);

    const implicit_nil = vm.stack[1];
    try testing.expect(implicit_nil.isNil());
}
