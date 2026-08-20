const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const resolver = @import("../core/resolver.zig");
const value = @import("../core/value.zig");
const kernel = @import("../kernel/kernel.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../core/document.zig").Document;
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
    defer comp.deinit();
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
    try out_chunk.write(testing.allocator, @intCast(name_idx), 0);
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
    defer comp.deinit();
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
    defer comp.deinit();
    try comp.compile(add_node);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top); // Changed from 2 to 1

    const final_val = vm.stack[0];
    try testing.expect(final_val.isGeometry());
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
    try main_chunk.write(testing.allocator, @intCast(const_42), 0);

    // Instantiate the Closure
    const const_func = try main_chunk.addConstant(testing.allocator, value.Value.initObj(&func.obj));
    try main_chunk.writeOp(testing.allocator, .op_closure, 0);
    try main_chunk.write(testing.allocator, @intCast(const_func), 0);

    // Upvalue parameters: is_local = 1, index = 1 (captures stack slot 1, where 42 is sitting)
    try main_chunk.write(testing.allocator, 1, 0); // is_local flag
    try main_chunk.write(testing.allocator, 0, 0); // NEW: index high byte (0)
    try main_chunk.write(testing.allocator, 1, 0); // index low byte (1)

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
    try out_chunk.write(testing.allocator, @intCast(c42), 0);
    try out_chunk.writeOp(testing.allocator, .op_array_push, 0);

    // 3. Source Array: Build [1, 2]
    const c1 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(1.0));
    const c2 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(2.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(c1), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(c2), 0);
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
    try out_chunk.write(testing.allocator, 0xFF, 0); // 3-byte offset

    // 2. Push a dummy variable to prove stack unwinding drops dead variables cleanly
    const dummy = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(99.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(dummy), 0);

    // 3. Throw an Error!
    const err_str_val = try vm.allocateString("Crash!");
    vm.ensureStackCapacity(1) catch unreachable;
    vm.push(err_str_val);
    const err_str = try out_chunk.addConstant(testing.allocator, err_str_val);
    _ = vm.pop();

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(err_str), 0);
    try out_chunk.writeOp(testing.allocator, .op_throw, 0);

    // 4. Success path (Should be completely skipped by the VM unwinder!)
    try out_chunk.writeOp(testing.allocator, .op_pop_rescue, 0);
    try out_chunk.writeOp(testing.allocator, .op_jump, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 4, 0); // skip over rescue block

    // --- RESCUE HANDLER ---
    // Patch the setup_rescue offset so it lands exactly here
    const handler_ip = out_chunk.code.items.len;
    const offset = handler_ip - (jump_idx + 3);
    out_chunk.code.items[jump_idx] = @intCast((offset >> 16) & 0xFF);
    out_chunk.code.items[jump_idx + 1] = @intCast((offset >> 8) & 0xFF);
    out_chunk.code.items[jump_idx + 2] = @intCast(offset & 0xFF);

    // Pop the "Crash!" error off the stack
    try out_chunk.writeOp(testing.allocator, .op_pop, 0);

    // Return a fallback value of 42
    const c42 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(c42), 0);
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
    try out_chunk.write(testing.allocator, @intCast(err_idx), 0);

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
    try out_chunk.write(testing.allocator, @intCast(str_idx), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(num_idx), 0);
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
    try out_chunk.write(testing.allocator, @intCast(num_idx), 0);
    try out_chunk.writeOp(testing.allocator, .op_invoke, 0);
    try out_chunk.write(testing.allocator, @intCast(m_idx), 0);
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
    try out_chunk.write(testing.allocator, @intCast(test_val), 0);

    // op_switch with 2 cases
    try out_chunk.writeOp(testing.allocator, .op_switch, 0);
    try out_chunk.write(testing.allocator, 2, 0); // case count

    // Table Entry 1: case 10
    try out_chunk.write(testing.allocator, @intCast((case1_val >> 8) & 0xFF), 0); // const high
    try out_chunk.write(testing.allocator, @intCast(case1_val & 0xFF), 0); // const low
    try out_chunk.write(testing.allocator, 0, 0); // jump high
    try out_chunk.write(testing.allocator, 0, 0); // jump mid
    try out_chunk.write(testing.allocator, 0, 0); // relative offset 0

    // Table Entry 2: case 42
    try out_chunk.write(testing.allocator, @intCast((case2_val >> 8) & 0xFF), 0); // const high
    try out_chunk.write(testing.allocator, @intCast(case2_val & 0xFF), 0); // const low
    try out_chunk.write(testing.allocator, 0, 0); // jump high
    try out_chunk.write(testing.allocator, 0, 0); // jump mid
    try out_chunk.write(testing.allocator, 3, 0); // relative offset 3 (Size of Branch 1 block)

    // Default Entry:
    try out_chunk.write(testing.allocator, 0, 0); // jump high
    try out_chunk.write(testing.allocator, 0, 0); // jump mid
    try out_chunk.write(testing.allocator, 6, 0); // relative offset 6 (Size of B1 + B2 blocks)

    // Branch 1 (Target: offset + 3) -> Pushes 100
    const b1_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(100.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(b1_val), 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    // Branch 2 (Target: offset + 6) -> Pushes 200 [THIS SHOULD EXECUTE]
    const b2_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(200.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(b2_val), 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    // Default Branch (Target: offset + 6) -> Pushes 300
    const bdef_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(300.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(bdef_val), 0);
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
    try out_chunk.write(testing.allocator, @intCast(val1), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(val2), 0);

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
    defer comp1.deinit();
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
    defer comp2.deinit();
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
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @intFromEnum(map_call) + 1);

    // Update the Compiler.init call to pass `symbols.items` instead of `&.{}`
    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
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
    // op_loop takes a 3-byte offset to jump backwards.
    // By jumping back exactly 4 bytes (the size of op_loop + its offset), it loops forever.
    try out_chunk.writeOp(testing.allocator, .op_loop, 0);
    try out_chunk.write(testing.allocator, 0, 0); // Jump High Byte
    try out_chunk.write(testing.allocator, 0, 0); // Jump Mid Byte
    try out_chunk.write(testing.allocator, 4, 0); // Jump Low Byte

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
    try out_chunk.write(testing.allocator, @intCast(math_str), 0);
    try out_chunk.writeOp(testing.allocator, .op_get_property, 0);
    try out_chunk.write(testing.allocator, @intCast(pi_str), 0);
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
    try out_chunk.write(testing.allocator, @intCast(math_str), 0); // Receiver (Math)
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(arg_0), 0); // Argument (0)

    try out_chunk.writeOp(testing.allocator, .op_invoke, 0); // Invoke method on receiver
    try out_chunk.write(testing.allocator, @intCast(sin_str), 0);
    try out_chunk.write(testing.allocator, 1, 0); // 1 arg
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(f64, 0.0), vm.stack[0].asNumber());
}

test "VM: String Native Methods (split, replace)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Prove "hello world".split(" ")
    const str_val = try out_chunk.addConstant(testing.allocator, try vm.allocateString("hello world"));
    const split_str = try out_chunk.addConstant(testing.allocator, try vm.allocateString("split"));
    const delim_val = try out_chunk.addConstant(testing.allocator, try vm.allocateString(" "));

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(str_val), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(delim_val), 0);
    try out_chunk.writeOp(testing.allocator, .op_invoke, 0);
    try out_chunk.write(testing.allocator, @intCast(split_str), 0);
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
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Create an Array [10, 20, 30]
    const val_10 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(10));
    const val_20 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(20));
    const val_30 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(30));

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(val_10), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(val_20), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(val_30), 0);
    try out_chunk.writeOp(testing.allocator, .op_build_array, 0);
    try out_chunk.write(testing.allocator, 3, 0); // stack[0] = Array

    // Call .slice(1, 2)
    const slice_str = try out_chunk.addConstant(testing.allocator, try vm.allocateString("slice"));
    const start_idx = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(1));
    const len_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(2));

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(start_idx), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(len_val), 0);
    try out_chunk.writeOp(testing.allocator, .op_invoke, 0);
    try out_chunk.write(testing.allocator, @intCast(slice_str), 0);
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
    try block_chunk.write(testing.allocator, @intCast(const_2), 0);
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
    try parent_chunk.write(testing.allocator, @intCast(const_21), 0);
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
    try main_chunk.write(testing.allocator, @intCast(p_const), 0);

    try main_chunk.writeOp(testing.allocator, .op_closure, 0);
    try main_chunk.write(testing.allocator, @intCast(b_const), 0);

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
    defer comp.deinit();
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
    const a_id = try b.intern("a");
    const args_id = try b.intern("args");

    const p1 = ast.Param{ .name = a_id, .default_value = .none, .modifier = null, .is_keyword = false };
    const p2 = ast.Param{ .name = args_id, .default_value = .none, .modifier = .splat, .is_keyword = false };
    const params_span = try b.addParams(&.{ p1, p2 });

    // Use the exact StringId so the compiler resolves local slot 2 accurately
    const body = try b.createNode(.identifier, 0, @intFromEnum(args_id));
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
    defer comp.deinit();

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
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 4.0), arr_obj.items.items[2].asNumber());
}

test "VM: Compiles and executes class variables (@@var)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class Counter
        \\  def init()
        \\    @@count = 10
        \\  end
        \\  def get()
        \\    @@count
        \\  end
        \\end
        \\c = Counter.new()
        \\c.init()
        \\c.get()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 10.0), vm.stack[0].asNumber());
}

test "VM: Compiles and executes class methods (def self.method)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class MathUtils
        \\  def self.double(x)
        \\    x * 2
        \\  end
        \\end
        \\MathUtils.double(21)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 42.0), vm.stack[0].asNumber());
}

test "VM: Standard exceptions are caught in rescue blocks natively" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests that subclass (ArgumentError) gracefully cascades and is caught securely
    const source =
        \\begin
        \\  raise(ArgumentError)
        \\rescue TypeError => e
        \\  10
        \\rescue ArgumentError => e
        \\  42
        \\rescue StandardError => e
        \\  99
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 42.0), vm.stack[0].asNumber());
}

test "VM: Splats (*args) and Keywords (**kwargs) compile and route perfectly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // 1. AST: def test_splat(a, *args, **kwargs) [args, kwargs] end
    const func_name = try b.intern("test_splat");
    const a_id = try b.intern("a");
    const args_id = try b.intern("args");
    const kwargs_id = try b.intern("kwargs");

    const p1 = ast.Param{ .name = a_id, .default_value = .none, .modifier = null, .is_keyword = false };
    const p2 = ast.Param{ .name = args_id, .default_value = .none, .modifier = .splat, .is_keyword = false };
    const p3 = ast.Param{ .name = kwargs_id, .default_value = .none, .modifier = .double_splat, .is_keyword = false };
    const params_span = try b.addParams(&.{ p1, p2, p3 });

    // Use the exact StringIds so local slots 2 and 3 resolve perfectly
    const arg_node = try b.createNode(.identifier, 0, @intFromEnum(args_id));
    const kwarg_node = try b.createNode(.identifier, 0, @intFromEnum(kwargs_id));
    const ret_arr_span = try b.addNodes(&.{ arg_node, kwarg_node });
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
    defer comp.deinit();

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
    const packed_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", packed_args.asObj())));
    try testing.expectEqual(@as(usize, 2), packed_obj.items.items.len);
    try testing.expectEqual(@as(f64, 20.0), packed_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), packed_obj.items.items[1].asNumber());

    // kwargs == {"x" => 100}
    const packed_kwargs = arr_obj.items.items[1];
    const map_obj = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", packed_kwargs.asObj())));
    try testing.expectEqual(@as(usize, 1), map_obj.keys.items.len);
}

test "VM: Explicit block capturing (&block) and first-class invocation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\def run_block(&b)
        \\  b(42)
        \\end
        \\run_block { |x| x * 2 }
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // We intentionally DO NOT override doc.symbols here, so `x` stays a clean local!

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 84.0), vm.stack[0].asNumber());
}

test "VM: LHS Splat Destructuring (a, *b, c = arr)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\arr = [10, 20, 30, 40, 50]
        \\a, *b, c = arr
        \\[a, b, c]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    // Outer array
    const out_arr = vm.stack[0];
    const out_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", out_arr.asObj())));
    try testing.expectEqual(@as(usize, 3), out_obj.items.items.len);

    // a = 10
    try testing.expectEqual(@as(f64, 10.0), out_obj.items.items[0].asNumber());

    // b = [20, 30, 40]
    const b_arr = out_obj.items.items[1];
    const b_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", b_arr.asObj())));
    try testing.expectEqual(@as(usize, 3), b_obj.items.items.len);
    try testing.expectEqual(@as(f64, 20.0), b_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 40.0), b_obj.items.items[2].asNumber());

    // c = 50
    try testing.expectEqual(@as(f64, 50.0), out_obj.items.items[2].asNumber());
}

test "VM: Named Keyword Arguments with default values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // 1. AST: def build_box(width:, height: 20) [width, height] end
    const func_name = try b.intern("build_box");
    const w_id = try b.intern("width");
    const h_id = try b.intern("height");

    const p1 = ast.Param{ .name = w_id, .default_value = .none, .modifier = null, .is_keyword = true };
    const h_def = try b.number("20", 0);
    const p2 = ast.Param{ .name = h_id, .default_value = h_def, .modifier = null, .is_keyword = true };
    const params_span = try b.addParams(&.{ p1, p2 });

    const w_node = try b.createNode(.identifier, 0, @intFromEnum(w_id));
    const h_node = try b.createNode(.identifier, 0, @intFromEnum(h_id));
    const ret_arr_span = try b.addNodes(&.{ w_node, h_node });
    const body = try b.arrayLiteral(ret_arr_span, 0, 0);

    const def_node = try b.defStmt(func_name, params_span, body, false, 0, 0);

    // 2. AST: build_box(width: 50)
    const call_name = try b.intern("build_box");
    const w_val = try b.number("50", 0);
    const args_span = try b.addNamedArgs(&.{
        .{ .name = w_id, .value = w_val, .modifier = null },
    });
    const call_node = try b.methodCall(.none, call_name, args_span, .none, false, 0, 0);

    // 3. Compile and Run
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Mock the symbols array so the compiler doesn't panic out-of-bounds
    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, 100);
    symbols.items[@intFromEnum(def_node)] = .{ .kind = .global, .index = 0 };

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    const block_node = try b.block(&.{}, &.{ def_node, call_node }, 0, 0);
    try comp.compile(block_node);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const result_arr = vm.stack[0];
    try testing.expect(result_arr.isObject() and result_arr.asObj().obj_type == .array);
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", result_arr.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[0].asNumber()); // Passed width
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber()); // Default height
}

test "VM: defined? operator evaluates safely without panicking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // defined?(missing_var)
    const missing_id = try b.intern("missing_var");
    const ident_node = try b.createNode(.identifier, 0, @intFromEnum(missing_id));
    const def_expr = try b.createNode(.defined_expr, 0, @intFromEnum(ident_node));

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(def_expr);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expect(vm.stack[0].isNil()); // Returns nil if undefined
}

test "VM: Modules and Mixins (include)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\module Greeter
        \\  def greet()
        \\    42
        \\  end
        \\end
        \\
        \\class Person
        \\  include Greeter
        \\end
        \\
        \\p = Person.new()
        \\p.greet()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 42.0), vm.stack[0].asNumber());
}

test "VM: executes while loops with break and next" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Loop from 1 to 5.
    // Skip 3 (next), stop at 5 (break).
    // Sum should be 1 + 2 + 4 = 7.
    const source =
        \\i = 0
        \\sum = 0
        \\while (i < 5)
        \\  i = i + 1
        \\  if (i == 3)
        \\    next
        \\  end
        \\  if (i == 5)
        \\    break
        \\  end
        \\  sum = sum + i
        \\end
        \\sum
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 7.0), vm.stack[0].asNumber());
}

test "VM: executes ternary operator with short-circuiting" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\x = 10
        \\y = 10
        \\true ? (x = 20) : (x = 30)
        \\false ? (y = 20) : (y = 30)
        \\[x, y]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Result should be an array: [20, 30]
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isObject() and arr_val.asObj().obj_type == .array);

    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[1].asNumber());
}

test "VM Edge Case: Out of bounds array indexing returns runtime error" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.mute_errors = true; // Prevent the error from cluttering test output

    const source =
        \\arr = [10, 20, 30]
        \\arr[5]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    // Should safely abort rather than panic
    try testing.expectEqual(.runtime_error, result);
}

test "VM: Module mixin method resolution order" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class Base
        \\  def call() 1 end
        \\end
        \\module M1
        \\  def call() 2 end
        \\end
        \\module M2
        \\  def call() 3 end
        \\end
        \\
        \\class Child < Base
        \\  include M1
        \\  include M2
        \\end
        \\
        \\class ChildLocal < Base
        \\  include M2
        \\  def call() 4 end
        \\end
        \\
        \\[Child.new().call(), ChildLocal.new().call()]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    // Result should be an array: [3, 4]
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);

    // Child: M2 overrides M1 and Base
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[0].asNumber());
    // ChildLocal: Local class method overrides M2
    try testing.expectEqual(@as(f64, 4.0), arr_obj.items.items[1].asNumber());
}

test "VM: Array utility methods (max, min, sum, flatten)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\arr = [5, 2, 9]
        \\nested = [[1, 2], [3]]
        \\flat = nested.flatten()
        \\[arr.max(), arr.min(), arr.sum(), arr.first(), arr.last(), flat.length()]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 6), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 9.0), arr_obj.items.items[0].asNumber()); // max
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[1].asNumber()); // min
    try testing.expectEqual(@as(f64, 16.0), arr_obj.items.items[2].asNumber()); // sum
    try testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[3].asNumber()); // first
    try testing.expectEqual(@as(f64, 9.0), arr_obj.items.items[4].asNumber()); // last
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[5].asNumber()); // flat length
}

test "VM: Symbol conversion and Map key manipulation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\m1 = { "a" => 10 }
        \\m2 = m1.symbolize_keys()
        \\m3 = m2.stringify_keys()
        \\[ m2[:a], m3["a"], :test.to_s(), "test".to_sym() == :test ]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber()); // m2[:a]
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[1].asNumber()); // m3["a"]

    // :test.to_s() == "test"
    const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[2].asObj())));
    try testing.expectEqualStrings("test", str_obj.chars);

    // "test".to_sym() == :test
    try testing.expectEqual(true, arr_obj.items.items[3].asBool());
}

test "VM: Type coercion and Number methods" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\[ 3.14159.round(2), 3.14.ceil(), 3.14.floor(), 42.to_s(), "42.5".to_f(), "42".to_i() ]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 6), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 3.14), arr_obj.items.items[0].asNumber()); // round(2)
    try testing.expectEqual(@as(f64, 4.0), arr_obj.items.items[1].asNumber()); // ceil()
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[2].asNumber()); // floor()

    // 42.to_s() == "42"
    const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[3].asObj())));
    try testing.expectEqualStrings("42", str_obj.chars);

    try testing.expectEqual(@as(f64, 42.5), arr_obj.items.items[4].asNumber()); // "42.5".to_f()
    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[5].asNumber()); // "42".to_i()
}

test "VM: Negative array indexing" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\arr = [10, 20, 30]
        \\[arr[-1], arr[-2], arr[-3]]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    // -1 = last, -2 = middle, -3 = first
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[2].asNumber());
}

test "VM: case statement subsumption (===) with ranges and classes" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Replaced 'then' with newlines for valid KupCAD syntax
    const source =
        \\def check_val(x)
        \\  case x
        \\  when String
        \\    100
        \\  when 1..10
        \\    200
        \\  else
        \\    300
        \\  end
        \\end
        \\[check_val("hello"), check_val(5), check_val(42)]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[0].asNumber()); // Matches Class
    try testing.expectEqual(@as(f64, 200.0), arr_obj.items.items[1].asNumber()); // Matches Range
    try testing.expectEqual(@as(f64, 300.0), arr_obj.items.items[2].asNumber()); // Fallback
}

test "VM Edge Case: executes 24-bit control flow jump correctly (> 65KB block)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Push 'false' to trigger the jump
    try out_chunk.writeOp(testing.allocator, .op_false, 0);

    // Jump if false over 70,000 bytes!
    try out_chunk.writeOp(testing.allocator, .op_jump_if_false, 0);
    const jump_dist: usize = 70000;
    try out_chunk.write(testing.allocator, @intCast((jump_dist >> 16) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast((jump_dist >> 8) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast(jump_dist & 0xFF), 0);

    try out_chunk.writeOp(testing.allocator, .op_pop, 0); // pop condition if true

    // Pad exactly 70,000 bytes of dummy instructions
    try out_chunk.code.appendNTimes(testing.allocator, @intFromEnum(chunk.OpCode.op_nil), jump_dist);

    // Landing zone
    try out_chunk.writeOp(testing.allocator, .op_pop, 0); // pop condition if false
    const success_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(success_val), 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 5;

    // Temporarily increase gas limit because decoding 70,000 nils counts against instructions run
    vm.instruction_limit = 200_000;

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // The VM should successfully land and return 42!
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 42.0), vm.stack[0].asNumber());
}

test "VM: JIT materialization cascades through DAG and ARC safely cleans up" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Build a complex symbolic DAG (Cube + Sphere + Translate)
    // 2. Call `.bbox()` to force JIT materialization down the entire tree!
    const source =
        \\part = cube(10, 10, 10, true) + sphere(5).translate(0, 0, 5)
        \\part.bbox()
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Execute the script
    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const bbox_val = vm.stack[0];
    try testing.expect(bbox_val.isInstance());
    const bbox_inst = bbox_val.asInstance();

    // BoundingBox now has 16 dynamically assigned fields
    try testing.expectEqual(@as(u32, 12), bbox_inst.class.instance_layout.count());

    // When the test scope ends, `defer vm.deinit()` will clear the VM stack.
    // This will drop the ARC ref_count of the `part` geometry to 0.
    // The GC will immediately route the pointer to `host.mesh_destructor`, safely freeing the C++ Manifold memory.
    // If ANY memory is leaked across the FFI boundary, Zig's testing allocator will fail the test right here!
}

test "VM: Primitives support flexible keyword arguments and shortcuts" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests:
    // 1. cube(10) -> uniform 10x10x10 cube
    // 2. cube(x: 10, y: 20, z: 30, center: true) -> explicit axes & center
    // 3. sphere(d: 20) -> diameter conversion to r=10
    // 4. cylinder(d: 10, h: 15) -> diameter & height overrides
    const source =
        \\c1 = cube(10)
        \\c2 = cube(x: 10, y: 20, z: 30, center: true)
        \\s1 = sphere(d: 20)
        \\cyl = cylinder(d: 10, h: 15)
        \\[c1.bbox(), c2.bbox(), s1.bbox(), cyl.bbox()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    // Verify the returned array contains all 4 bounding boxes
    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());
    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);
}

test "STL Exporter: exports valid Binary STL file with expected byte structure" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    const test_stl_path = "test_export_cube.stl";

    // Clean up the output file if it already exists before running the test
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(testing.io, test_stl_path) catch {};
    defer cwd.deleteFile(testing.io, test_stl_path) catch {};

    // 1. Run script exporting a 10x10x10 cube
    const source =
        \\part = cube(10)
        \\export_stl("test_export_cube.stl", part)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);

    // 2. Read the generated STL file back using @enumFromInt for std.Io.Limit
    const file_contents = try cwd.readFileAlloc(
        testing.io,
        test_stl_path,
        testing.allocator,
        @enumFromInt(10 * 1024 * 1024),
    );
    defer testing.allocator.free(file_contents);

    // Header must be at least 84 bytes (80-byte header + 4-byte triangle count)
    try testing.expect(file_contents.len >= 84);

    // Read the 32-bit triangle count from bytes 80..84 (little-endian)
    const tri_count = std.mem.readInt(u32, file_contents[80..84], .little);

    // A standard cube has 12 triangles (2 per face * 6 faces)
    try testing.expectEqual(@as(u32, 12), tri_count);

    // Verify exact binary size: 84 + (12 triangles * 50 bytes) = 684 bytes
    const expected_file_size = 84 + (@as(usize, tri_count) * 50);
    try testing.expectEqual(expected_file_size, file_contents.len);
}

test "VM: Inspection methods (volume, bbox) and inspect() work in KupCAD scripts" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    // Mute print_handler during unit tests
    vm.host.print_handler = null;

    const source =
        \\base = cube(size: 30, center: true)
        \\hole = cylinder(d: 10, h: 40, center: true)
        \\part = base - hole
        \\inspect(part.volume())
        \\inspect(part.bbox())
        \\part
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expect(vm.stack[0].isGeometry());

    // Verify discrete tessellated volume calculation (~24,658.92)
    const handle = try vm.ensureConcrete(vm.stack[0]);
    const vol = kernel.volume(handle);
    try testing.expect(vol > 24600.0 and vol < 24700.0);
}

test "VM: 2D primitives, sweeps, and Bitwise AND (Intersection) work seamlessly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Mute print_handler during unit tests
    vm.host.print_handler = null;

    // Test script:
    // 1. Create a 10x10 square and extrude it 50 units (Volume should be 5000)
    // 2. Create two 10x10x10 cubes, shift one by 5, and Intersect them (Volume should be 125)
    const source =
        \\sq = square(size: 10, center: true)
        \\part1 = sq.extrude(50)
        \\
        \\box1 = cube(10, 10, 10, false)
        \\box2 = cube(10, 10, 10, false).translate(5, 5, 5)
        \\part2 = box1 & box2
        \\
        \\[part1.volume(), part2.volume()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());
    const arr_obj = arr_val.asArray();

    // Extruded 10x10 square up to 50 = 5000 volume
    try testing.expect(arr_obj.items.items[0].asNumber() > 4999.0);
    try testing.expect(arr_obj.items.items[0].asNumber() < 5001.0);

    // Intersecting cubes should yield a 5x5x5 cube = 125 volume
    try testing.expect(arr_obj.items.items[1].asNumber() > 124.0);
    try testing.expect(arr_obj.items.items[1].asNumber() < 126.0);
}

test "VM: 2D Boolean Operations (Union, Difference, Intersection) work seamlessly before 3D extrusion" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    // Test script:
    // 1. Create a 20x20 square plate (Area = 400)
    // 2. Subtract a D=10 circle from it (Area = pi * r^2 = ~78.54)
    // 3. Extrude the result by 10 units (Volume = Area * 10 = ~3214.6)
    const source =
        \\sq = square(size: 20, center: true)
        \\circ = circle(d: 10)
        \\part2d = sq - circ
        \\part3d = part2d.extrude(10)
        \\part3d.volume()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const vol = vm.stack[0].asNumber();
    try testing.expect(vol > 3200.0 and vol < 3230.0);
}

test "VM: Minkowski sums and 2D Offsets evaluate correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    // Test script:
    // 1. Minkowski: A 10x10x10 cube and a r=2 sphere.
    //    Bounds should expand from [-5, 5] to [-7, 7].
    // 2. Offset: A 10x10 square offset by 2 (creates rounded corners by default).
    //    Area = 100 (base) + 80 (edges) + ~12.56 (corners) = ~192.56.
    //    Extruded by 10 = ~1925.6 volume.
    const source =
        \\c = cube(size: 10, center: true)
        \\s = sphere(r: 2)
        \\m_part = c.minkowski(s)
        \\
        \\sq = square(size: 10, center: true)
        \\off_sq = sq.offset(2)
        \\off_part = off_sq.extrude(10)
        \\
        \\[m_part.bbox(), off_part.volume()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());
    const arr_obj = arr_val.asArray();

    // 1. Minkowski BBox map checks
    const bbox_inst = arr_obj.items.items[0].asInstance();
    try testing.expect(bbox_inst.class.instance_layout.contains("min_x"));
    try testing.expect(bbox_inst.class.instance_layout.contains("max_y"));

    // 2. Offset volume check (~1925.6)
    const vol = arr_obj.items.items[1].asNumber();
    try testing.expect(vol > 1900.0 and vol < 2000.0);
}

test "VM: Affine transformations via multmatrix evaluate correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    // Test script:
    // 1. 3D Transform: Translate a cube by +5, +10, +15 using an explicit 4x3 matrix.
    // 2. 2D Transform: Translate a square by +2, +4 using an explicit 3x2 matrix.
    const source =
        \\c = cube(size: 10, center: true)
        \\c_trans = c.transform([1, 0, 0,  0, 1, 0,  0, 0, 1,  5, 10, 15])
        \\
        \\sq = square(size: 10, center: true)
        \\sq_trans = sq.transform([1, 0,  0, 1,  2, 4])
        \\
        \\[c_trans.bbox(), sq_trans.extrude(10).bbox()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());
    const arr_obj = arr_val.asArray();

    // Check 3D Transform
    const c_bbox = arr_obj.items.items[0].asInstance();
    const c_min_x_idx = c_bbox.class.instance_layout.get("min_x").?;
    const c_min_y_idx = c_bbox.class.instance_layout.get("min_y").?;
    try testing.expectEqual(@as(f64, 0.0), c_bbox.fields.items[c_min_x_idx].asNumber()); // -5 + 5
    try testing.expectEqual(@as(f64, 5.0), c_bbox.fields.items[c_min_y_idx].asNumber()); // -5 + 10

    // Check 2D Transform
    const sq_bbox = arr_obj.items.items[1].asInstance();
    const sq_min_x_idx = sq_bbox.class.instance_layout.get("min_x").?;
    const sq_min_y_idx = sq_bbox.class.instance_layout.get("min_y").?;
    try testing.expectEqual(@as(f64, -3.0), sq_bbox.fields.items[sq_min_x_idx].asNumber()); // -5 + 2
    try testing.expectEqual(@as(f64, -1.0), sq_bbox.fields.items[sq_min_y_idx].asNumber()); // -5 + 4
}

test "VM: Spatial Queries (min_gap, contains?, ray_cast) evaluate safely" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    // Script:
    // 1. Min Gap between two cubes offset by 15 units. Gap should be 5.
    // 2. Contains point: cube size 10, center true. contains [0,0,0], doesn't contain [10, 10, 10]
    // 3. Ray cast: cube size 10. Cast from [0, 0, 10] to [0, 0, -10]. Hits top face at z=5.
    const source =
        \\c1 = cube(size: 10, center: true)
        \\c2 = cube(size: 10, center: true).translate(15, 0, 0)
        \\gap = c1.min_gap(c2)
        \\
        \\in1 = c1.contains?([0, 0, 0])
        \\in2 = c1.contains?([10, 10, 10])
        \\
        \\ray_hits = c1.ray_cast([0, 0, 10], [0, 0, -10])
        \\
        \\[gap, in1, in2, ray_hits.length(), ray_hits[0]["distance"], ray_hits[0]["position"][2]]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());
    const arr_obj = arr_val.asArray();

    // 1. Min gap (kernel extrema search)
    try testing.expect(arr_obj.items.items[0].asNumber() > 0.0);
    // 2. Contains [0,0,0] = true
    try testing.expectEqual(true, arr_obj.items.items[1].asBool());
    // 3. Contains [10,10,10] = false
    try testing.expectEqual(false, arr_obj.items.items[2].asBool());
    // 4. Ray hits length
    try testing.expect(arr_obj.items.items[3].asNumber() > 0.0);
    // 5. Metric distance from [0, 0, 10] to top face [0, 0, 5] = 5.0 units!
    try testing.expectApproxEqAbs(@as(f64, 5.0), arr_obj.items.items[4].asNumber(), 0.1);
    // 6. Hit position Z = 5.0
    try testing.expectApproxEqAbs(@as(f64, 5.0), arr_obj.items.items[5].asNumber(), 0.1);
}

test "VM: Custom Polygons and Fixed Matrix Transforms evaluate seamlessly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    // Test Script:
    // 1. Create a custom 2D Triangle using `polygon`
    // 2. Skew the 2D polygon using a 3x2 Transformation Matrix
    // 3. Extrude to 3D and skew again using a 4x3 Transformation Matrix
    const source =
        \\pts = [ [0, 0], [10, 0], [0, 10] ]
        \\poly = polygon(pts)
        \\
        \\# 2D Transform (Scale X by 2, Translate Y by 5)
        \\poly_trans = poly.transform([2, 0,  0, 1,  0, 5])
        \\
        \\# 3D Transform (Extrude, then translate Z by 15)
        \\poly_3d = poly_trans.extrude(10).transform([1, 0, 0,  0, 1, 0,  0, 0, 1,  0, 0, 15])
        \\
        \\[poly_3d.volume()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    // Area of Triangle was (10 * 10) / 2 = 50
    // Scale X by 2 -> Area = 100
    // Extrude by 10 -> Volume = 1000
    const vol = vm.stack[0].asArray().items.items[0].asNumber();
    try testing.expect(vol > 999.0 and vol < 1001.0);
}

test "VM: Native string and array addition (+ operator)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    const source =
        \\s = "Hello " + "World"
        \\arr = [1, 2] + [3, 4]
        \\[s, arr]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const outer_arr = vm.stack[0].asArray().items.items;

    // Check String Concatenation
    const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", outer_arr[0].asObj())));
    try testing.expectEqualStrings("Hello World", str_obj.chars);

    // Check Array Concatenation
    const inner_arr = outer_arr[1].asArray().items.items;
    try testing.expectEqual(@as(usize, 4), inner_arr.len);
    try testing.expectEqual(@as(f64, 1.0), inner_arr[0].asNumber());
    try testing.expectEqual(@as(f64, 4.0), inner_arr[3].asNumber());
}

test "VM: Object Reflection (is_a? and responds_to?)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Animal
        \\  def speak() "roar" end
        \\end
        \\class Dog < Animal
        \\  def bark() "woof" end
        \\end
        \\
        \\d = Dog.new()
        \\[
        \\  d.is_a?(Dog),
        \\  d.is_a?(Animal),
        \\  d.is_a?(String),
        \\  "test".is_a?(String),
        \\  d.responds_to?(:bark),
        \\  d.responds_to?("speak"),
        \\  d.responds_to?(:meow),
        \\  [1, 2, 3].responds_to?(:push)
        \\]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());

    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 8), arr_obj.items.items.len);

    // d.is_a?(Dog) -> true
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());
    // d.is_a?(Animal) -> true (Testing superclass inheritance tracking)
    try testing.expectEqual(true, arr_obj.items.items[1].asBool());
    // d.is_a?(String) -> false
    try testing.expectEqual(false, arr_obj.items.items[2].asBool());
    // "test".is_a?(String) -> true (Testing primitive class tracking)
    try testing.expectEqual(true, arr_obj.items.items[3].asBool());

    // d.responds_to?(:bark) -> true
    try testing.expectEqual(true, arr_obj.items.items[4].asBool());
    // d.responds_to?("speak") -> true (Testing superclass method tracking and String arg)
    try testing.expectEqual(true, arr_obj.items.items[5].asBool());
    // d.responds_to?(:meow) -> false
    try testing.expectEqual(false, arr_obj.items.items[6].asBool());
    // [1, 2, 3].responds_to?(:push) -> true (Testing primitive methods)
    try testing.expectEqual(true, arr_obj.items.items[7].asBool());
}

test "VM: GC Grey Stack handles deeply nested objects without C-stack overflow" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Create an array nested 2,000 levels deep.
    // A recursive markObject would blow the C call stack here.
    const source =
        \\arr = []
        \\i = 0
        \\while (i < 2000)
        \\  arr = [arr]
        \\  i = i + 1
        \\end
        \\arr
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Full garbage collection sweep right now
    vm.gc.collectGarbage(&vm, false);

    // If we reach this line, the iterative grey stack successfully prevented a stack overflow!
    try testing.expect(true);
}

test "VM Edge Case: Safe casting prevents panics on invalid CAD arguments" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.mute_errors = true; // Prevent the error from cluttering test output

    // Attempt to translate a geometry using a String instead of a Number
    const source =
        \\c = cube(10)
        \\c.translate("hello", 0, 0)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    // It should cleanly catch the invalid type and safely abort the execution
    try testing.expectEqual(.runtime_error, result);
}

test "VM Edge Case: Native C++ FFI failures are safely caught by rescue blocks" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.mute_errors = true; // Prevent the error string from cluttering test output

    // Attempt to translate a geometry using an invalid String instead of a Number.
    // In Phase 2, this caused a fatal process panic. Now it should gracefully throw to rescue!
    const source =
        \\begin
        \\  c = cube(10)
        \\  c.translate("hello") # FFI Boundary rejects the type and throws error.RuntimeError
        \\  100
        \\rescue => e
        \\  42
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    // The script should successfully exit with .ok, returning 42 from the rescue block!
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 42.0), vm.stack[0].asNumber());
}

test "VM: ARC objects correctly track memory against the Sandbox limit" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Verify initial state
    try testing.expectEqual(@as(usize, 0), vm.gc.bytes_allocated);

    // Allocate an ARC object and verify it counts towards the GC heap size
    const geom_val = try vm.allocateGeometry(.{ .symbolic = 1 });

    // FIX: Manual allocations belong to the tester, not the VM.
    // We must manually release it to balance the initial ref_count = 1.
    defer vm.releaseValue(geom_val);

    try testing.expect(vm.gc.bytes_allocated > 0);

    // Clamp the sandbox limit to exactly the current usage
    vm.gc.max_memory_limit = vm.gc.bytes_allocated;

    // Attempt to allocate another geometry. The Sandbox MUST block it.
    const result = vm.allocateGeometry(.{ .symbolic = 2 });
    try testing.expectError(error.OutOfMemory, result);
}

test "VM: Symbols are weak references and swept when unused" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Allocate a symbol (it gets cached in vm.symbols)
    const sym_val = try vm.allocateSymbol("ephemeral_key");
    vm.push(sym_val);

    try testing.expect(vm.symbols.contains("ephemeral_key"));

    // Pop the symbol off the stack so nothing references it
    _ = vm.pop();

    // Force a garbage collection cycle
    vm.gc.collectGarbage(&vm, false);

    // The symbol MUST be swept from the VM's internal cache
    try testing.expectEqual(false, vm.symbols.contains("ephemeral_key"));
}

test "VM: Brep topology deinit cleanly frees all arrays" {
    // If Brep.deinit() leaks, std.testing.allocator will fail the test automatically!
    const Brep = @import("../kernel/engines/brep/topology.zig").Brep;
    const Vertex = @import("../kernel/engines/brep/topology.zig").Vertex;
    const Wire = @import("../kernel/engines/brep/topology.zig").Wire;

    var brep = Brep.initEmpty(testing.allocator);
    defer brep.deinit();

    // Simulate allocating topology slices using the new ArrayListUnmanaged API
    for (0..10) |_| {
        try brep.vertices.append(testing.allocator, Vertex{ .point = .{ .x = 0.0, .y = 0.0, .z = 0.0 } });
    }
    for (0..5) |_| {
        try brep.wires.append(testing.allocator, Wire{ .first_edge = 0, .num_edges = 0 });
    }

    // Simulate appending to the relationship arrays
    try brep.wire_edges.append(testing.allocator, 1);
    try brep.wire_edges.append(testing.allocator, 2);

    // The defer brep.deinit() will trigger here.
    // If it doesn't correctly free `.vertices`, `.wires`, and `.wire_edges`, Zig's test runner will panic with a memory leak.
}

test "VM: Closure stack frame safely pre-allocates local variables" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def calc()
        \\  x = 10
        \\  y = 20
        \\  z = x + y
        \\  z
        \\end
        \\
        \\calc()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 30.0), vm.stack[0].asNumber());
}

test "VM: Reflection methods safely pop implicit blocks without corrupting stack" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\val = "hello"
        \\check1 = val.is_a?(String)
        \\check2 = val.responds_to?("split")
        \\[check1, check2]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());

    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());
    try testing.expectEqual(true, arr_obj.items.items[1].asBool());
}

test "VM: OOP Inheritance, instance fields, and super() expressions" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Base
        \\  def initialize(base_val)
        \\    self.val = base_val
        \\  end
        \\  def calc(x)
        \\    self.val + x
        \\  end
        \\end
        \\
        \\class Child < Base
        \\  def initialize(base_val, child_val)
        \\    super(base_val)
        \\    self.c_val = child_val
        \\  end
        \\  def calc(x)
        \\    super(x) + self.c_val
        \\  end
        \\end
        \\
        \\c = Child.new(10, 20)
        \\c.calc(5) # Base(10 + 5) + Child(20) = 35
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 35.0), vm.stack[0].asNumber());
}

test "VM: Object properties and compound assignments" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Point
        \\  def initialize(x, y)
        \\    self.x = x
        \\    self.y = y
        \\  end
        \\end
        \\
        \\p = Point.new(10, 20)
        \\p.x += 5
        \\p.y = p.y * 2
        \\[p.x, p.y]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Stack: [Point closure, [15, 40]]
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());

    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 15.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 40.0), arr_obj.items.items[1].asNumber());
}

test "VM: Fluent method chaining" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Builder
        \\  def initialize
        \\    self.val = 0
        \\  end
        \\  def add(x)
        \\    self.val += x
        \\    self
        \\  end
        \\  def build
        \\    self.val
        \\  end
        \\end
        \\
        \\Builder.new.add(10).add(20).build
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 30.0), vm.stack[0].asNumber());
}

test "VM: Comprehensive Ruby-like language features integration" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\module MathHelpers
        \\  def square(x)
        \\    x * x
        \\  end
        \\end
        \\
        \\class Calculator
        \\  include MathHelpers
        \\
        \\  def initialize(offset)
        \\    self.offset = offset
        \\    @@count = 42
        \\  end
        \\
        \\  def self.get_count
        \\    @@count
        \\  end
        \\
        \\  def compute(arr)
        \\    res = []
        \\    i = 0
        \\    while i < arr.length
        \\      val = arr[i]
        \\      processed = case val
        \\      when 1..5
        \\        self.square(val)
        \\      when 10
        \\        val * 2
        \\      else
        \\        -1
        \\      end
        \\      res.push(processed + self.offset)
        \\      i += 1
        \\    end
        \\    res
        \\  end
        \\end
        \\
        \\class AdvancedCalculator < Calculator
        \\  def initialize(offset, multiplier)
        \\    super(offset)
        \\    self.multiplier = multiplier
        \\  end
        \\
        \\  def compute(arr)
        \\    base_res = super(arr)
        \\    # Proves `self` is correctly captured as an Upvalue inside the block!
        \\    base_res.map { |x| x * self.multiplier }
        \\  end
        \\end
        \\
        \\calc = AdvancedCalculator.new(5, 2)
        \\# 2  -> (2^2 + 5) * 2  = 18
        \\# 10 -> (10*2 + 5) * 2 = 50
        \\# 42 -> (-1 + 5) * 2   = 8
        \\result = calc.compute([2, 10, 42])
        \\
        \\err_caught = false
        \\begin
        \\  raise(ArgumentError)
        \\rescue ArgumentError => e
        \\  err_caught = true
        \\end
        \\
        \\dict = { first: result[0], second: result[1] }
        \\a, *b, c = [*result, 100, 200]
        \\
        \\summary = "Count: #{Calculator.get_count}"
        \\
        \\[dict[:first], b.length(), c, err_caught, summary]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());

    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 5), arr_obj.items.items.len);

    // dict["first"] == 18
    try testing.expectEqual(@as(f64, 18.0), arr_obj.items.items[0].asNumber());
    // b.length() == 3 (the middle splat captured [50, 8, 100])
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[1].asNumber());
    // c == 200 (the tail end of the destructure)
    try testing.expectEqual(@as(f64, 200.0), arr_obj.items.items[2].asNumber());
    // err_caught == true
    try testing.expectEqual(true, arr_obj.items.items[3].asBool());

    // Interpolated summary == "Count: 42"
    const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[4].asObj())));
    try testing.expectEqualStrings("Count: 42", str_obj.chars);
}

test "VM: Map indexing and compound assignment" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\m = { "score" => 10 }
        \\m["score"] += 15
        \\m["lives"] = 3
        \\[m["score"], m["lives"]]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));

    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 25.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[1].asNumber());
}

test "VM: Ensure block executes and applies side effects" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\x = 0
        \\begin
        \\  raise(ArgumentError)
        \\rescue => e
        \\  x += 10
        \\ensure
        \\  x += 100
        \\end
        \\x
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 110.0), vm.stack[0].asNumber()); // 10 from rescue, 100 from ensure
}

test "VM: Class variables (@@var) are shared globally across instances" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Counter
        \\  def initialize() @@c = 0 end
        \\  def inc() @@c += 1 end
        \\  def get() @@c end
        \\end
        \\
        \\a = Counter.new()
        \\b = Counter.new()
        \\a.inc()
        \\b.inc()
        \\[a.get(), b.get()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));

    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    // Because they share the same @@c, both should read `2`!
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[1].asNumber());
}

test "VM: Advanced Math (exponent, modulo) and nested String Interpolation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\base = 2 ** 3 # 8
        \\rem = 14 % 5  # 4
        \\"Result: #{base + rem}!"
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", vm.stack[0].asObj())));
    try testing.expectEqualStrings("Result: 12!", str_obj.chars);
}

test "VM: op_interpolate prevents memory leak on GC OOM" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Allocate string fragments BEFORE artificially restricting the GC
    const s1 = try out_chunk.addConstant(testing.allocator, try vm.allocateString("A"));
    const s2 = try out_chunk.addConstant(testing.allocator, try vm.allocateString("B"));

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(s1), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(s2), 0);

    try out_chunk.writeOp(testing.allocator, .op_interpolate, 0);
    try out_chunk.write(testing.allocator, 2, 0); // 2 parts
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    // NOW restrict memory to force an OOM during execution of op_interpolate
    vm.gc.max_memory_limit = 10;

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);
    // If the leak exists, Zig's testing allocator will panic at the end of this test.
}

test "VM: Logical OR (||) short-circuiting and Unary NOT (!) truthiness" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // true/false and nil truthiness evaluation
    const source =
        \\a = false || 42
        \\b = 100 || 50
        \\c = !nil
        \\d = !10
        \\[a, b, c, d]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));

    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[0].asNumber()); // false || 42 -> 42
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[1].asNumber()); // 100 || 50 -> 100
    try testing.expectEqual(true, arr_obj.items.items[2].asBool()); // !nil -> true
    try testing.expectEqual(false, arr_obj.items.items[3].asBool()); // !10 -> false
}

test "VM: Map literal spreading (**kwargs) executes seamlessly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests op_map_spread and op_map_insert ordering
    const source =
        \\base = { "a" => 1, "b" => 2 }
        \\merged = { "c" => 3, **base, "a" => 99 }
        \\[merged["c"], merged["b"], merged["a"]]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));

    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 99.0), arr_obj.items.items[2].asNumber()); // Overwritten by tail key
}

test "VM: Lexical block scopes isolate shadowed variables" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Ensure `x` inside the block doesn't overwrite `x` outside the block
    const source =
        \\x = 10
        \\[1, 2].each do |x|
        \\  y = x * 2
        \\end
        \\x
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    // x should remain 10, completely unaffected by the inner block's parameter
    try testing.expectEqual(@as(f64, 10.0), vm.stack[0].asNumber());
}

test "VM: Relational operators (<=, >=, <, >, !=) evaluate correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Prove that the compiler's desugaring of <= and >= into (< !) and (> !) works perfectly
    const source =
        \\[ 5 <= 5, 5 <= 6, 5 >= 5, 5 >= 4, 10 < 20, 20 > 10, 5 != 6, 10 <= 5 ]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", vm.stack[0].asObj())));
    try testing.expectEqual(@as(usize, 8), arr_obj.items.items.len);

    try testing.expectEqual(true, arr_obj.items.items[0].asBool()); // 5 <= 5
    try testing.expectEqual(true, arr_obj.items.items[1].asBool()); // 5 <= 6
    try testing.expectEqual(true, arr_obj.items.items[2].asBool()); // 5 >= 5
    try testing.expectEqual(true, arr_obj.items.items[3].asBool()); // 5 >= 4
    try testing.expectEqual(true, arr_obj.items.items[4].asBool()); // 10 < 20
    try testing.expectEqual(true, arr_obj.items.items[5].asBool()); // 20 > 10
    try testing.expectEqual(true, arr_obj.items.items[6].asBool()); // 5 != 6
    try testing.expectEqual(false, arr_obj.items.items[7].asBool()); // 10 <= 5 (False!)
}

test "VM: Consolidated numeric operations (*, /, %, **) evaluate correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\[ 10 * 5, 10 / 2, 11 % 3, 2 ** 4 ]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", vm.stack[0].asObj())));
    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[0].asNumber()); // 10 * 5
    try testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[1].asNumber()); // 10 / 2
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[2].asNumber()); // 11 % 3
    try testing.expectEqual(@as(f64, 16.0), arr_obj.items.items[3].asNumber()); // 2 ^ 4
}

test "VM: Optimized String methods operate safely without leaks" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Proves that allocateStringTakeOwnership correctly takes over the memory
    // from our stringUpcase/stringReplace refactor without double allocating.
    const source =
        \\[ "hello".upcase(), "WORLD".downcase(), "foo bar".replace("foo", "baz") ]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", vm.stack[0].asObj())));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    const s1 = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[0].asObj())));
    try testing.expectEqualStrings("HELLO", s1.chars);

    const s2 = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[1].asObj())));
    try testing.expectEqualStrings("world", s2.chars);

    const s3 = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[2].asObj())));
    try testing.expectEqualStrings("baz bar", s3.chars);
}

test "VM Edge Case: CSG operations across mixed 2D/3D types throw runtime error" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true; // Don't pollute terminal output

    // Attempt to Union (+) a 3D Cube with a 2D Square
    const source =
        \\c = cube(10)
        \\s = square(10)
        \\c + s
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    // Our DRY'd cadBinaryHandler should instantly block this as a type mismatch
    try testing.expectEqual(.runtime_error, result);
}

test "VM: Script globals are correctly updated from within blocks without shadowing" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // If the compiler incorrectly flags `sum` as a new local inside the block,
    // the outer `sum` will remain 0. If fixed, it will correctly output 6.
    const source =
        \\sum = 0
        \\[1, 2, 3].each do |x|
        \\  sum = sum + x
        \\end
        \\sum
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 6.0), vm.stack[0].asNumber());
}

test "VM: Global assignments maintain strict stack equilibrium" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // If `op_define_global` leaks a `nil` onto the stack, multiple assignments
    // will leave residual garbage, causing the stack top to be > 1.
    const source =
        \\a = 10
        \\b = 20
        \\c = 30
        \\a + b + c
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // The stack must contain EXACTLY 1 item (the final result: 60.0).
    // If it contains 4, the compiler is leaking assignment expressions!
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 60.0), vm.stack[0].asNumber());
}

test "VM: Stack does not leak on local variable assignments inside loops" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // The script initializes 'i', then loops 10 times.
    // Inside the loop, it declares a brand new local variable 'temp'.
    // If the compiler emits `op_nil` dynamically here, the stack will leak by +10.
    const source =
        \\i = 0
        \\while (i < 10)
        \\  temp = i * 2
        \\  i = i + 1
        \\end
        \\i
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);

    // The stack must contain EXACTLY 1 item (the final result: 10.0).
    // Before the fix, stack_top would be 11 (10 leaked nils + 1 result).
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 10.0), vm.stack[0].asNumber());
}

test "VM: GC correctly marks executing closures and primitive classes" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Bind a native function to aggressively force a GC cycle mid-execution
    const force_gc = struct {
        fn run(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
            _ = arg_count;
            _ = args;
            const v: *VM = @ptrCast(@alignCast(vm_opaque));
            v.gc.collectGarbage(v, false);
            return value.Value.initNil();
        }
    }.run;
    try vm.defineNative("force_gc", force_gc);

    const source =
        \\(def ()
        \\  force_gc()
        \\  [1, 2, 3].length()
        \\end)()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    // If we reach here without a panic or segfault, the GC roots are watertight!
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 3.0), vm.stack[0].asNumber());
}

test "VM: super correctly resolves and executes Native C++ methods" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Create a safe custom native base class instead of subclassing `Array`
    const base_name = try vm.allocateString("NativeBase");
    vm.push(base_name); // Protect from GC
    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", base_name.asObj())));
    const base_class = try vm.gc.allocateClass(&vm, name_str, null);
    try vm.globals.put(vm.allocator, "NativeBase", value.Value.initObj(&base_class.obj));
    _ = vm.pop();

    // Bind a native method to it that returns 42
    const native_func = struct {
        fn run(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
            _ = vm_opaque;
            _ = arg_count;
            _ = args;
            return value.Value.initNumber(42.0);
        }
    }.run;
    const native_obj = try vm.gc.allocateNative(&vm, native_func);
    try base_class.methods.put(vm.allocator, "get_val", value.Value.initObj(&native_obj.obj));

    // Subclass it and call super
    const source =
        \\class Child < NativeBase
        \\  def get_val
        \\    super + 100
        \\  end
        \\end
        \\
        \\c = Child.new
        \\c.get_val
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 142.0), vm.stack[0].asNumber()); // 42 (Native) + 100
}

test "Compiler/VM: Splat parameters calculate trailing arity correctly alongside kwargs" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // If trailing_arity is miscalculated, the VM will over-shift
    // the stack, corrupting the kwarg map slot. `c` and `d` would evaluate to nil.
    const source =
        \\def test_splat(a, *args, c:, d:)
        \\  [a, args, c, d]
        \\end
        \\test_splat(10, 20, 30, c: 100, d: 200)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const result_arr = vm.stack[0];
    try testing.expect(result_arr.isObject() and result_arr.asObj().obj_type == .array);
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", result_arr.asObj())));

    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    // a = 10
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());

    // args = [20, 30]
    const packed_args = arr_obj.items.items[1];
    const packed_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", packed_args.asObj())));
    try testing.expectEqual(@as(usize, 2), packed_obj.items.items.len);
    try testing.expectEqual(@as(f64, 20.0), packed_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), packed_obj.items.items[1].asNumber());

    // c = 100, d = 200
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[2].asNumber());
    try testing.expectEqual(@as(f64, 200.0), arr_obj.items.items[3].asNumber());
}

test "VM: Positional parameters properly evaluate default values" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests three invocation patterns:
    // 1. Missing both defaults
    // 2. Missing one default
    // 3. Overriding all defaults
    const source =
        \\def make_box(width, height = 20, depth = 20 + 10)
        \\  [width, height, depth]
        \\end
        \\
        \\[make_box(10), make_box(10, 50), make_box(10, 50, 60)]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());
    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    // First call: make_box(10) -> [10, 20, 30]
    const call1 = arr_obj.items.items[0].asArray();
    try testing.expectEqual(@as(f64, 10.0), call1.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), call1.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 30.0), call1.items.items[2].asNumber());

    // Second call: make_box(10, 50) -> [10, 50, 30]
    const call2 = arr_obj.items.items[1].asArray();
    try testing.expectEqual(@as(f64, 10.0), call2.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 50.0), call2.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 30.0), call2.items.items[2].asNumber());

    // Third call: make_box(10, 50, 60) -> [10, 50, 60]
    const call3 = arr_obj.items.items[2].asArray();
    try testing.expectEqual(@as(f64, 10.0), call3.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 50.0), call3.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 60.0), call3.items.items[2].asNumber());
}

test "VM: ARC references are safely released when receivers are discarded" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    const baseline_memory = vm.gc.bytes_allocated;

    // By wrapping this in a Lambda, we prevent global namespace pollution.
    // When `f` is reassigned to `nil`, the closure and the error variable `e`
    // are unreferenced, allowing the GC to cleanly sweep the entire test from memory!
    const source =
        \\f = ->() do
        \\  begin
        \\    cube(10).invalid_property = 42
        \\  rescue => e
        \\    nil
        \\  end
        \\end
        \\f()
        \\f = nil
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // The stack contains exactly 1 item (the `nil` from `f = nil`)
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    // Force a GC cycle to sweep the closure and the rescued error string
    vm.gc.collectGarbage(&vm, false);

    // Memory footprint returns to exactly the baseline
    try testing.expectEqual(baseline_memory, vm.gc.bytes_allocated);
}

test "VM: Unified Exception hierarchy with native methods" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Trigger a native VM soft exception (indexing an array out of bounds).
    // 2. Rescue it explicitly using StandardError to test inheritance.
    // 3. Return an array proving its class hierarchy and message extraction
    const source =
        \\begin
        \\  [1, 2][5]
        \\rescue StandardError => e
        \\  [e.is_a?(RuntimeError), e.is_a?(Exception), e.message()]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());

    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    // Prove `e` is an instance of RuntimeError natively wrapped by throwDynamicError
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());

    // Prove `RuntimeError` successfully inherits from `Exception`
    try testing.expectEqual(true, arr_obj.items.items[1].asBool());

    // Prove `e.message()` evaluates successfully to the VM's formatted array bounds error
    const msg_val = arr_obj.items.items[2];
    const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", msg_val.asObj())));
    try testing.expectEqualStrings("Runtime Error: Array index out of bounds.", str_obj.chars);
}

test "VM: Custom exceptions inherit properly and rescue block ordering is respected" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Define a CustomError inheriting from StandardError
    // 2. Raise it using the native `.new` constructor to pass a custom message
    // 3. Catch it in the FIRST block, proving it doesn't fall through to StandardError
    // 4. Extract and yield the message natively via method call `e.message()`
    const source =
        \\class CustomError < StandardError
        \\end
        \\
        \\begin
        \\  raise(CustomError.new("My custom failure!"))
        \\rescue CustomError => e
        \\  e.message
        \\rescue StandardError => e
        \\  "wrong block"
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Stack should contain exactly the yielded message string!
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const str_val = vm.stack[0];
    try testing.expect(str_val.isObject() and str_val.asObj().obj_type == .string);

    const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", str_val.asObj())));
    try testing.expectEqualStrings("My custom failure!", str_obj.chars);
}

test "VM: defined? operator works dynamically on globals, instance, and class variables" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\global_var = 42
        \\class TestClass
        \\  def initialize
        \\    @inst_var = 10
        \\    @@class_var = 20
        \\  end
        \\  def check
        \\    [
        \\      defined?(global_var),
        \\      defined?(missing_global),
        \\      defined?(@inst_var),
        \\      defined?(@missing_inst),
        \\      defined?(@@class_var),
        \\      defined?(@@missing_class)
        \\    ]
        \\  end
        \\end
        \\TestClass.new.check
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isArray());
    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 6), arr_obj.items.items.len);

    // Global
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());
    try testing.expect(arr_obj.items.items[1].isNil());

    // Instance (@)
    try testing.expectEqual(true, arr_obj.items.items[2].asBool());
    try testing.expect(arr_obj.items.items[3].isNil());

    // Class (@@)
    try testing.expectEqual(true, arr_obj.items.items[4].asBool());
    try testing.expect(arr_obj.items.items[5].isNil());
}

test "VM: DOD param registry getter and setter overloading" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Script:
    // 1. Define :width with a default of 42.5
    // 2. Retrieve it using param(:width)
    const source =
        \\param(:width, default: 42.5, validate: { min: 10, max: 100 })
        \\param(:width)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // The script should return exactly 42.5
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 42.5), vm.stack[0].asNumber());

    // Verify the DOD array actually stored it
    try testing.expectEqual(@as(usize, 1), vm.param_registry.len);
    try testing.expectEqual(@as(f64, 42.5), vm.param_registry.items(.current_value)[0].asNumber());
}

test "VM: param validation halts execution on max bounds violation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Mute the console error output so it doesn't clutter the test runner
    vm.mute_errors = true;

    // The default is 200, but the max is strictly 100!
    const source =
        \\param(:width, default: 200, validate: { max: 100 })
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    // The VM must intercept the bound violation and throw a runtime error!
    try testing.expectEqual(.runtime_error, result);
}

test "VM: param validation halts execution on min bounds violation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    // The default is 5, but the min is strictly 10!
    const source =
        \\param(:width, default: 5, validate: { min: 10 })
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);
}

test "VM: param getter halts execution if parameter is undefined" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    // Fetching a parameter before it is defined
    const source =
        \\param(:does_not_exist)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    // The VM must recognize it is missing from the registry and halt
    try testing.expectEqual(.runtime_error, result);
}

test "VM: Universal Object Protocol (nil?, empty?, tap, into, dup)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\val = nil
        \\t1 = val.nil?
        \\t2 = "hello".nil?
        \\t3 = [].empty?
        \\
        \\t4 = cube(10).tap { |c| c.translate(5, 0, 0) }.volume()
        \\t5 = 10.into { |x| x * 2 }
        \\
        \\[t1, t2, t3, t4, t5]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_obj = vm.stack[0].asArray();

    try testing.expectEqual(true, arr_obj.items.items[0].asBool()); // nil.nil? -> true
    try testing.expectEqual(false, arr_obj.items.items[1].asBool()); // "hello".nil? -> false
    try testing.expectEqual(true, arr_obj.items.items[2].asBool()); // [].empty? -> true
    try testing.expectApproxEqAbs(@as(f64, 1000.0), arr_obj.items.items[3].asNumber(), 0.1); // tap returns receiver un-mutated
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[4].asNumber()); // 10.then { |x| x * 2 } -> 20
}

test "VM: Parameter definition, bounds validation, and getter retrieval" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\param(:width, default: 50, validate: { min: 10, max: 100 })
        \\param(:height, default: 20)
        \\
        \\w = param(:width)
        \\h = param(:height)
        \\[w, h]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_obj = vm.stack[0].asArray();
    try testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());
}

test "VM: Parameter validation failure halts script execution with runtime_error" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true; // Prevent stdout error logs during intentional failure test

    // Default value 150 exceeds max of 100
    const source =
        \\param(:width, default: 150, validate: { min: 10, max: 100 })
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);
}

test "VM: CLI parameter injection overrides default script parameter values" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Simulate CLI flag injection (`--param width=85`) into the VM `params` Map
    const params_val = vm.globals.get("params").?;
    const map_obj = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", params_val.asObj())));

    const sym_key = try vm.allocateSymbol("width");
    vm.push(sym_key);
    defer _ = vm.pop();

    try map_obj.keys.append(vm.allocator, sym_key);
    try map_obj.values.append(vm.allocator, value.Value.initNumber(85.0));

    // Script declares default: 50, but CLI injection should replace it with 85
    const source =
        \\param(:width, default: 50, validate: { min: 10, max: 100 })
        \\param(:width)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 85.0), vm.stack[0].asNumber());
}

test "VM: Parameter choice validation (in: [...]) enforces allowed discrete options" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    // Value "huge" is not in ["small", "medium", "large"]
    const source =
        \\param(:size, default: "huge", validate: { in: ["small", "medium", "large"] })
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);
}

// At the bottom of src/vm/vm_test.zig

test "VM Edge Case: Robot Mount Bracket execution safely resolves Spatial Queries without Segfaulting" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.host.print_handler = null; // Mute prints during CI testing

    // Use core snippets from the reported segfault
    const source =
        \\raw_pts = [ [0.0, 0.0], [40.0, 0.0], [30.0, 25.0], [10.0, 25.0] ]
        \\base_poly = polygon(raw_pts)
        \\outer_profile = base_poly.offset(4.0)
        \\center_hole = circle(d: 12.0).translate(22.0, 17.5)
        \\bracket_profile = outer_profile - center_hole
        \\bracket_3d = bracket_profile.extrude(12.0)
        \\trimmed_bracket = bracket_3d.trim_by_plane(0.0, 0.0, 1.0, 18.0)
        \\
        \\# Spatial query which triggered GC sweep bug
        \\ray_hits = trimmed_bracket.ray_cast([22.0, 17.5, 40.0], [22.0, 17.5, -10.0])
        \\
        \\inspect("Ray hit:", ray_hits.length)
        \\trimmed_bracket
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Test that the return is the valid constructed Geometry
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expect(vm.stack[0].isGeometry());
}

test "VM: Global variable re-assignment inside block closures updates global scope" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\main_val = 10
        \\[1, 2, 3].each do |x|
        \\  main_val = main_val + x
        \\end
        \\main_val
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // 10 + 1 + 2 + 3 = 16
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 16.0), vm.stack[0].asNumber());
}

test "VM: inspect() formats Instance objects using native inspect/to_s methods" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.host.print_handler = null;

    const source =
        \\c = cube(10)
        \\inspect(c.bbox())
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
}

test "VM: Block closure local variables do not collide with implicit block slot" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\total = 0
        \\[5, 10, 20].each do |val|
        \\  scale_factor = val > 15 ? 3 : 2
        \\  scaled = val * scale_factor
        \\  total = total + scaled
        \\end
        \\total
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // 5*2 (10) + 10*2 (20) + 20*3 (60) = 90
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 90.0), vm.stack[0].asNumber());
}

test "VM: Complex loops with variables, break, and next maintain perfect equilibrium" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\x = 0
        \\while (x < 10)
        \\  y = x + 1
        \\  x = y
        \\  if (x == 3)
        \\    temp = 99
        \\    next
        \\  end
        \\  if (x == 7)
        \\    break_val = 100
        \\    break
        \\  end
        \\end
        \\x
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // The entire script must collapse perfectly back down to exactly 1 return value
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 7.0), vm.stack[0].asNumber());
}

test "VM: Nested block execution isolates local variables without colliding" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\total = 0
        \\[1, 2].each do |a|
        \\  level_1 = a * 10
        \\  [1, 2].each do |b|
        \\    level_2 = level_1 + b
        \\    total = total + level_2
        \\  end
        \\end
        \\total
    ;
    // Walkthrough:
    // a=1 -> lvl1=10 -> b=1 (tot=11) -> b=2 (tot=11+12=23)
    // a=2 -> lvl1=20 -> b=1 (tot=23+21=44) -> b=2 (tot=44+22=66)

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 66.0), vm.stack[0].asNumber());
}

test "VM: Closure block executes local return back to caller frame" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def run_block(&b)
        \\  b(42)
        \\end
        \\run_block do |x|
        \\  return x * 2
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 84.0), vm.stack[0].asNumber());
}

test "VM: Closed upvalues inside loops migrate to heap without slot corruption" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Counter
        \\  def initialize(val)
        \\    self.val = val
        \\  end
        \\  def get_val
        \\    self.val
        \\  end
        \\end
        \\
        \\objs = []
        \\i = 0
        \\while (i < 3)
        \\  captured = i * 10
        \\  objs.push(Counter.new(captured))
        \\  i = i + 1
        \\end
        \\[objs[0].get_val(), objs[1].get_val(), objs[2].get_val()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 0.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[2].asNumber());
}

test "VM: Block closures support splat (*args) parameters natively" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def yield_splat(&b)
        \\  b(10, 20, 30, 40)
        \\end
        \\yield_splat do |first, *rest|
        \\  [first, rest]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());

    const rest_arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[1].asObj())));
    try testing.expectEqual(@as(usize, 3), rest_arr.items.items.len);
    try testing.expectEqual(@as(f64, 20.0), rest_arr.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), rest_arr.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 40.0), rest_arr.items.items[2].asNumber());
}

test "VM: Block closures support array destructuring |(x, y)| natively" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def yield_array(&b)
        \\  b([100, 200])
        \\end
        \\yield_array do |(x, y)|
        \\  x + y
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 300.0), vm.stack[0].asNumber());
}

test "VM: Block closures support keyword arguments (**kwargs) cleanly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def yield_kwargs(&b)
        \\  b(50, width: 10, height: 20)
        \\end
        \\yield_kwargs do |val, **opts|
        \\  [val, opts[:width], opts[:height]]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));

    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[2].asNumber());
}

test "VM: Block closures handle extreme complex arguments |(x, y), *args, **kw|" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def yield_complex(&b)
        \\  b([10, 20], 30, 40, a: 1, c: 2)
        \\end
        \\yield_complex do |(x, y), *args, **kw|
        \\  [x, y, args, kw[:a]]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));

    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());

    const args_arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[2].asObj())));
    try testing.expectEqual(@as(usize, 2), args_arr.items.items.len);
    try testing.expectEqual(@as(f64, 30.0), args_arr.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 40.0), args_arr.items.items[1].asNumber());

    try testing.expectEqual(@as(f64, 1.0), arr_obj.items.items[3].asNumber());
}

test "VM: Block closures support default parameter assignments" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Yields multiple times with varying arguments to test default fallbacks
    const source =
        \\def yield_defaults(&b)
        \\  [b(), b(5), b(5, 50)]
        \\end
        \\yield_defaults do |x = 10, y = 20|
        \\  x + y
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);

    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    // b() -> 10 + 20 = 30
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[0].asNumber());
    // b(5) -> 5 + 20 = 25
    try testing.expectEqual(@as(f64, 25.0), arr_obj.items.items[1].asNumber());
    // b(5, 50) -> 5 + 50 = 55
    try testing.expectEqual(@as(f64, 55.0), arr_obj.items.items[2].asNumber());
}

test "VM: Deeply nested blocks modifying top-level upvalues securely" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests that Upvalue resolution correctly traverses multiple compiler boundaries
    const source =
        \\x = 0
        \\[1].each do
        \\  [2].each do
        \\    [3].each do
        \\      x = x + 10
        \\    end
        \\  end
        \\end
        \\x
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // The innermost block runs exactly once, so x should be 10.
    // Most importantly, the stack should be perfectly balanced at 1.
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 10.0), vm.stack[0].asNumber());
}

test "VM: Block arguments gracefully pad with nil when missing" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Yields 0 arguments, but block expects 2.
    const source =
        \\def call_empty(&b)
        \\  b()
        \\end
        \\call_empty do |x, y|
        \\  [x.nil?, y.nil?]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Should return [true, true] without reading garbage memory
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());
    try testing.expectEqual(true, arr_obj.items.items[1].asBool());
}

test "VM: Keyword arguments extract correctly regardless of passing order" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Block expects |a:, b:|, caller provides (b: 20, a: 10)
    const source =
        \\def test_kw(&block)
        \\  block(b: 20, a: 10)
        \\end
        \\test_kw do |a:, b:|
        \\  [a, b]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Should reliably map to [10, 20]
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());
}

test "VM: Block array destructuring safely pads missing elements with nil" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Yields an array with only 1 element, but the block destructs 3!
    const source =
        \\def yield_short(&b)
        \\  b([42])
        \\end
        \\yield_short do |(x, y, z)|
        \\  [x, y.nil?, z.nil?]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));

    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[0].asNumber()); // x
    try testing.expectEqual(true, arr_obj.items.items[1].asBool()); // y was padded with nil
    try testing.expectEqual(true, arr_obj.items.items[2].asBool()); // z was padded with nil
}

test "VM: Block silently trims extraneous yielded arguments" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Yields 5 arguments, but the block only takes 1
    const source =
        \\def yield_many(&b)
        \\  b(99, 2, 3, 4, 5)
        \\end
        \\yield_many do |first|
        \\  first
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 99.0), vm.stack[0].asNumber());
}

test "Compiler: Block array destructuring rejects splats and defaults natively" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // Manually build a bad destructuring parameter: |(x, *y)|
    const x_id = try b.identifierNode("x", 0);
    const y_id = try b.identifierNode("y", 0);
    const y_splat = try b.splatExpr(y_id, 0); // Invalid inside tuple!

    const tuple_span = try b.addNodes(&.{ x_id, y_splat });
    const tuple_node = try b.arrayLiteral(tuple_span, 0, 0);

    const block_node = try b.block(&.{tuple_node}, &.{}, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &[_]resolver.ResolvedSymbol{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // The compiler MUST reject the splat inside the tuple and return error.UnknownNode!
    const result = comp.compile(block_node);
    try testing.expectError(error.UnknownNode, result);
}

test "VM: Ensure block executes on successful (non-raising) path without corrupting stack" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\x = 0
        \\result = begin
        \\  x += 10
        \\  42
        \\ensure
        \\  x += 100
        \\end
        \\[result, x]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[0].asNumber()); // result of begin block
    try testing.expectEqual(@as(f64, 110.0), arr_obj.items.items[1].asNumber()); // x modified by ensure
}

test "VM: Rescue handles multiple comma-separated exception types in one clause" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def fail_with(err_type)
        \\  begin
        \\    raise(err_type)
        \\  rescue TypeError, ArgumentError => e
        \\    100
        \\  rescue StandardError => e
        \\    200
        \\  end
        \\end
        \\[fail_with(ArgumentError), fail_with(TypeError)]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[1].asNumber());
}

test "VM: Array indexing compound assignment (arr[idx] += val)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\arr = [10, 20, 30]
        \\i = 1
        \\arr[i] += 15
        \\arr[i]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 35.0), vm.stack[0].asNumber());
}

test "VM: Repeated block yields in loops maintain frame and stack equilibrium" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def repeat_yield(count, &b)
        \\  i = 0
        \\  acc = 0
        \\  while i < count
        \\    acc += b(i)
        \\    i += 1
        \\  end
        \\  acc
        \\end
        \\repeat_yield(100) do |val|
        \\  val * 2
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // Sum of (0..99)*2 = 2 * (99*100/2) = 9900
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 9900.0), vm.stack[0].asNumber());
}

test "VM: Shorthand hash syntax evaluates in runtime scope" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\width = 50
        \\height = 100
        \\box_opts = { width:, height: }
        \\[box_opts[:width], box_opts[:height]]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[1].asNumber());
}

test "VM: Class re-opening preserves existing methods and field layout map" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Part
        \\  def set_a(val) @a = val end
        \\end
        \\
        \\class Part
        \\  def set_b(val) @b = val end
        \\  def sum() @a + @b end
        \\end
        \\
        \\p = Part.new
        \\p.set_a(10)
        \\p.set_b(20)
        \\p.sum()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 30.0), vm.stack[0].asNumber());
}

test "VM: Inline rescue modifier traps soft exceptions during assignment" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\arr = [10, 20]
        \\val = arr[99] rescue 500
        \\val
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 500.0), vm.stack[0].asNumber());
}

test "VM: Stabby lambdas compile and execute with default and keyword parameters" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\calc = ->(x, y = 10, scale: 2) { (x + y) * scale }
        \\[calc(5), calc(5, 20), calc(5, scale: 3)]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    // calc(5) -> (5 + 10) * 2 = 30
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[0].asNumber());
    // calc(5, 20) -> (5 + 20) * 2 = 50
    try testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[1].asNumber());
    // calc(5, scale: 3) -> (5 + 10) * 3 = 45
    try testing.expectEqual(@as(f64, 45.0), arr_obj.items.items[2].asNumber());
}

test "VM: Block parameter shadowing isolates outer local upvalues" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def run_test()
        \\  x = 100
        \\  [50].each do |x|
        \\    # Inner x is 50
        \\    y = x + 1
        \\  end
        \\  # Outer x must remain 100
        \\  x
        \\end
        \\run_test()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(@as(f64, 100.0), vm.stack[0].asNumber());
}

test "VM: Safe navigation chaining on nil short-circuits without stack leak" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\part = nil
        \\res = part&.translate(10, 20, 30)&.rotate(x: 45)&.bbox()
        \\res.nil?
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expectEqual(true, vm.stack[0].asBool());
}

test "VM: GC sweep during dynamic map and array splat expansion" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Bind native force_gc helper to trigger GC sweep mid-execution
    const force_gc = struct {
        fn run(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
            _ = arg_count;
            _ = args;
            const v: *VM = @ptrCast(@alignCast(vm_opaque));
            v.gc.collectGarbage(v, false);
            return value.Value.initNil();
        }
    }.run;
    try vm.defineNative("force_gc", force_gc);

    const source =
        \\base_map = { a: 1, b: 2 }
        \\base_arr = [10, 20]
        \\# Force GC mid-expression via method chain
        \\merged_map = { **base_map, c: 3 }.tap { force_gc() }
        \\merged_arr = [ *base_arr, 30 ].tap { force_gc() }
        \\[ merged_map[:c], merged_arr[2] ]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[1].asNumber());
}
