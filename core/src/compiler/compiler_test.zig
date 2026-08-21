const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const Compiler = @import("compiler.zig").Compiler;
const Document = @import("../core/document.zig").Document;
const resolver = @import("../core/resolver.zig");
const VM = @import("../vm/vm.zig").VM;

test "Compiler: compiles basic binary addition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const left = try b.number("10", 0);
    const right = try b.number("5", 0);
    const bin_node = try b.binary(.add, left, right, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Initialize the VM so the Compiler can use it for managed allocations
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Pass &vm as the 5th argument
    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit(); // Leak fixed
    try comp.compile(bin_node);

    try testing.expectEqual(@as(usize, 6), out_chunk.code.items.len);

    // Left Node
    try testing.expectEqual(@as(u8, @intFromEnum(chunk.OpCode.op_constant)), out_chunk.code.items[0]);
    try testing.expectEqual(@as(u8, 0), out_chunk.code.items[1]);
    try testing.expectEqual(@as(f64, 10.0), out_chunk.constants.items[0].asNumber());

    // Right Node
    try testing.expectEqual(@as(u8, @intFromEnum(chunk.OpCode.op_constant)), out_chunk.code.items[2]);
    try testing.expectEqual(@as(u8, 1), out_chunk.code.items[3]);
    try testing.expectEqual(@as(f64, 5.0), out_chunk.constants.items[1].asNumber());

    // Operator
    try testing.expectEqual(@as(u8, @intFromEnum(chunk.OpCode.op_add)), out_chunk.code.items[4]);
}

test "Compiler: compiles range expression (1..10)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const start = try b.number("1", 0);
    const end = try b.number("10", 0);
    const range_node = try b.range(start, end, .none, false, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit(); // Leak fixed
    try comp.compile(range_node);

    // Bytecode expected:
    // 0: op_constant (start) -> 1
    // 2: op_constant (end) -> 10
    // 4: op_constant (default step) -> 1
    // 6: op_build_range
    // 7: 0 (inclusive boolean flag)
    // 8: op_return

    try testing.expectEqual(@as(usize, 9), out_chunk.code.items.len);
    try testing.expectEqual(chunk.OpCode.op_build_range, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[6])));
    try testing.expectEqual(@as(u8, 0), out_chunk.code.items[7]);
}

test "Compiler: compiles compound assignment (x += 5)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const name_id = try b.intern("x");
    const val = try b.number("5", 0);
    const assign_node = try b.assignment(name_id, .add, val, 0);

    // Unmanaged ArrayList and the top-level resolver import
    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @intFromEnum(assign_node) + 1);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit(); // Leak fixed
    try comp.compile(assign_node);

    // Bytecode expected for `x += 5` at top level:
    // op_get_global (x)
    // op_constant (5)
    // op_add
    // op_define_global (x)
    // op_nil
    // op_return

    try testing.expectEqual(@as(usize, 9), out_chunk.code.items.len);
    try testing.expectEqual(chunk.OpCode.op_get_global, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_add, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[4])));
    try testing.expectEqual(chunk.OpCode.op_define_global, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[5])));
    try testing.expectEqual(chunk.OpCode.op_nil, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[7])));
}

test "Compiler: compiles safe navigation method call (obj&.cut())" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const receiver = try b.identifierNode("obj", 0);
    const method_name = try b.intern("cut");
    const empty_args = try b.addNamedArgs(&.{});

    // Set is_safe to true
    const safe_call = try b.methodCall(receiver, method_name, empty_args, .none, true, 0, 0);

    // Unmanaged ArrayList and the top-level resolver import
    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @intFromEnum(safe_call) + 1);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit(); // Leak fixed
    try comp.compile(safe_call);

    // Bytecode expected:
    // op_get_global (obj)
    // op_jump_if_nil (Safely skip the invoke if true!) (uses 4-byte offset now)
    // op_invoke ('cut')
    // op_return

    try testing.expectEqual(chunk.OpCode.op_get_global, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_jump_if_nil, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[2])));
    // op_invoke shifted 1 byte right due to 4-byte jump offset
    try testing.expectEqual(chunk.OpCode.op_invoke, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[7])));
}

test "Compiler: compiles string interpolation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const str1 = try b.stringNode("Value: ", 0);
    const num = try b.number("42", 0);
    const span = try b.addNodes(&.{ str1, num });

    const interp_node = try b.interpolatedString(span, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit(); // Leak fixed
    try comp.compile(interp_node);

    // Bytecode Expected:
    // op_constant ("Value: ")
    // op_constant (42)
    // op_interpolate (Takes operand 2 for count)
    // op_return

    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_interpolate, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[4])));
    try testing.expectEqual(@as(u8, 2), out_chunk.code.items[5]); // 2 parts merged
}

test "Compiler: compiles import statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const path_str = try b.intern("math.kup");
    const empty_symbols = try b.addStringLists(&.{});

    // import "math.kup"
    const import_node = try b.importStmt(empty_symbols, path_str, .none, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit(); // Leak fixed
    try comp.compile(import_node);

    // Expected Bytecode:
    // 0: op_import (path constant)
    // 2: op_pop (discard standard import result)
    // 3: op_nil (yield nil)
    // 4: op_return

    try testing.expectEqual(chunk.OpCode.op_import, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_pop, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_nil, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[3])));
}

test "Compiler: compiles namespace access (Hardware::Screw)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const p1 = try b.intern("Hardware");
    const p2 = try b.intern("Screw");
    const path_span = try b.addStringLists(&.{ p1, p2 });

    const namespace_node = try b.namespaceAccess(path_span, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit(); // Leak fixed
    try comp.compile(namespace_node);

    // Expected Bytecode:
    // 0: op_get_global ("Hardware")
    // 2: op_get_property ("Screw")
    // 4: op_return

    try testing.expectEqual(chunk.OpCode.op_get_global, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_get_property, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[2])));
}

test "Compiler: compiles rescue modifier (dangerous() rescue 0)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const dangerous_expr = try b.identifierNode("x", 0);
    const fallback_val = try b.number("0", 0);
    const rescue_node = try b.rescueModifier(dangerous_expr, fallback_val, 0);

    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @intFromEnum(rescue_node) + 1);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit(); // Leak fixed
    try comp.compile(rescue_node);

    // Expected Bytecode:
    // 0: op_setup_rescue (jump to rescue block on error) (uses 4-byte offset now)
    // 4: op_get_local (x)
    // 6: op_pop_rescue (success path, remove frame)
    // 7: op_jump (skip rescue block)
    // 11: op_pop (rescue block start: pop the thrown error payload)
    // 12: op_constant (0)
    // 14: op_return

    try testing.expectEqual(chunk.OpCode.op_setup_rescue, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_pop_rescue, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[7])));
    try testing.expectEqual(chunk.OpCode.op_jump, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[8])));
    try testing.expectEqual(chunk.OpCode.op_pop, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[13])));
}

test "Compiler: Compiles complex Begin/Rescue with specific Type Checking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // rescue IOError => e
    const rescue_body = try b.block(&.{}, &.{try b.number("1", 0)}, 0, 0);
    const err_name = try b.intern("IOError");
    const err_list = try b.addStringLists(&.{err_name});
    const var_name = try b.intern("e");
    const rescue_clause = ast.RescueClause{ .errors = err_list, .variable = var_name, .body = rescue_body };
    const rescues = try b.addRescueClauses(&.{rescue_clause});

    // begin body
    const begin_body = try b.block(&.{}, &.{try b.number("2", 0)}, 0, 0);
    const begin_stmt = try b.beginStmt(begin_body, rescues, .none, 0);

    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @intFromEnum(begin_stmt) + 1);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // We are ensuring the complex `op_is_instance` dynamic routing compiles without crashing
    try comp.compile(begin_stmt);

    // The setup, type check duping, and routing generates a significant amount of bytecode
    try testing.expect(out_chunk.code.items.len > 10);
}

test "Compiler Edge Case: Compiles empty Hashes and Arrays safely" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // []
    const empty_arr_span = try b.addNodes(&.{});
    const arr_node = try b.arrayLiteral(empty_arr_span, 0, 0);

    // {}
    const empty_hash_span = try b.addHashEntries(&.{});
    const hash_node = try b.hashLiteral(empty_hash_span, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // Ensure bounds-checking doesn't panic on length == 0
    try comp.compile(arr_node);
    try comp.compile(hash_node);

    try testing.expectEqual(chunk.OpCode.op_build_array, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(@as(u8, 0), out_chunk.code.items[1]); // 0 items
}

test "Compiler: case statements with literals optimize to op_switch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: case x \n when 1 \n 10 \n end
    const cond = try b.number("1", 0);
    const branch1_cond = try b.addNodes(&.{try b.number("1", 0)});
    const branch1_body = try b.number("10", 0);
    const branch1 = ast.WhenBranch{ .conditions = branch1_cond, .body = branch1_body };
    const branches = try b.addWhenBranches(&.{branch1});

    const case_node = try b.caseStmt(cond, branches, .none, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit(); // Leak fixed
    try comp.compile(case_node);

    // Verify the fast-path OP_SWITCH was emitted
    // 0: op_constant (push condition 1)
    // 2: op_switch
    // 3: 1 (case_count)
    try testing.expectEqual(chunk.OpCode.op_switch, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[2])));
    try testing.expectEqual(@as(u8, 1), out_chunk.code.items[3]);
}

test "Compiler: correctly maps AST token offsets into DebugSpans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // Mock an AST: `10 + 5`
    // Let's pretend "10" is at byte offset 0, "+" is at offset 3, "5" is at offset 5
    const left = try b.number("10", 0); // Token index 0
    const right = try b.number("5", 2); // Token index 2
    const bin_node = try b.binary(.add, left, right, 1); // Token index 1

    // Mock the Lexer's token start offsets
    const token_starts = [_]u32{ 0, 3, 5 };

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &token_starts, &out_chunk, &vm);
    defer comp.deinit(); // Leak fixed
    try comp.compile(bin_node);

    // Verify the DebugSpans caught the offsets from the token_starts array
    try testing.expect(out_chunk.debug_spans.items.len > 0);
    // The very first instruction should be mapped to offset 0 (the "10" literal)
    try testing.expectEqual(@as(u32, 0), out_chunk.getOffset(0));
}

test "Compiler Edge Case: compiles array literal with > 255 elements (wide operand)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // Generate 300 literal "1" nodes
    var elements: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
    defer elements.deinit(testing.allocator);

    for (0..300) |_| {
        const num = try b.number("1", 0);
        try elements.append(testing.allocator, num);
    }
    const span = try b.addNodes(elements.items);
    const arr_node = try b.arrayLiteral(span, 0, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(arr_node);

    // Verify op_build_array_wide is present in the bytecode!
    var found_wide = false;
    for (out_chunk.code.items) |byte| {
        if (byte == @intFromEnum(chunk.OpCode.op_build_array_wide)) found_wide = true;
    }

    // If it fell back to the standard op_build_array, this test will fail
    try testing.expect(found_wide);
}

test "Compiler Edge Case: Prevent stack leaks from break inside expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // 1. Construct AST manually to bypass the parser: 10 + (break 5)
    const ten = try b.number("10", 0);
    const five = try b.number("5", 0);

    // Inject the break statement payload directly
    const break_node = try b.createNode(.break_stmt, 0, @intFromEnum(five));
    const add_node = try b.binary(.add, ten, break_node, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &[_]resolver.ResolvedSymbol{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // 2. Inject a fake loop state into the compiler so it permits the break
    try comp.loops.append(comp.allocator, .{ .start = 0, .depth = 0 });

    // 3. Compile the addition. The compiler will catch the depth mismatch and abort!
    const result = comp.compile(add_node);
    try testing.expectError(error.UnsupportedScope, result);
}

test "Compiler: Prevent stack leaks from next inside expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // 1. Construct AST manually: 10 + (next)
    const ten = try b.number("10", 0);
    const next_node = try b.createNode(.next_stmt, 0, @intFromEnum(ast.NodeIndex.none));
    const add_node = try b.binary(.add, ten, next_node, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &[_]resolver.ResolvedSymbol{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // 2. Inject a fake loop state
    try comp.loops.append(comp.allocator, .{ .start = 0, .depth = 0 });

    const result = comp.compile(add_node);
    try testing.expectError(error.UnsupportedScope, result);
}

test "Compiler: op_pop_rescue does not corrupt max_stack_slots calculation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST:
    // begin
    //   10
    // rescue => e
    //   20
    // end
    const begin_body = try b.block(&.{}, &.{try b.number("10", 0)}, 0, 0);
    const rescue_body = try b.block(&.{}, &.{try b.number("20", 0)}, 0, 0);

    const err_name = try b.intern("StandardError");
    const err_list = try b.addStringLists(&.{err_name});
    const var_name = try b.intern("e");

    const rescue_clause = ast.RescueClause{ .errors = err_list, .variable = var_name, .body = rescue_body };
    const rescues = try b.addRescueClauses(&.{rescue_clause});
    const begin_stmt = try b.beginStmt(begin_body, rescues, .none, 0);

    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @intFromEnum(begin_stmt) + 1);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(begin_stmt);

    // The maximum stack depth for this simple begin/rescue should be 2
    // (1 for the pushed number/error, 1 temporarily used during error type checking).
    // Before the fix, `op_pop_rescue` would simulate a pop, causing under-calculation
    // and potentially returning a smaller maximum stack size than physically needed.
    try testing.expect(out_chunk.max_stack_slots >= 2);
}

test "Compiler: Protects core globals from variable reassignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: cube = 10
    const name_id = try b.intern("cube");
    const val = try b.number("10", 0);
    const assign_node = try b.assignment(name_id, null, val, 0);

    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .global, .index = 0 }, @intFromEnum(assign_node) + 1);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // The compiler must intercept the 'cube' assignment and halt
    const result = comp.compile(assign_node);
    try testing.expectError(error.ProtectedSymbol, result);
}

test "Compiler: Protects core globals from function redefinition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: def param() end
    const func_name = try b.intern("param");
    const params_span = try b.addParams(&.{});
    const body = try b.createNode(.undef, 0, 0);
    const def_node = try b.defStmt(func_name, params_span, body, false, 0, 0);

    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .global, .index = 0 }, @intFromEnum(def_node) + 1);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // The compiler must intercept the 'param' def and halt
    const result = comp.compile(def_node);
    try testing.expectError(error.ProtectedSymbol, result);
}

test "Compiler: Protects core classes from complete reassignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: class Array; end
    const class_name_node = try b.identifierNode("Array", 0);
    const empty_body = try b.block(&.{}, &.{}, 0, 0);
    const class_node = try b.classStmt(class_name_node, .none, empty_body, 0, 0);

    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .global, .index = 0 }, @intFromEnum(class_node) + 1);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // The compiler must intercept the 'Array' class definition and halt
    const result = comp.compile(class_node);
    try testing.expectError(error.ProtectedSymbol, result);
}

test "Compiler: Block intermediate expressions are strictly popped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: { 10; 20; 30 }
    const ten = try b.number("10", 0);
    const twenty = try b.number("20", 0);
    const thirty = try b.number("30", 0);
    const block_node = try b.block(&.{}, &.{ ten, twenty, thirty }, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &[_]resolver.ResolvedSymbol{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(block_node);

    // Expected Bytecode:
    // 0: op_constant (10)
    // 2: op_pop         <-- CRITICAL
    // 3: op_constant (20)
    // 5: op_pop         <-- CRITICAL
    // 6: op_constant (30)
    // 8: op_return
    try testing.expectEqual(chunk.OpCode.op_pop, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_pop, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[5])));
    // The final expression (30) should NOT be popped
    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[6])));
}

test "Compiler: Method blocks accurately extract local_count for the VM" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // The block defines 3 unique local variables: x (param), y, z
    const source =
        \\[1, 2].each do |x|
        \\  y = x * 2
        \\  z = y + 1
        \\end
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    // Scan the compiled bytecode to find the closure function object
    var closure_func: ?*value.ObjFunction = null;
    for (out_chunk.code.items, 0..) |byte, i| {
        if (byte == @intFromEnum(chunk.OpCode.op_closure)) {
            const func_idx = out_chunk.code.items[i + 1];
            closure_func = @as(*value.ObjFunction, @alignCast(@fieldParentPtr("obj", out_chunk.constants.items[func_idx].asObj())));
            break;
        }
    }

    try testing.expect(closure_func != null);
    // local_count must be at least 4: (0: closure itself, 1: x, 2: y, 3: z)
    try testing.expect(closure_func.?.local_count >= 4);
}

test "Compiler: Short-circuit AND/OR operands pop cleanly before loop jumps" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def run_loop()
        \\  i = 0
        \\  res = 0
        \\  while (i < 10)
        \\    i = i + 1
        \\    if (i == 5)
        \\      break
        \\    end
        \\  end
        \\  i
        \\end
        \\run_loop()
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
    try testing.expectEqual(@as(f64, 5.0), vm.stack[0].asNumber());
}

test "Compiler: Block closures calculate total local slots accurately" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\def wrapper(&b)
        \\  b(1, 2)
        \\end
        \\wrapper do |x, y|
        \\  loc1 = 100
        \\  loc2 = 200
        \\  loc3 = loc1 + loc2
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    var block_func: ?*value.ObjFunction = null;
    for (out_chunk.constants.items) |c_val| {
        if (c_val.isObject() and c_val.asObj().obj_type == .function) {
            const func = @as(*value.ObjFunction, @alignCast(@fieldParentPtr("obj", c_val.asObj())));
            if (func.name == null) {
                block_func = func;
                break;
            }
        }
    }

    try testing.expect(block_func != null);
    try testing.expect(block_func.?.local_count >= 6);
}

test "Compiler: Break outside of loop scope correctly emits CompileError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: break 10
    const val = try b.number("10", 0);
    const break_node = try b.breakStmt(val, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &[_]resolver.ResolvedSymbol{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // Attempting to compile a break statement without an active loop scope
    // MUST trigger a safe compilation error, preventing the VM from executing warped bytecode.
    const result = comp.compile(break_node);
    try testing.expectError(error.UnknownNode, result);
}

test "Compiler: Large array literals (> 65,535 items) fallback to dynamic build mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // Create an array literal with 70,000 elements
    const elem_count: usize = 70000;
    var elements: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
    defer elements.deinit(testing.allocator);

    const one = try b.number("1", 0);
    for (0..elem_count) |_| {
        try elements.append(testing.allocator, one);
    }

    const span = try b.addNodes(elements.items);
    const arr_node = try b.arrayLiteral(span, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // Must NOT throw error.TooManyConstants
    try comp.compile(arr_node);

    // Verify op_array_push was emitted for dynamic element insertion
    var found_push = false;
    for (out_chunk.code.items) |byte| {
        if (byte == @intFromEnum(chunk.OpCode.op_array_push)) found_push = true;
    }
    try testing.expect(found_push);
}

test "Compiler: compiles compound property assignment (obj.x += 10)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: obj.x += 10
    const target = try b.identifierNode("obj", 0);
    const prop_id = try b.intern("x");
    const val = try b.number("10", 0);
    const prop_assign = try b.propertyAssignment(target, prop_id, .add, val, 0);

    // Provide a generic symbol map to avoid out of bounds
    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .global, .index = 0 }, @intFromEnum(prop_assign) + 1);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.script_globals.put(testing.allocator, "obj", {});
    try comp.compile(prop_assign);

    // Expected Bytecode:
    // 0: op_get_global ("obj")
    // 2: op_dup                <-- Duplicates the target pointer to use for the setter later!
    // 3: op_get_property ("x") <-- Consumes one of the target pointers to get current value
    // 5: op_constant (10)
    // 7: op_add
    // 8: op_set_property ("x") <-- Consumes the duplicated target pointer and the new value
    // 10: op_return

    try testing.expectEqual(chunk.OpCode.op_get_global, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_dup, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_get_property, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[3])));
    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[5])));
    try testing.expectEqual(chunk.OpCode.op_add, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[7])));
    try testing.expectEqual(chunk.OpCode.op_set_property, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[8])));
}

test "Compiler: compiles compound index assignment (arr[1] *= 2)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: arr[1] *= 2
    const target = try b.identifierNode("arr", 0);
    const index = try b.number("1", 0);
    const val = try b.number("2", 0);
    const idx_assign = try b.indexAssignment(target, index, .multiply, val, 0);

    var symbols: std.ArrayListUnmanaged(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .global, .index = 0 }, @intFromEnum(idx_assign) + 1);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.script_globals.put(testing.allocator, "arr", {});

    try comp.compile(idx_assign);

    // Expected Bytecode:
    // 0: op_get_global ("arr")
    // 2: op_constant (1)
    // 4: op_dup_two            <-- Duplicates BOTH target and index
    // 5: op_get_index
    // 6: op_constant (2)
    // 8: op_multiply
    // 9: op_set_index          <-- Consumes the duplicated target/index and the new result
    // 10: op_return

    try testing.expectEqual(chunk.OpCode.op_get_global, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_dup_two, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[4])));
    try testing.expectEqual(chunk.OpCode.op_get_index, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[5])));
    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[6])));
    try testing.expectEqual(chunk.OpCode.op_multiply, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[8])));
    try testing.expectEqual(chunk.OpCode.op_set_index, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[9])));
}

test "Compiler: compiles unary NOT operator gracefully" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: !true
    const t_node = try b.booleanNode(true, 0);
    const not_node = try b.unary(.not, t_node, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(not_node);

    try testing.expectEqual(chunk.OpCode.op_true, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_not, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[1])));
}

test "Compiler: compiles export statement natively yielding nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: export { x } (Currently implemented as a stub yielding nil in MVP)
    const export_node = try b.createNode(.export_stmt, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(export_node);

    try testing.expectEqual(chunk.OpCode.op_nil, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
}
