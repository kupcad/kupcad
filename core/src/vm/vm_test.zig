const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const VM = @import("vm.zig").VM;

test "VM: End-to-end compilation and execution of math expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const ten = try b.number("10", 0);
    const five = try b.number("5", 0);
    const add_node = try b.binary(.add, ten, five, 0);

    const two = try b.number("2", 0);
    const neg_two = try b.unary(.negate, two, 0);

    const root_math = try b.binary(.multiply, add_node, neg_two, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &out_chunk, &vm);
    try comp.compile(root_math);

    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 2), vm.stack_top);

    const final_value = vm.stack[0];
    try testing.expect(final_value.isNumber());
    try testing.expectEqual(@as(f64, -30.0), final_value.asNumber());

    const implicit_nil = vm.stack[1];
    try testing.expect(implicit_nil.isNil());
}

test "VM: Dynamic stack growth handles thousands of pushes without overflow" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    const push_count: usize = 5000;
    try vm.ensureStackCapacity(push_count);

    for (0..push_count) |i| {
        vm.push(value.Value.initNumber(@floatFromInt(i)));
    }

    try testing.expect(vm.stack.len >= push_count);
    try testing.expectEqual(push_count, vm.stack_top);

    var i: usize = push_count;
    while (i > 0) {
        i -= 1;
        const val = vm.pop();
        try testing.expectEqual(@as(f64, @floatFromInt(i)), val.asNumber());
    }

    try testing.expectEqual(@as(usize, 0), vm.stack_top);
}

test "VM: Execute native CAD function (cube)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const cube_name = try vm.allocateString("cube");
    vm.push(cube_name);
    const name_idx = try out_chunk.addConstant(testing.allocator, cube_name);
    _ = vm.pop();

    try out_chunk.writeOp(testing.allocator, .op_get_global, 1);
    try out_chunk.write(testing.allocator, name_idx, 1);
    try out_chunk.writeOp(testing.allocator, .op_call, 1);
    try out_chunk.write(testing.allocator, 0, 1);
    try out_chunk.writeOp(testing.allocator, .op_return, 1);

    out_chunk.max_stack_slots = 2; // Setup mock memory peak

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const returned_mesh = vm.stack[0];
    try testing.expect(returned_mesh.isMesh());

    const mesh = returned_mesh.asMesh();
    try testing.expectEqual(@as(usize, 8), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 12), mesh.faces.len);
}

test "VM: End-to-end compilation and execution of native CAD function (cube)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const cube_str = try b.intern("cube");
    const empty_args = try b.addNamedArgs(&.{});
    const cube_call = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &out_chunk, &vm);
    try comp.compile(cube_call);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 2), vm.stack_top);

    const returned_mesh = vm.stack[0];
    try testing.expect(returned_mesh.isMesh());

    const mesh = returned_mesh.asMesh();
    try testing.expectEqual(@as(usize, 8), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 12), mesh.faces.len);
}

test "VM: End-to-end compilation of fluent API method chaining (cube().translate())" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // Build AST for `cube()`
    const cube_str = try b.intern("cube");
    const empty_args = try b.addNamedArgs(&.{});
    const cube_call = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);

    // Wrap it in `.translate()` -> `cube().translate()`
    const translate_str = try b.intern("translate");
    const translate_call = try b.methodCall(cube_call, translate_str, empty_args, .none, false, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Compile the chained AST
    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &out_chunk, &vm);
    try comp.compile(translate_call);

    // Execute
    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // The top of the stack should hold the result of the `translate` invocation
    try testing.expectEqual(@as(usize, 2), vm.stack_top);

    const returned_mesh = vm.stack[0];
    try testing.expect(returned_mesh.isMesh());

    // Clean execution implicit nil check
    try testing.expect(vm.stack[1].isNil());
}

test "VM: Generates a real physical .stl file from a compiled script" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // Build AST for `cube()`
    const cube_str = try b.intern("cube");
    const empty_args = try b.addNamedArgs(&.{});
    const cube_call = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);

    // Build AST for `export_stl("test_cube.stl", cube())`
    const export_str = try b.intern("export_stl");

    // Create the string argument
    const filename_node = try b.stringNode("test_cube.stl", 0);

    // Assemble the two arguments
    var args_buf = [_]ast.NamedArg{
        .{ .name = .none, .value = filename_node, .modifier = null },
        .{ .name = .none, .value = cube_call, .modifier = null },
    };
    const export_args = try b.addNamedArgs(&args_buf);

    const export_call = try b.methodCall(.none, export_str, export_args, .none, false, 0, 0);

    // Setup VM & Compile
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    vm.cwd = tmp.dir;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &out_chunk, &vm);
    try comp.compile(export_call);

    // Run the VM!
    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Verify the file was written safely to the temp directory
    const file = try tmp.dir.openFile(testing.io, "test_cube.stl", .{});
    defer file.close(testing.io);

    const stat = try file.stat(testing.io);
    // 80 bytes (header) + 4 bytes (count) + 12 faces * 50 bytes = 684 bytes
    try testing.expectEqual(@as(u64, 684), stat.size);
}

test "VM: Executes CSG Operator Overloading (cube() + cube())" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const cube_str = try b.intern("cube");
    const empty_args = try b.addNamedArgs(&.{});

    // mesh1 = cube()
    const cube1 = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);
    // mesh2 = cube()
    const cube2 = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);

    // result = cube() + cube()
    const add_node = try b.binary(.add, cube1, cube2, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &out_chunk, &vm);
    try comp.compile(add_node);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Final result should be a single merged mesh left on the stack
    try testing.expectEqual(@as(usize, 2), vm.stack_top);
    try testing.expect(vm.stack[0].isMesh());

    try testing.expect(vm.stack[0].asMesh().kernel_handle != null);
}
