//! VM tests of callables: blocks, closures and lambdas, upvalues, yield, and how calls pass
//! positional, splat and keyword arguments.

const std = @import("std");
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const resolver = @import("../core/resolver.zig");
const value = @import("../core/value.zig");
const kernel = @import("../kernel/kernel.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../core/document.zig").Document;
const Profiler = @import("profiler.zig").Profiler;
const geom = @import("../kernel/geometry_handle.zig");
const VM = @import("vm.zig").VM;
const InterpretResult = @import("vm.zig").InterpretResult;
const ErrorKind = @import("error_kind.zig").ErrorKind;
const support = @import("../test_support.zig");
const helpers = @import("vm_test_helpers.zig");
const executeAndAssertStack = helpers.executeAndAssertStack;

test "VM: Closures correctly capture and return upvalues" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var closure_chunk = try testing.allocator.create(chunk.Chunk);
    closure_chunk.* = chunk.Chunk.init();
    defer {
        closure_chunk.free(testing.allocator);
        testing.allocator.destroy(closure_chunk);
    }

    try closure_chunk.writeOp(testing.allocator, .op_get_upvalue, 0);
    try closure_chunk.write(testing.allocator, 0, 0); // upvalue index 0
    try closure_chunk.writeOp(testing.allocator, .op_return, 0);
    closure_chunk.max_stack_slots = 2;

    const func = try vm.gc.allocateFunction(&vm);
    func.chunk = closure_chunk;
    func.owns_chunk = false;
    func.upvalue_count = 1;
    func.arity = 0;

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(testing.allocator);
    // Built by hand, so registered as the compiler registers its chunks: under -Dgc-stress the
    // values it holds were swept before the run began.
    try vm.gc.trackChunk(&main_chunk);

    const const_42 = try main_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));
    try main_chunk.writeOp(testing.allocator, .op_constant, 0);
    try main_chunk.write(testing.allocator, @intCast(const_42), 0);
    // Store it in local slot 1, the variable the closure captures
    try main_chunk.writeOp(testing.allocator, .op_set_local, 0);
    try main_chunk.write(testing.allocator, 1, 0);
    try main_chunk.writeOp(testing.allocator, .op_pop, 0);

    const const_func = try main_chunk.addConstant(testing.allocator, value.Value.initObj(&func.obj));
    try main_chunk.writeOp(testing.allocator, .op_closure, 0);
    try main_chunk.write(testing.allocator, @intCast(const_func), 0);

    try main_chunk.write(testing.allocator, 1, 0); // is_local flag
    try main_chunk.write(testing.allocator, 0, 0); // index high byte (0)
    try main_chunk.write(testing.allocator, 1, 0); // index low byte (1)

    try main_chunk.writeOp(testing.allocator, .op_call, 0);
    try main_chunk.write(testing.allocator, 0, 0); // 0 arguments
    try main_chunk.write(testing.allocator, 0, 0); // CallFlags
    try main_chunk.writeOp(testing.allocator, .op_return, 0);
    main_chunk.max_stack_slots = 4;
    main_chunk.local_count = 2; // slot 0: the script closure, slot 1: the captured 42

    const final_val = try executeAndAssertStack(&vm, &main_chunk, 1);
    try testing.expect(final_val.isNumber());
    try testing.expectEqual(@as(f64, 42.0), final_val.asNumber());
}

test "VM: executes Array.map with functional closure block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const one = try b.number("1", 0);
    const two = try b.number("2", 0);
    const three = try b.number("3", 0);
    const arr_span = try b.addNodes(&.{ one, two, three });
    const arr_node = try b.arrayLiteral(arr_span, 0, 0);

    const param_x = try b.identifierNode("x", 0);
    const get_x = try b.identifierNode("x", 0);
    const two_mul = try b.number("2", 0);
    const mult_node = try b.binary(.multiply, get_x, two_mul, 0);
    const block_node = try b.block(&.{param_x}, &.{mult_node}, 0, 0);

    const map_str = try b.intern("map");
    const empty_args = try b.addNamedArgs(&.{});
    const map_call = try b.methodCall(arr_node, map_str, empty_args, block_node, false, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @backingInt(map_call) + 1);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(map_call);

    const final_arr = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(final_arr.isObject());
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", final_arr.asObj()));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 4.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 6.0), arr_obj.items.items[2].asNumber());
}

test "VM: Native yield instruction seamlessly calls implicitly passed block" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // The main script's chunk, registered and given each function as it is made: built by
    // hand, the functions were swept before the run began under -Dgc-stress.
    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(testing.allocator);
    try vm.gc.trackChunk(&main_chunk);

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
    block_func.local_count = 2; // slot 0: the closure, slot 1: x
    const b_const = try main_chunk.addConstant(testing.allocator, value.Value.initObj(&block_func.obj));

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
    try parent_chunk.write(testing.allocator, 0, 0); // CallFlags
    try parent_chunk.writeOp(testing.allocator, .op_return, 0);
    parent_chunk.max_stack_slots = 5;

    const parent_func = try vm.gc.allocateFunction(&vm);
    parent_func.chunk = parent_chunk;
    parent_func.owns_chunk = false;
    parent_func.arity = 0; // Expects 0 positional args
    parent_func.is_method = true; // a def: yield reads its own block slot
    const p_const = try main_chunk.addConstant(testing.allocator, value.Value.initObj(&parent_func.obj));

    // 3. Main script: do_yield() { |x| x * 2 }

    try main_chunk.writeOp(testing.allocator, .op_closure, 0);
    try main_chunk.write(testing.allocator, @intCast(p_const), 0);

    try main_chunk.writeOp(testing.allocator, .op_closure, 0);
    try main_chunk.write(testing.allocator, @intCast(b_const), 0);

    // Call Parent with 1 argument: the block, flagged as such
    try main_chunk.writeOp(testing.allocator, .op_call, 0);
    try main_chunk.write(testing.allocator, 1, 0);
    try main_chunk.write(testing.allocator, @bitCast(chunk.CallFlags{ .has_block = true }), 0);
    try main_chunk.writeOp(testing.allocator, .op_return, 0);
    main_chunk.max_stack_slots = 5;

    const res = try executeAndAssertStack(&vm, &main_chunk, 1);

    // 21 * 2 = 42
    try testing.expectEqual(@as(f64, 42.0), res.asNumber());
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
    comp.is_method = true; // both intrinsics are only valid inside a def
    try comp.compile(bg_call);
    try comp.compile(yield_call);

    // Verify block_given? compiled to exactly one byte!
    try testing.expectEqual(chunk.OpCode.op_block_given, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[0])));

    // Skip op_return (1), then op_constant (2), index (3), op_yield (4)
    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_yield, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[4])));
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
    const body = try b.createNode(.identifier, 0, @backingInt(args_id));
    const def_node = try b.defStmt(func_name, params_span, body, false, 0, false, 0);

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

    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    // Default all nodes to local (so parameters inside the function resolve correctly)
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, 100);
    // Force the function definition to be global so the methodCall explicitly finds it
    symbols.items[@backingInt(def_node)] = .{ .kind = .global, .index = 0 };

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // Group into a block to execute as a single script sequence
    const block_node = try b.block(&.{}, &.{ def_node, call_node }, 0, 0);
    try comp.compile(block_node);

    // The result should be the packed *args array: [2, 3, 4]
    const result_arr = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result_arr.isObject() and result_arr.asObj().obj_type == .array);

    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", result_arr.asObj()));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 4.0), arr_obj.items.items[2].asNumber());
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
    const arg_node = try b.createNode(.identifier, 0, @backingInt(args_id));
    const kwarg_node = try b.createNode(.identifier, 0, @backingInt(kwargs_id));
    const ret_arr_span = try b.addNodes(&.{ arg_node, kwarg_node });
    const body = try b.arrayLiteral(ret_arr_span, 0, 0);
    const def_node = try b.defStmt(func_name, params_span, body, false, 0, false, 0);

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

    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    // Default all nodes to local (so parameters inside the function resolve correctly)
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, 100);
    // Force the function definition to be global so the methodCall explicitly finds it
    symbols.items[@backingInt(def_node)] = .{ .kind = .global, .index = 0 };

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // Group into a block to execute as a single script sequence
    const block_node = try b.block(&.{}, &.{ def_node, call_node }, 0, 0);
    try comp.compile(block_node);

    // The result should be an array: [ [20, 30], { "x" => 100 } ]
    const result_arr = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result_arr.isObject() and result_arr.asObj().obj_type == .array);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", result_arr.asObj()));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);

    // args == [20, 30]
    const packed_args = arr_obj.items.items[0];
    const packed_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", packed_args.asObj()));
    try testing.expectEqual(@as(usize, 2), packed_obj.items.items.len);
    try testing.expectEqual(@as(f64, 20.0), packed_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), packed_obj.items.items[1].asNumber());

    // kwargs == {"x" => 100}
    const packed_kwargs = arr_obj.items.items[1];
    const map_obj: *value.ObjMap = @alignCast(@fieldParentPtr("obj", packed_kwargs.asObj()));
    try testing.expectEqual(@as(usize, 1), map_obj.map.count());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Outer array
    const out_arr = try executeAndAssertStack(&vm, &out_chunk, 1);
    const out_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", out_arr.asObj()));
    try testing.expectEqual(@as(usize, 3), out_obj.items.items.len);

    // a = 10
    try testing.expectEqual(@as(f64, 10.0), out_obj.items.items[0].asNumber());

    // b = [20, 30, 40]
    const b_arr = out_obj.items.items[1];
    const b_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", b_arr.asObj()));
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

    const w_node = try b.createNode(.identifier, 0, @backingInt(w_id));
    const h_node = try b.createNode(.identifier, 0, @backingInt(h_id));
    const ret_arr_span = try b.addNodes(&.{ w_node, h_node });
    const body = try b.arrayLiteral(ret_arr_span, 0, 0);

    const def_node = try b.defStmt(func_name, params_span, body, false, 0, false, 0);

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
    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, 100);
    symbols.items[@backingInt(def_node)] = .{ .kind = .global, .index = 0 };

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    const block_node = try b.block(&.{}, &.{ def_node, call_node }, 0, 0);
    try comp.compile(block_node);

    const result_arr = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result_arr.isObject() and result_arr.asObj().obj_type == .array);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", result_arr.asObj()));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[0].asNumber()); // Passed width
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber()); // Default height
}

test "VM Edge Case: executes 32-bit control flow jump correctly (> 65KB block)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Push 'false' to trigger the jump
    try out_chunk.writeOp(testing.allocator, .op_false, 0);

    // Jump if false over 70,000 bytes!
    try out_chunk.writeOp(testing.allocator, .op_jump_if_false, 0);
    const jump_dist: usize = 70000;
    try out_chunk.write(testing.allocator, @intCast((jump_dist >> 24) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast((jump_dist >> 16) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast((jump_dist >> 8) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast(jump_dist & 0xFF), 0);

    try out_chunk.writeOp(testing.allocator, .op_pop, 0); // pop condition if true

    // Pad exactly 70,000 bytes of dummy instructions
    try out_chunk.code.appendNTimes(testing.allocator, @backingInt(chunk.OpCode.op_nil), jump_dist);

    // Landing zone
    try out_chunk.writeOp(testing.allocator, .op_pop, 0); // pop condition if false
    const success_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(success_val), 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 5;

    // Temporarily increase gas limit because decoding 70,000 nils counts against instructions run
    vm.hooks.setLimit(200_000);

    // The VM should successfully land and return 42
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expectEqual(@as(f64, 30.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));

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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    // x should remain 10, completely unaffected by the inner block's parameter
    try testing.expectEqual(@as(f64, 10.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 6.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result_arr = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result_arr.isObject() and result_arr.asObj().obj_type == .array);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", result_arr.asObj()));

    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    // a = 10
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());

    // args = [20, 30]
    const packed_args = arr_obj.items.items[1];
    const packed_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", packed_args.asObj()));
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
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

test "VM: param getter halts execution if parameter is undefined" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Fetching a parameter before it is defined
    const source =
        \\param(:does_not_exist)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    // The VM must recognize it is missing from the registry and halt
    try testing.expectEqual(.runtime_error, result);
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = result.asArray();
    try testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());
}

test "VM: CLI parameter injection overrides default script parameter values" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Simulate CLI flag injection (`--param width=85`) into the VM `params` Map
    const params_val = vm.globals.get("params").?;
    const map_obj: *value.ObjMap = @alignCast(@fieldParentPtr("obj", params_val.asObj()));

    const sym_key = try vm.allocateSymbol("width");
    vm.push(sym_key);
    defer _ = vm.pop();

    // Replace map_obj.keys.append and map_obj.values.append with a single put
    try map_obj.map.put(vm.gc.trackingAllocator(), sym_key, value.Value.initNumber(85.0));

    // Script declares default: 50, but CLI injection should replace it with 85
    const source =
        \\param(:width, default: 50, validate: { min: 10, max: 100 })
        \\param(:width)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 85.0), result.asNumber());
}

test "VM: Parameter choice validation (in: [...]) enforces allowed discrete options" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Value "huge" is not in ["small", "medium", "large"]
    const source =
        \\param(:size, default: "huge", validate: { in: ["small", "medium", "large"] })
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // 10 + 1 + 2 + 3 = 16
    try testing.expectEqual(@as(f64, 16.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // 5*2 (10) + 10*2 (20) + 20*3 (60) = 90
    try testing.expectEqual(@as(f64, 90.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 66.0), result.asNumber());
}

test "VM: Closure block executes local return back to caller frame" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def run_block(&b)
        \\  b.call(42)
        \\end
        \\run_block do |x|
        \\  return x * 2
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 84.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
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
        \\  b.call(10, 20, 30, 40)
        \\end
        \\yield_splat do |first, *rest|
        \\  [first, rest]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());

    const rest_arr: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_obj.items.items[1].asObj()));
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
        \\  b.call([100, 200])
        \\end
        \\yield_array do |(x, y)|
        \\  x + y
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 300.0), result.asNumber());
}

test "VM: Block closures support keyword arguments (**kwargs) cleanly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def yield_kwargs(&b)
        \\  b.call(50, width: 10, height: 20)
        \\end
        \\yield_kwargs do |val, **opts|
        \\  [val, opts[:width], opts[:height]]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));

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
        \\  b.call([10, 20], 30, 40, a: 1, c: 2)
        \\end
        \\yield_complex do |(x, y), *args, **kw|
        \\  [x, y, args, kw[:a]]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));

    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());

    const args_arr: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_obj.items.items[2].asObj()));
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
        \\  [b.call, b.call(5), b.call(5, 50)]
        \\end
        \\yield_defaults do |x = 10, y = 20|
        \\  x + y
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // The innermost block runs exactly once, so x should be 10.
    // Most importantly, the stack should be perfectly balanced at 1.
    try testing.expectEqual(@as(f64, 10.0), result.asNumber());
}

test "VM: Block arguments gracefully pad with nil when missing" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Yields 0 arguments, but block expects 2.
    const source =
        \\def call_empty(&b)
        \\  b.call
        \\end
        \\call_empty do |x, y|
        \\  [x.nil?, y.nil?]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Should return [true, true] without reading garbage memory
    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
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
        \\  block.call(b: 20, a: 10)
        \\end
        \\test_kw do |a:, b:|
        \\  [a, b]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Should reliably map to [10, 20]
    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
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
        \\  b.call([42])
        \\end
        \\yield_short do |(x, y, z)|
        \\  [x, y.nil?, z.nil?]
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));

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
        \\  b.call(99, 2, 3, 4, 5)
        \\end
        \\yield_many do |first|
        \\  first
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 99.0), result.asNumber());
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

test "VM: Repeated block yields in loops maintain frame and stack equilibrium" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def repeat_yield(count, &b)
        \\  i = 0
        \\  acc = 0
        \\  while i < count
        \\    acc += b.call(i)
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Sum of (0..99)*2 = 2 * (99*100/2) = 9900
    try testing.expectEqual(@as(f64, 9900.0), result.asNumber());
}

test "VM: Stabby lambdas compile and execute with default and keyword parameters" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\calc = ->(x, y = 10, scale: 2) { (x + y) * scale }
        \\[calc.call(5), calc.call(5, 20), calc.call(5, scale: 3)]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 100.0), result.asNumber());
}

test "VM: a reader read as a property is cached at its site like a call" {
    // `b.width` with `def width` found no field, then looked the method up from scratch
    // on every read (class chain, then the private name).
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Box
        \\  def initialize(w)
        \\    @w = w
        \\  end
        \\  def width
        \\    @w
        \\  end
        \\end
        \\b = Box.new(3)
        \\total = 0
        \\i = 0
        \\while i < 3
        \\  total = total + b.width
        \\  i = i + 1
        \\end
        \\total
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 9.0), result.asNumber());

    // The read site caches Box's `width` closure.
    const box = vm.globals.get("Box").?.asClass();
    var cached_reader = false;
    for (out_chunk.inline_caches.items) |ic| if (ic.cachedMethod(box)) |m| {
        if (m.isClosure() and std.mem.eql(u8, m.asClosure().function.name.?.chars, "width")) cached_reader = true;
    };
    try testing.expect(cached_reader);
}

test "VM/Compiler: Resolves pre-existing VM globals as variables, preventing false op_call(0)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: x * 5
    const x_id = try b.intern("x");
    const x_node = try b.createNode(.identifier, 0, @backingInt(x_id));
    const five = try b.number("5", 0);
    const mul_node = try b.binary(.multiply, x_node, five, 0);

    // --- NEW: Provide a mock symbols array ---
    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .global, .index = 0 }, @backingInt(mul_node) + 1);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // 1. INJECT global 'x' into the live VM memory
    try vm.setGlobal("x", value.Value.initNumber(100.0));

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(mul_node);

    // 2. Verify Bytecode: It should NOT emit op_call(0).
    // It should securely fetch 'x' via op_get_global.
    try support.expectOps(&out_chunk, &.{ .op_get_global, .op_constant, .op_multiply });

    // 3. Verify Execution: 100 * 5 = 500
    const res = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 500.0), res.asNumber());
}

test "VM/Compiler: Assignments in a seeded context dynamically allocate new slots via getNextLocalSlot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: z = 42
    const z_id = try b.intern("z");
    const val = try b.number("42", 0);
    const assign_node = try b.assignment(z_id, null, val, 0);

    // Trick the compiler into treating `z` as a local, as if we were inside a block scope.
    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @backingInt(assign_node) + 1);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // --- Create a real, distinct parent compiler to prevent circular recursion! ---
    var parent_chunk = chunk.Chunk.init();
    defer parent_chunk.free(testing.allocator);
    var parent_comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &parent_chunk, &vm);
    defer parent_comp.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // Link safely
    comp.enclosing = &parent_comp;

    // 1. Seed 2 variables at offset 1 -> meaning slots 1 and 2 are occupied.
    const seeded = [_][]const u8{ "a", "b" };
    comp.seedLocals(&seeded, 1);

    try comp.compile(assign_node);

    // 2. Verify it emitted op_set_local starting at slot 3!
    try testing.expectEqual(chunk.OpCode.op_set_local, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[2])));
    try testing.expectEqual(@as(u8, 3), out_chunk.code.items[3]); // Safely bypassed slots 1 and 2
}

test "VM/Compiler: Deeply nested closures correctly resolve and capture upvalues without recursion limits" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // 3 levels of nested scopes!
    // level3 needs to capture 'b' from level2 (1 step up)
    // AND capture 'a' from level1 (2 steps up, requiring recursive upvalue chaining).
    const source =
        \\def level1(a)
        \\  def level2(b)
        \\    def level3(c)
        \\      a + b + c
        \\    end
        \\    level3(30)
        \\  end
        \\  level2(20)
        \\end
        \\level1(10)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    // If there was an infinite loop vulnerability in resolveUpvalue, it would hang right here.
    try comp.compile(doc.tree.root);

    // Run the compiled script. 10 + 20 + 30 = 60.
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expectEqual(@as(f64, 60.0), result.asNumber());
}

test "VM Syntax: Keyword logical operators (and, or, not) evaluate with proper precedence" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\res1 = true and false or not false
        \\res2 = not true or false and true
        \\[res1, res2]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());
    try testing.expectEqual(false, arr_obj.items.items[1].asBool());
}

test "VM Syntax: Safe navigation (&.) on nil receiver short-circuits block execution" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // If safe navigation fails on block-receiving methods, the block will attempt
    // to execute on nil or crash the VM stack.
    const source =
        \\item = nil
        \\executed = false
        \\res = item&.map do |x|
        \\  executed = true
        \\  x * 2
        \\end
        \\[res.nil?, executed]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    // res.nil? -> true (safe navigation returned nil)
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());
    // executed -> false (block was completely bypassed)
    try testing.expectEqual(false, arr_obj.items.items[1].asBool());
}

test "VM Syntax: Safe navigation (&.) short-circuits argument evaluation when receiver is nil" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\evaluated = false
        \\side_effect = ->() do
        \\  evaluated = true
        \\  10
        \\end
        \\
        \\obj = nil
        \\res = obj&.translate(side_effect(), 0, 0)
        \\[res.nil?, evaluated]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    try testing.expectEqual(true, arr_obj.items.items[0].asBool());
    try testing.expectEqual(false, arr_obj.items.items[1].asBool());
}

test "VM Syntax: break statement with value inside while loop yields value to caller" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\i = 0
        \\res = while i < 10
        \\  i = i + 1
        \\  if i == 5
        \\    break 999
        \\  end
        \\end
        \\res
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 999.0), result.asNumber());
}

test "VM Syntax: Array literal splats (*[]) expand empty arrays without corrupting layout" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\empty_arr = []
        \\full_arr = [10, *empty_arr, 20, 30]
        \\[full_arr.length, full_arr[0] + full_arr[1] + full_arr[2]]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 60.0), arr_obj.items.items[1].asNumber());
}

test "VM Syntax: next statement inside block skips iteration and returns value to iterator" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\list = [1, 2, 3, 4]
        \\mapped = list.map do |x|
        \\  if x == 2
        \\    next 0
        \\  end
        \\  x * 10
        \\end
        \\[mapped[0], mapped[1], mapped[2], mapped[3]]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 0.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[2].asNumber());
    try testing.expectEqual(@as(f64, 40.0), arr_obj.items.items[3].asNumber());
}

test "VM: Parameter registry uses O(1) lookup and respects validation limits" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Test script:
    // 1. Define a parameter with a default value and validation limits.
    // 2. Read the parameter inside a loop 10 times to hammer the O(1) cache.
    // 3. Return the accumulated sum.
    const source =
        \\ p = param(:feedrate, default: 15.0, validate: { min: 1.0, max: 100.0 })
        \\ sum = 0
        \\ i = 0
        \\ while (i < 10)
        \\   sum = sum + param(:feedrate)
        \\   i = i + 1
        \\ end
        \\ sum
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // 15.0 * 10 iterations = 150.0
    try testing.expect(result.isNumber());
    try testing.expectEqual(@as(f64, 150.0), result.asNumber());

    // Verify it was correctly recorded in the VM's native registry
    try testing.expectEqual(@as(usize, 1), vm.param_registry.items(.name).len);
    try testing.expectEqual(@as(f64, 1.0), vm.param_registry.items(.min_val)[0]);
    try testing.expectEqual(@as(f64, 100.0), vm.param_registry.items(.max_val)[0]);
}

test "VM: yield securely passes keyword arguments to blocks" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def test_yield
        \\  yield(10, width: 50, height: 100)
        \\end
        \\test_yield do |val, **kwargs|
        \\  [val, kwargs[:width], kwargs[:height]]
        \\end
    ;

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(std.testing.allocator);
    var comp = Compiler.forDocument(std.testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = result.asArray();
    try std.testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);
    try std.testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());
    try std.testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[1].asNumber());
    try std.testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[2].asNumber());
}

test "VM: Splat unpacking roots arrays safely" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // The splat operation forces an array allocation midway through unpacking
    const source =
        \\begin
        \\  a, *b, c = [1, 2, 3, 4]
        \\  b
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isArray());
    const arr = result.asArray();
    try testing.expectEqual(@as(usize, 2), arr.items.items.len); // Should contain [2, 3]
    try testing.expectEqual(@as(f64, 2.0), arr.items.items[0].asNumber());
}

test "VM: Open upvalues do not dangle after stack reallocation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Bind a native function that artificially forces the VM stack to move in memory
    const force_realloc = struct {
        fn run(vm_opaque: *anyopaque, call: value.NativeArgs) anyerror!value.Value {
            const arg_count = call.count;
            const args = call.ptr;
            _ = arg_count;
            _ = args;
            const v: *VM = @ptrCast(@alignCast(vm_opaque));

            // Force the allocator to move the stack array to a completely new memory address
            try v.ensureStackCapacity(v.stack.len * 2 + 1000);
            return value.Value.initNil();
        }
    }.run;
    try vm.defineNative("force_realloc", force_realloc);

    // Script creates an open upvalue `x`, forcefully moves the stack, and tries to read `x`
    const source =
        \\x = 42
        \\closure = ->() { x }
        \\force_realloc() # BOOM: Stack moves, closure's upvalue pointer is now dangling!
        \\closure.call    # Read from freed memory
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // If the bug exists, this will either segfault or trigger a use-after-free panic
    // from the Zig testing allocator!
    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
}
