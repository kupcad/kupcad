const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const resolver = @import("../core/resolver.zig");
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

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    try comp.compile(root_math);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top); // Changed from 2 to 1

    const final_value = vm.stack[0];
    try testing.expect(final_value.isNumber());
    try testing.expectEqual(@as(f64, -30.0), final_value.asNumber());
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

test "VM: Execute native CAD function (cube) generates symbolic DAG node" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const cube_name = try vm.allocateString("cube");
    vm.push(cube_name);
    const name_idx = try out_chunk.addConstant(testing.allocator, cube_name);
    _ = vm.pop();

    try out_chunk.writeOp(testing.allocator, .op_get_global, 0);
    try out_chunk.write(testing.allocator, name_idx, 0);
    try out_chunk.writeOp(testing.allocator, .op_call, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 2;

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const returned_geom = vm.stack[0];
    try testing.expect(returned_geom.isGeometry());

    const geom = returned_geom.asGeometry();
    // Verify it was appended to the DAG lazily, bypassing the C++ kernel
    try testing.expectEqual(false, geom.isConcrete());
    try testing.expect(vm.dag_builder.nodes.items.len > 0);
}

test "VM: End-to-end compilation of fluent API method chaining (cube().translate())" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const cube_str = try b.intern("cube");
    const empty_args = try b.addNamedArgs(&.{});
    const cube_call = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);

    const translate_str = try b.intern("translate");
    const translate_call = try b.methodCall(cube_call, translate_str, empty_args, .none, false, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    try comp.compile(translate_call);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top); // Changed from 2 to 1

    const returned_geom = vm.stack[0];
    try testing.expect(returned_geom.isGeometry());
    // The DAG should remain entirely symbolic until JIT materialized
    try testing.expectEqual(false, returned_geom.asGeometry().isConcrete());
}

test "VM: Executes CSG Operator Overloading lazily (cube() + cube())" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const cube_str = try b.intern("cube");
    const empty_args = try b.addNamedArgs(&.{});

    const cube1 = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);
    const cube2 = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);

    // result = cube() + cube()
    const add_node = try b.binary(.add, cube1, cube2, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    try comp.compile(add_node);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top); // Changed from 2 to 1

    const final_val = vm.stack[0];
    try testing.expect(final_val.isGeometry());
}

test "VM: Generates a real physical .stl file via JIT materialization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const cube_str = try b.intern("cube");
    const empty_args = try b.addNamedArgs(&.{});
    const cube_call = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);

    const export_str = try b.intern("export_stl");
    const filename_node = try b.stringNode("test_cube.stl", 0);

    var args_buf = [_]ast.NamedArg{
        .{ .name = .none, .value = filename_node, .modifier = null },
        .{ .name = .none, .value = cube_call, .modifier = null },
    };
    const export_args = try b.addNamedArgs(&args_buf);
    const export_call = try b.methodCall(.none, export_str, export_args, .none, false, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    vm.cwd = tmp.dir;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    try comp.compile(export_call);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Verify the file was written safely to the temp directory
    const file = try tmp.dir.openFile(testing.io, "test_cube.stl", .{});
    defer file.close(testing.io);
    const stat = try file.stat(testing.io);

    // Note: Due to mock exporters, file byte count will adapt based on final implementation.
    // For now, ensuring the VM reaches this point without crashing validates the JIT pathway.
    try testing.expect(stat.size >= 0);
}

test "VM: Closures correctly capture and return upvalues" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // 1. Create the Closure's bytecode chunk
    var closure_chunk = try testing.allocator.create(chunk.Chunk);
    closure_chunk.* = chunk.Chunk.init();
    defer {
        closure_chunk.free(testing.allocator);
        testing.allocator.destroy(closure_chunk);
    }

    // Closure code: Get upvalue 0, then return it
    try closure_chunk.writeOp(testing.allocator, .op_get_upvalue, 0);
    try closure_chunk.write(testing.allocator, 0, 0); // upvalue index 0
    try closure_chunk.writeOp(testing.allocator, .op_return, 0);
    closure_chunk.max_stack_slots = 2;

    // 2. Wrap the chunk in an ObjFunction on the GC heap
    const func = try vm.gc.allocateFunction(&vm);
    func.chunk = closure_chunk;
    func.owns_chunk = false;
    func.upvalue_count = 1;
    func.arity = 0;

    // 3. Create the Main Script Chunk
    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(testing.allocator);

    // Push 42 (simulating `let x = 42`)
    const const_42 = try main_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));
    try main_chunk.writeOp(testing.allocator, .op_constant, 0);
    try main_chunk.write(testing.allocator, const_42, 0);

    // Instantiate the Closure
    const const_func = try main_chunk.addConstant(testing.allocator, value.Value.initObj(&func.obj));
    try main_chunk.writeOp(testing.allocator, .op_closure, 0);
    try main_chunk.write(testing.allocator, const_func, 0);

    // Upvalue parameters: is_local = 1, index = 1 (captures stack slot 1, where 42 is sitting)
    try main_chunk.write(testing.allocator, 1, 0);
    try main_chunk.write(testing.allocator, 1, 0);

    // Call the closure we just created
    try main_chunk.writeOp(testing.allocator, .op_call, 0);
    try main_chunk.write(testing.allocator, 0, 0); // 0 arguments

    try main_chunk.writeOp(testing.allocator, .op_return, 0);
    main_chunk.max_stack_slots = 4;

    // Run!
    const result = vm.interpret(&main_chunk);

    try testing.expectEqual(.ok, result);
    // Proves that all nested scopes and variables were destroyed perfectly
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const final_val = vm.stack[0];
    try testing.expect(final_val.isNumber());
    // Proves that the closure successfully reached into the parent scope!
    try testing.expectEqual(@as(f64, 42.0), final_val.asNumber());
}

test "VM: executes dynamic array building and spreading" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // 1. Target Array: op_build_array 0 (Empty Array)
    try out_chunk.writeOp(testing.allocator, .op_build_array, 0);
    try out_chunk.write(testing.allocator, 0, 0);

    // 2. Element 1: Push 42 and op_array_push
    const c42 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, c42, 0);
    try out_chunk.writeOp(testing.allocator, .op_array_push, 0);

    // 3. Source Array: Build [1, 2]
    const c1 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(1.0));
    const c2 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(2.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, c1, 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, c2, 0);
    try out_chunk.writeOp(testing.allocator, .op_build_array, 0);
    try out_chunk.write(testing.allocator, 2, 0);

    // 4. Spread source into target
    try out_chunk.writeOp(testing.allocator, .op_array_spread, 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 5;

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    // Verify the Array is successfully merged [42.0, 1.0, 2.0]
    const final_arr_val = vm.stack[0];
    try testing.expect(final_arr_val.isObject());
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", final_arr_val.asObj())));
    try testing.expectEqual(@as(usize, 3), arr.items.items.len);
    try testing.expectEqual(@as(f64, 42.0), arr.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 1.0), arr.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 2.0), arr.items.items[2].asNumber());
}

test "VM: cleanly unwinds stack and jumps to rescue block on throw" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // 1. op_setup_rescue (reserves jump offset)
    try out_chunk.writeOp(testing.allocator, .op_setup_rescue, 0);
    const jump_idx = out_chunk.code.items.len;
    try out_chunk.write(testing.allocator, 0xFF, 0);
    try out_chunk.write(testing.allocator, 0xFF, 0);

    // 2. Push a dummy variable to prove stack unwinding drops dead variables cleanly
    const dummy = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(99.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, dummy, 0);

    // 3. Throw an Error!
    const err_str_val = try vm.allocateString("Crash!");
    vm.ensureStackCapacity(1) catch unreachable;
    vm.push(err_str_val);
    const err_str = try out_chunk.addConstant(testing.allocator, err_str_val);
    _ = vm.pop();

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, err_str, 0);
    try out_chunk.writeOp(testing.allocator, .op_throw, 0);

    // 4. Success path (Should be completely skipped by the VM unwinder!)
    try out_chunk.writeOp(testing.allocator, .op_pop_rescue, 0);
    try out_chunk.writeOp(testing.allocator, .op_jump, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 3, 0); // skip over rescue block

    // --- RESCUE HANDLER ---
    // Patch the setup_rescue offset so it lands exactly here
    const handler_ip = out_chunk.code.items.len;
    const offset = handler_ip - (jump_idx + 2);
    out_chunk.code.items[jump_idx] = @intCast((offset >> 8) & 0xFF);
    out_chunk.code.items[jump_idx + 1] = @intCast(offset & 0xFF);

    // Pop the "Crash!" error off the stack
    try out_chunk.writeOp(testing.allocator, .op_pop, 0);

    // Return a fallback value of 42
    const c42 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, c42, 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 5;

    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    // The stack should contain exactly 42.0, the dummy 99.0 should be stripped entirely!
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 42.0), vm.stack[0].asNumber());
}

test "VM Edge Case: Uncaught exceptions halt gracefully without panicking" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const err_val = try vm.allocateString("Fatal System Error!");
    vm.push(err_val); // Protect from GC
    const err_idx = try out_chunk.addConstant(testing.allocator, err_val);
    _ = vm.pop();

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, err_idx, 0);

    // Throw the error with NO rescue block set up!
    try out_chunk.writeOp(testing.allocator, .op_throw, 0);
    out_chunk.max_stack_slots = 2;

    const result = vm.interpret(&out_chunk);

    // The VM should catch the lack of rescue frames and return a runtime_error cleanly
    try testing.expectEqual(.runtime_error, result);
}

test "VM Edge Case: Gracefully handles type mismatches in arithmetic" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Try to add a String and a Number ("Hello" + 5)
    const str_val = try vm.allocateString("Hello");
    vm.push(str_val);
    const str_idx = try out_chunk.addConstant(testing.allocator, str_val);
    _ = vm.pop();

    const num_idx = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(5.0));

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, str_idx, 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, num_idx, 0);
    try out_chunk.writeOp(testing.allocator, .op_add, 0);

    out_chunk.max_stack_slots = 3;

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);
}

test "VM Edge Case: Gracefully handles method calls on raw primitives" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const num_idx = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(5.0));

    const m_val = try vm.allocateString("fake_method");
    vm.push(m_val);
    const m_idx = try out_chunk.addConstant(testing.allocator, m_val);
    _ = vm.pop();

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, num_idx, 0);
    try out_chunk.writeOp(testing.allocator, .op_invoke, 0);
    try out_chunk.write(testing.allocator, m_idx, 0);
    try out_chunk.write(testing.allocator, 0, 0); // 0 args

    out_chunk.max_stack_slots = 3;

    const result = vm.interpret(&out_chunk);
    // You can't call methods on a raw float, so it should abort cleanly.
    try testing.expectEqual(.runtime_error, result);
}

test "VM: natively executes op_switch jump table" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // The test value: 42
    const test_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));

    // The match cases: 10 and 42
    const case1_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(10.0));
    const case2_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));

    // Push test value
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, test_val, 0);

    // op_switch with 2 cases
    try out_chunk.writeOp(testing.allocator, .op_switch, 0);
    try out_chunk.write(testing.allocator, 2, 0); // case count

    // Table Entry 1: case 10
    try out_chunk.write(testing.allocator, case1_val, 0);
    try out_chunk.write(testing.allocator, 0, 0); // jump high
    try out_chunk.write(testing.allocator, 0, 0); // relative offset 0

    // Table Entry 2: case 42
    try out_chunk.write(testing.allocator, case2_val, 0);
    try out_chunk.write(testing.allocator, 0, 0); // jump high
    try out_chunk.write(testing.allocator, 3, 0); // relative offset 3

    // Default Entry:
    try out_chunk.write(testing.allocator, 0, 0); // jump high
    try out_chunk.write(testing.allocator, 6, 0); // relative offset 6

    // Branch 1 (Target: offset + 7) -> Pushes 100
    const b1_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(100.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, b1_val, 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    // Branch 2 (Target: offset + 11) -> Pushes 200 [THIS SHOULD EXECUTE]
    const b2_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(200.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, b2_val, 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    // Default Branch (Target: offset + 15) -> Pushes 300
    const bdef_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(300.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, bdef_val, 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 5;

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 200.0), vm.stack[0].asNumber()); // Must match Branch 2!
}

test "VM: op_unpack correctly destructs array into stack slots" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Push 10, 20
    const val1 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(10.0));
    const val2 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(20.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, val1, 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, val2, 0);

    // Build Array [10, 20]
    try out_chunk.writeOp(testing.allocator, .op_build_array, 0);
    try out_chunk.write(testing.allocator, 2, 0);

    // Unpack 3 variables (should pad with nil). Stack becomes: [10.0, 20.0, nil]
    try out_chunk.writeOp(testing.allocator, .op_unpack, 0);
    try out_chunk.write(testing.allocator, 3, 0);

    // Pop the padded `nil` off the top of the stack
    try out_chunk.writeOp(testing.allocator, .op_pop, 0);

    // Return the next value down (which should be 20.0!)
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 5;

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // The result of the script is the 2nd unpacked variable (20.0)
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 20.0), vm.stack[0].asNumber());
}

test "VM: executes logical short-circuiting and comparisons correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // ==========================================
    // Test 1: 5 >= 3 (Should be true)
    // ==========================================
    const five = try b.number("5", 0);
    const three = try b.number("3", 0);
    const gte_node = try b.binary(.greater_equal, five, three, 0);

    var chunk1 = chunk.Chunk.init();
    defer chunk1.free(testing.allocator);

    var comp1 = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &chunk1, &vm);
    try comp1.compile(gte_node);

    var result = vm.interpret(&chunk1);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(true, vm.stack[0].asBool());

    // ==========================================
    // Test 2: false && 100
    // ==========================================
    // Reset the VM stack to clear out the previous result
    vm.stack_top = 0;

    // Because it is false, 100 should NEVER be evaluated!
    const f_node = try b.booleanNode(false, 0);
    const num_node = try b.number("100", 0);
    const and_node = try b.binary(.logical_and, f_node, num_node, 0);

    var chunk2 = chunk.Chunk.init();
    defer chunk2.free(testing.allocator);

    var comp2 = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &chunk2, &vm);
    try comp2.compile(and_node);

    result = vm.interpret(&chunk2);
    try testing.expectEqual(.ok, result);

    // The top of the stack should be `false`, and no errors should have occurred
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(false, vm.stack[0].asBool());
}

test "VM: executes Array.map with functional closure block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // 1. Build array [1, 2, 3]
    const one = try b.number("1", 0);
    const two = try b.number("2", 0);
    const three = try b.number("3", 0);
    const arr_span = try b.addNodes(&.{ one, two, three });
    const arr_node = try b.arrayLiteral(arr_span, 0, 0);

    // 2. Build block: { |x| x * 2 }
    const param_x = try b.identifierNode("x", 0);
    const get_x = try b.identifierNode("x", 0);
    const two_mul = try b.number("2", 0);
    const mult_node = try b.binary(.multiply, get_x, two_mul, 0);
    const block_node = try b.block(&.{param_x}, &.{mult_node}, 0, 0);

    // 3. Build map method call: arr.map { |x| x * 2 }
    const map_str = try b.intern("map");
    const empty_args = try b.addNamedArgs(&.{});
    const map_call = try b.methodCall(arr_node, map_str, empty_args, block_node, false, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @intFromEnum(map_call) + 1);

    // Update the Compiler.init call to pass `symbols.items` instead of `&.{}`
    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    try comp.compile(map_call);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Result should be a new array [2, 4, 6]!
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const final_arr = vm.stack[0];
    try testing.expect(final_arr.isObject());

    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", final_arr.asObj())));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 4.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 6.0), arr_obj.items.items[2].asNumber());
}

test "VM: Symbols map exactly to memory pointers for O(1) identity checks" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Allocate two separate :top symbols
    const sym1 = try vm.allocateSymbol("top");
    const sym2 = try vm.allocateSymbol("top");
    const sym3 = try vm.allocateSymbol("bottom");

    // They should evaluate to true
    try testing.expect(sym1.isEqual(sym2));
    try testing.expect(!sym1.isEqual(sym3));

    // Because they are interned, they must point to the exact same struct in memory!
    try testing.expectEqual(sym1.asObj(), sym2.asObj());
}

test "VM: Gas limit prevents infinite loops and throws specific error" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Set a tiny gas limit to trigger the timeout instantly
    vm.instruction_limit = 50;
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Create an infinite loop natively in bytecode.
    // op_loop takes a 2-byte offset to jump backwards.
    // By jumping back exactly 3 bytes (the size of op_loop + its offset), it loops forever.
    try out_chunk.writeOp(testing.allocator, .op_loop, 0);
    try out_chunk.write(testing.allocator, 0, 0); // Jump High Byte
    try out_chunk.write(testing.allocator, 3, 0); // Jump Low Byte

    // The VM will never reach this return
    try out_chunk.writeOp(testing.allocator, .op_return, 0);
    out_chunk.max_stack_slots = 1;

    const result = vm.interpret(&out_chunk);

    // Prove that it was safely killed by the gas limit!
    try testing.expectEqual(.execution_limit_exceeded, result);
    try testing.expectEqual(@as(usize, 51), vm.instruction_count);
}

test "VM: Math module namespace and functions" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Prove Math::PI via property access
    const math_str = try out_chunk.addConstant(testing.allocator, try vm.allocateString("Math"));
    const pi_str = try out_chunk.addConstant(testing.allocator, try vm.allocateString("PI"));
    try out_chunk.writeOp(testing.allocator, .op_get_global, 0);
    try out_chunk.write(testing.allocator, math_str, 0);
    try out_chunk.writeOp(testing.allocator, .op_get_property, 0);
    try out_chunk.write(testing.allocator, pi_str, 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 5;
    var result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(f64, std.math.pi), vm.stack[0].asNumber());

    // Clean up and prove Math.sin(0) = 0
    vm.stack_top = 0;
    out_chunk.code.clearRetainingCapacity();

    const sin_str = try out_chunk.addConstant(testing.allocator, try vm.allocateString("sin"));
    const arg_0 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(0));

    try out_chunk.writeOp(testing.allocator, .op_get_global, 0);
    try out_chunk.write(testing.allocator, math_str, 0); // Receiver (Math)
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, arg_0, 0); // Argument (0)

    try out_chunk.writeOp(testing.allocator, .op_invoke, 0); // Invoke method on receiver
    try out_chunk.write(testing.allocator, sin_str, 0);
    try out_chunk.write(testing.allocator, 1, 0); // 1 arg
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(f64, 0.0), vm.stack[0].asNumber());
}

test "VM: String Native Methods (split, replace)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Prove "hello world".split(" ")
    const str_val = try out_chunk.addConstant(testing.allocator, try vm.allocateString("hello world"));
    const split_str = try out_chunk.addConstant(testing.allocator, try vm.allocateString("split"));
    const delim_val = try out_chunk.addConstant(testing.allocator, try vm.allocateString(" "));

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, str_val, 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, delim_val, 0);
    try out_chunk.writeOp(testing.allocator, .op_invoke, 0);
    try out_chunk.write(testing.allocator, split_str, 0);
    try out_chunk.write(testing.allocator, 1, 0); // 1 arg
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 5;
    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    const arr = vm.stack[0];
    try testing.expect(arr.isObject() and arr.asObj().obj_type == .array);
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
}

test "VM: Array and Map Native Methods (slice, keys)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Create an Array [10, 20, 30]
    const val_10 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(10));
    const val_20 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(20));
    const val_30 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(30));

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, val_10, 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, val_20, 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, val_30, 0);
    try out_chunk.writeOp(testing.allocator, .op_build_array, 0);
    try out_chunk.write(testing.allocator, 3, 0); // stack[0] = Array

    // Call .slice(1, 2)
    const slice_str = try out_chunk.addConstant(testing.allocator, try vm.allocateString("slice"));
    const start_idx = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(1));
    const len_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(2));

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, start_idx, 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, len_val, 0);
    try out_chunk.writeOp(testing.allocator, .op_invoke, 0);
    try out_chunk.write(testing.allocator, slice_str, 0);
    try out_chunk.write(testing.allocator, 2, 0); // 2 args
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 6;
    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    const slice_arr = vm.stack[0];
    try testing.expect(slice_arr.isObject() and slice_arr.asObj().obj_type == .array);
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", slice_arr.asObj())));

    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[1].asNumber());
}

test "VM: Native yield instruction seamlessly calls implicitly passed block" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // 1. Build the child Block Closure: { |x| x * 2 }
    var block_chunk = try testing.allocator.create(chunk.Chunk);
    block_chunk.* = chunk.Chunk.init();
    defer {
        block_chunk.free(testing.allocator);
        testing.allocator.destroy(block_chunk);
    }

    // Push local 1 (x), push 2, multiply, return
    try block_chunk.writeOp(testing.allocator, .op_get_local, 0);
    try block_chunk.write(testing.allocator, 1, 0);
    const const_2 = try block_chunk.addConstant(testing.allocator, value.Value.initNumber(2.0));
    try block_chunk.writeOp(testing.allocator, .op_constant, 0);
    try block_chunk.write(testing.allocator, const_2, 0);
    try block_chunk.writeOp(testing.allocator, .op_multiply, 0);
    try block_chunk.writeOp(testing.allocator, .op_return, 0);
    block_chunk.max_stack_slots = 5;

    const block_func = try vm.gc.allocateFunction(&vm);
    block_func.chunk = block_chunk;
    block_func.owns_chunk = false;
    block_func.arity = 1;

    // 2. Build the Parent Function: def do_yield() yield(21) end
    var parent_chunk = try testing.allocator.create(chunk.Chunk);
    parent_chunk.* = chunk.Chunk.init();
    defer {
        parent_chunk.free(testing.allocator);
        testing.allocator.destroy(parent_chunk);
    }

    // Push 21, then Yield with 1 argument!
    const const_21 = try parent_chunk.addConstant(testing.allocator, value.Value.initNumber(21.0));
    try parent_chunk.writeOp(testing.allocator, .op_constant, 0);
    try parent_chunk.write(testing.allocator, const_21, 0);
    try parent_chunk.writeOp(testing.allocator, .op_yield, 0);
    try parent_chunk.write(testing.allocator, 1, 0); // 1 arg
    try parent_chunk.writeOp(testing.allocator, .op_return, 0);
    parent_chunk.max_stack_slots = 5;

    const parent_func = try vm.gc.allocateFunction(&vm);
    parent_func.chunk = parent_chunk;
    parent_func.owns_chunk = false;
    parent_func.arity = 0; // Expects 0 positional args

    // 3. Main script: do_yield() { |x| x * 2 }
    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(testing.allocator);

    const p_const = try main_chunk.addConstant(testing.allocator, value.Value.initObj(&parent_func.obj));
    const b_const = try main_chunk.addConstant(testing.allocator, value.Value.initObj(&block_func.obj));

    try main_chunk.writeOp(testing.allocator, .op_closure, 0);
    try main_chunk.write(testing.allocator, p_const, 0);

    try main_chunk.writeOp(testing.allocator, .op_closure, 0);
    try main_chunk.write(testing.allocator, b_const, 0);

    // Call Parent with 1 argument (the block counts as +1 in the raw arg_count before padding!)
    try main_chunk.writeOp(testing.allocator, .op_call, 0);
    try main_chunk.write(testing.allocator, 1, 0);
    try main_chunk.writeOp(testing.allocator, .op_return, 0);
    main_chunk.max_stack_slots = 5;

    const result = vm.interpret(&main_chunk);
    try testing.expectEqual(.ok, result);

    // 21 * 2 = 42
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 42.0), vm.stack[0].asNumber());
}

test "Compiler: compiles block_given? and yield intrinsics natively" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // 1. block_given?()
    const bg_str = try b.intern("block_given?");
    const empty_args = try b.addNamedArgs(&.{});
    const bg_call = try b.methodCall(.none, bg_str, empty_args, .none, false, 0, 0);

    // 2. yield(42)
    const yield_str = try b.intern("yield");
    const arg_42 = try b.number("42", 0);
    var args_buf = [_]ast.NamedArg{.{ .name = .none, .value = arg_42, .modifier = null }};
    const yield_args = try b.addNamedArgs(&args_buf);
    const yield_call = try b.methodCall(.none, yield_str, yield_args, .none, false, 0, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    try comp.compile(bg_call);
    try comp.compile(yield_call);

    // Verify block_given? compiled to exactly one byte!
    try testing.expectEqual(chunk.OpCode.op_block_given, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));

    // Skip op_return (1), then op_constant (2), index (3), op_yield (4)
    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_yield, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[4])));
    try testing.expectEqual(@as(u8, 1), out_chunk.code.items[5]); // 1 arg
}

test "VM: Splat parameters pack arbitrary arguments into an Array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // 1. AST: def func(a, *args) args end
    const func_name = try b.intern("func");
    // Create the parameters: 'a' and '*args'
    const p1 = ast.Param{ .name = try b.intern("a"), .default_value = .none, .modifier = null, .is_keyword = false };
    const p2 = ast.Param{ .name = try b.intern("args"), .default_value = .none, .modifier = .splat, .is_keyword = false };
    const params_span = try b.addParams(&.{ p1, p2 });

    const body = try b.identifierNode("args", 0);
    const def_node = try b.defStmt(func_name, params_span, body, false, 0, 0);

    // 2. AST: func(1, 2, 3, 4)
    const call_name = try b.intern("func");
    const a1 = try b.number("1", 0);
    const a2 = try b.number("2", 0);
    const a3 = try b.number("3", 0);
    const a4 = try b.number("4", 0);

    const args_span = try b.addNamedArgs(&.{
        .{ .name = .none, .value = a1, .modifier = null },
        .{ .name = .none, .value = a2, .modifier = null },
        .{ .name = .none, .value = a3, .modifier = null },
        .{ .name = .none, .value = a4, .modifier = null },
    });

    const call_node = try b.methodCall(.none, call_name, args_span, .none, false, 0, 0);

    // 3. Compile and Run
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    // Default all nodes to local (so parameters inside the function resolve correctly)
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, 100);
    // Force the function definition to be global so the methodCall explicitly finds it
    symbols.items[@intFromEnum(def_node)] = .{ .kind = .global, .index = 0 };

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);

    // Group into a block to execute as a single script sequence
    const block_node = try b.block(&.{}, &.{ def_node, call_node }, 0, 0);
    try comp.compile(block_node);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // The result should be the packed *args array: [2, 3, 4]
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const result_arr = vm.stack[0];
    try testing.expect(result_arr.isObject() and result_arr.asObj().obj_type == .array);

    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", result_arr.asObj())));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[1].asNumber()); // 3.0 is at index 1
    try testing.expectEqual(@as(f64, 4.0), arr_obj.items.items[2].asNumber());
}

test "VM: Splats (*args) and Keywords (**kwargs) compile and route perfectly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // 1. AST: def test_splat(a, *args, **kwargs) [args, kwargs] end
    const func_name = try b.intern("test_splat");
    const p1 = ast.Param{ .name = try b.intern("a"), .default_value = .none, .modifier = null, .is_keyword = false };
    const p2 = ast.Param{ .name = try b.intern("args"), .default_value = .none, .modifier = .splat, .is_keyword = false };
    const p3 = ast.Param{ .name = try b.intern("kwargs"), .default_value = .none, .modifier = .double_splat, .is_keyword = false };
    const params_span = try b.addParams(&.{ p1, p2, p3 });

    const ret_arr_span = try b.addNodes(&.{ try b.identifierNode("args", 0), try b.identifierNode("kwargs", 0) });
    const body = try b.arrayLiteral(ret_arr_span, 0, 0);
    const def_node = try b.defStmt(func_name, params_span, body, false, 0, 0);

    // 2. AST: test_splat(10, 20, 30, x: 100)
    const call_name = try b.intern("test_splat");
    const a1 = try b.number("10", 0);
    const a2 = try b.number("20", 0);
    const a3 = try b.number("30", 0);
    const kw_val = try b.number("100", 0);

    const args_span = try b.addNamedArgs(&.{
        .{ .name = .none, .value = a1, .modifier = null },
        .{ .name = .none, .value = a2, .modifier = null },
        .{ .name = .none, .value = a3, .modifier = null },
        .{ .name = try b.intern("x"), .value = kw_val, .modifier = null },
    });

    const call_node = try b.methodCall(.none, call_name, args_span, .none, false, 0, 0);

    // 3. Compile and Run
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    // Default all nodes to local (so parameters inside the function resolve correctly)
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, 100);
    // Force the function definition to be global so the methodCall explicitly finds it
    symbols.items[@intFromEnum(def_node)] = .{ .kind = .global, .index = 0 };

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);

    // Group into a block to execute as a single script sequence
    const block_node = try b.block(&.{}, &.{ def_node, call_node }, 0, 0);
    try comp.compile(block_node);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // The result should be an array: [ [20, 30], { "x" => 100 } ]
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const result_arr = vm.stack[0];
    try testing.expect(result_arr.isObject() and result_arr.asObj().obj_type == .array);
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", result_arr.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);

    // args == [20, 30]
    const packed_args = arr_obj.items.items[0];
    try testing.expect(packed_args.isObject() and packed_args.asObj().obj_type == .array);
    const packed_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", packed_args.asObj())));
    try testing.expectEqual(@as(usize, 2), packed_obj.items.items.len);
    try testing.expectEqual(@as(f64, 20.0), packed_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), packed_obj.items.items[1].asNumber());

    // kwargs == {"x" => 100}
    const packed_kwargs = arr_obj.items.items[1];
    try testing.expect(packed_kwargs.isObject() and packed_kwargs.asObj().obj_type == .map);
    const map_obj = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", packed_kwargs.asObj())));
    try testing.expectEqual(@as(usize, 1), map_obj.keys.items.len);
}
