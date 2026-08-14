const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const Compiler = @import("compiler.zig").Compiler;
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
    try comp.compile(safe_call);

    // Bytecode expected:
    // op_get_global (obj)
    // op_jump_if_nil (Safely skip the invoke if true!)
    // op_invoke ('cut')
    // op_return
    try testing.expectEqual(chunk.OpCode.op_get_global, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_jump_if_nil, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_invoke, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[5])));
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
    try comp.compile(rescue_node);

    // Expected Bytecode:
    // 0: op_setup_rescue (jump to rescue block on error)
    // 3: op_get_local (x)
    // 5: op_pop_rescue (success path, remove frame)
    // 6: op_jump (skip rescue block)
    // 9: op_pop (rescue block start: pop the thrown error payload)
    // 10: op_constant (0)
    // 12: op_return
    try testing.expectEqual(chunk.OpCode.op_setup_rescue, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_pop_rescue, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[5])));
    try testing.expectEqual(chunk.OpCode.op_jump, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[6])));
    try testing.expectEqual(chunk.OpCode.op_pop, @as(chunk.OpCode, @enumFromInt(out_chunk.code.items[9])));
}

test "Compiler Edge Case: Compiles complex Begin/Rescue with specific Type Checking" {
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
    try comp.compile(bin_node);

    // Verify the DebugSpans caught the offsets from the token_starts array
    try testing.expect(out_chunk.debug_spans.items.len > 0);

    // The very first instruction should be mapped to offset 0 (the "10" literal)
    try testing.expectEqual(@as(u32, 0), out_chunk.getOffset(0));
}
