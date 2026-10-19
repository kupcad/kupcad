const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const limits = @import("../core/limits.zig");
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const Compiler = @import("compiler.zig").Compiler;
const Document = @import("../core/document.zig").Document;
const resolver = @import("../core/resolver.zig");
const VM = @import("../vm/vm.zig").VM;
const support = @import("../test_support.zig");
const Diagnostic = @import("../core/errors.zig").Diagnostic;
const expectOps = support.expectOps;
const instructionAt = support.instructionAt;

const RunResult = struct {
    status: @import("../vm/vm.zig").InterpretResult,
    top: value.Value,
};

/// Compiles and runs `source`, returning the interpreter status and the value
/// left on the stack (nil if none).
fn run(vm: *VM, source: []const u8) !RunResult {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const status = vm.interpret(&out_chunk);
    const top = if (vm.stack_top > 0) vm.stack[vm.stack_top - 1] else value.Value.initNil();
    return .{ .status = status, .top = top };
}

fn expectRunsTo(source: []const u8, expected: f64) !void {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const res = try run(&vm, source);
    try testing.expectEqual(.ok, res.status);
    try testing.expectEqual(expected, res.top.asNumber());
}

fn compileOnly(source: []const u8) !void {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
}

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

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(bin_node);

    // Bytecode Expected (Folded):
    // 0: op_constant (15)
    // 2: op_return
    try testing.expectEqual(@as(usize, 3), out_chunk.code.items.len);

    // Folded Result Node
    try testing.expectEqual(@as(u8, @backingInt(chunk.OpCode.op_constant)), out_chunk.code.items[0]);
    try testing.expectEqual(@as(u8, 0), out_chunk.code.items[1]);
    try testing.expectEqual(@as(f64, 15.0), out_chunk.constants.items[0].asNumber());
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
    defer comp.deinit();
    try comp.compile(range_node);

    // Bytecode expected:
    // 0: op_constant (start) -> 1
    // 2: op_constant (end) -> 10
    // 4: op_constant (default step) -> 1
    // 6: op_build_range
    // 7: 0 (inclusive boolean flag)
    // 8: op_return

    try testing.expectEqual(@as(usize, 9), out_chunk.code.items.len);
    try testing.expectEqual(chunk.OpCode.op_build_range, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[6])));
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
    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @backingInt(assign_node) + 1);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(assign_node);

    try expectOps(&out_chunk, &.{ .op_get_global, .op_constant, .op_add, .op_dup, .op_define_global, .op_return });
    try testing.expectEqual(try instructionAt(&out_chunk, 6), out_chunk.code.items.len); // and nothing else
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
    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @backingInt(safe_call) + 1);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(safe_call);

    try expectOps(&out_chunk, &.{ .op_get_global, .op_jump_if_nil, .op_invoke, .op_return });
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
    defer comp.deinit();
    try comp.compile(interp_node);

    // Bytecode Expected:
    // op_constant ("Value: ")
    // op_constant (42)
    // op_interpolate (Takes operand 2 for count)
    // op_return

    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_interpolate, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[4])));
    try testing.expectEqual(@as(u8, 2), out_chunk.code.items[5]); // 2 parts merged
}

test "Compiler: compiles import statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const path_str = try b.intern("math.kup");
    const empty_symbols = try b.addAliasPairs(&.{});

    // import "math.kup"
    const import_node = try b.importStmt(empty_symbols, path_str, .none, false, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(import_node);

    // Expected Bytecode:
    // 0: op_import (path constant)
    // 2: op_pop (discard standard import result)
    // 3: op_nil (yield nil)
    // 4: op_return

    try testing.expectEqual(chunk.OpCode.op_import, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_pop, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_nil, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[3])));
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
    defer comp.deinit();
    try comp.compile(namespace_node);

    try expectOps(&out_chunk, &.{ .op_get_global, .op_get_property, .op_return });
}

test "Compiler: compiles rescue modifier (dangerous() rescue 0)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const dangerous_expr = try b.identifierNode("x", 0);
    const fallback_val = try b.number("0", 0);
    const rescue_node = try b.rescueModifier(dangerous_expr, fallback_val, 0);

    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @backingInt(rescue_node) + 1);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(rescue_node);

    try expectOps(&out_chunk, &.{ .op_setup_rescue, .op_get_global, .op_pop_rescue, .op_jump, .op_pop, .op_constant, .op_return });
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

    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @backingInt(begin_stmt) + 1);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(begin_stmt);

    // The handler is installed first, and the typed clause routes through op_is_instance
    try testing.expectEqual(chunk.OpCode.op_setup_rescue, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[0])));
    try testing.expect(std.mem.findScalar(u8, out_chunk.code.items, @backingInt(chunk.OpCode.op_is_instance)) != null);
    try testing.expect(std.mem.findScalar(u8, out_chunk.code.items, @backingInt(chunk.OpCode.op_pop_rescue)) != null);
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
    const hash_node = try b.hashLiteral(empty_hash_span, 0, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // Ensure bounds-checking doesn't panic on length == 0
    try comp.compile(arr_node);
    try comp.compile(hash_node);

    try testing.expectEqual(chunk.OpCode.op_build_array, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[0])));
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
    defer comp.deinit();
    try comp.compile(case_node);

    // Verify the fast-path OP_SWITCH was emitted
    // 0: op_constant (push condition 1)
    // 2: op_switch
    // 3: 1 (case_count)
    try testing.expectEqual(chunk.OpCode.op_switch, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[2])));
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
    defer comp.deinit();
    try comp.compile(bin_node);

    // Verify the DebugSpans caught the offsets from the token_starts array
    try testing.expect(out_chunk.debug_spans.items.len > 0);

    // Because 10 + 5 folds to 15, the compiler skips the leaf nodes and directly compiles
    // the binary operator (Token Index 1, which corresponds to offset 3 in the array)
    try testing.expectEqual(@as(u32, 3), out_chunk.getOffset(0));
}

test "Compiler Edge Case: compiles array literal with > 255 elements (wide operand)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // One more element than a u8 count operand can hold
    var elements: std.ArrayList(ast.NodeIndex) = .empty;
    defer elements.deinit(testing.allocator);

    for (0..limits.MAX_SHORT_CONSTANTS + 1) |_| {
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
        if (byte == @backingInt(chunk.OpCode.op_build_array_wide)) found_wide = true;
    }

    // If it fell back to the standard op_build_array, this test will fail
    try testing.expect(found_wide);
}

test "Compiler Edge Case: break and next inside an expression drop its operands" {
    // `10 + (break 5)` / `10 + next` in a loop: the jump leaves with the left operand on the
    // stack, and drops it (it was refused as an internal compiler error; an `ensure` body,
    // which runs with the begin's value on the stack, is where a script meets this).
    // Built by hand: the parser makes no jump inside an operand.
    inline for (.{ ast.Tag.break_stmt, ast.Tag.next_stmt }) |tag| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var b = ast.Builder.init(arena.allocator());
        defer b.deinit();

        const ten = try b.number("10", 0);
        const payload = if (tag == .break_stmt) try b.number("5", 0) else ast.NodeIndex.none;
        const jump_node = try b.createNode(tag, 0, @backingInt(payload));
        const add_node = try b.binary(.add, ten, jump_node, 0);
        const body = try b.block(&.{}, &.{add_node}, 0, 0);
        const loop = try b.whileStmt(try b.booleanNode(true, 0), body, false, 0);

        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(testing.allocator);
        var comp = Compiler.init(testing.allocator, &b.tree, &[_]resolver.ResolvedSymbol{}, &[_]u32{}, &out_chunk, &vm);
        defer comp.deinit();
        try comp.compile(loop);

        // `break 5` ends the endless loop with 5, the stack back to just that value. (The
        // `next` loop never ends: that it compiles is the change.)
        if (tag == .break_stmt) {
            const result = try @import("../vm/vm_test_helpers.zig").executeAndAssertStack(&vm, &out_chunk, 1);
            try testing.expectEqual(@as(f64, 5), result.asNumber());
        }
    }
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

    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .local, .index = 0 }, @backingInt(begin_stmt) + 1);

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

    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .global, .index = 0 }, @backingInt(assign_node) + 1);

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
    const body = try b.nilNode(0);
    const def_node = try b.defStmt(func_name, params_span, body, false, 0, false, 0);

    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .global, .index = 0 }, @backingInt(def_node) + 1);

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

    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .global, .index = 0 }, @backingInt(class_node) + 1);

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
    try testing.expectEqual(chunk.OpCode.op_pop, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[2])));
    try testing.expectEqual(chunk.OpCode.op_pop, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[5])));
    // The final expression (30) should NOT be popped
    try testing.expectEqual(chunk.OpCode.op_constant, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[6])));
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    // Scan the compiled bytecode to find the closure function object
    var closure_func: ?*value.ObjFunction = null;
    for (out_chunk.code.items, 0..) |byte, i| {
        if (byte == @backingInt(chunk.OpCode.op_closure)) {
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    var block_func: ?*value.ObjFunction = null;
    for (out_chunk.constants.items) |c_val| {
        if (c_val.isObject() and c_val.asObj().obj_type == .function) {
            const func: *value.ObjFunction = @alignCast(@fieldParentPtr("obj", c_val.asObj()));
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

    // One more element than op_build_array_wide's u16 count can hold
    const elem_count: usize = limits.MAX_CONSTANTS + 1;
    var elements: std.ArrayList(ast.NodeIndex) = .empty;
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
        if (byte == @backingInt(chunk.OpCode.op_array_push)) found_push = true;
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
    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .global, .index = 0 }, @backingInt(prop_assign) + 1);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.script_globals.put(testing.allocator, "obj", {});
    try comp.compile(prop_assign);

    try expectOps(&out_chunk, &.{ .op_get_global, .op_dup, .op_get_property, .op_constant, .op_add, .op_set_property, .op_return });
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

    var symbols: std.ArrayList(resolver.ResolvedSymbol) = .empty;
    defer symbols.deinit(testing.allocator);
    try symbols.appendNTimes(testing.allocator, .{ .kind = .global, .index = 0 }, @backingInt(idx_assign) + 1);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, symbols.items, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.script_globals.put(testing.allocator, "arr", {});

    try comp.compile(idx_assign);

    try expectOps(&out_chunk, &.{ .op_get_global, .op_constant, .op_dup_two, .op_get_index, .op_constant, .op_multiply, .op_set_index, .op_return });
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

    try testing.expectEqual(chunk.OpCode.op_true, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_not, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[1])));
}

test "Compiler: compiles export statement natively yielding module" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: export { x }
    const x_sym = try b.intern("x");
    // Wrap the symbol in the AliasPair struct
    const symbols = try b.addAliasPairs(&.{.{ .original = x_sym, .alias = x_sym }});
    const export_node = try b.exportStmt(symbols, .none, .none, true, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(export_node);

    try testing.expectEqual(chunk.OpCode.op_module, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[0])));
    try testing.expectEqual(chunk.OpCode.op_dup, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[2])));
}

test "Compiler: compiles STL asset import interception" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: import shape from "model.stl"
    const path_str = try b.intern("model.stl");
    const shape_sym = try b.intern("shape");
    // Wrap the symbol in the AliasPair struct
    const symbols = try b.addAliasPairs(&.{.{ .original = shape_sym, .alias = shape_sym }});
    const import_node = try b.importStmt(symbols, path_str, .none, false, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(import_node);

    try expectOps(&out_chunk, &.{ .op_get_global, .op_constant, .op_call, .op_dup, .op_define_global, .op_pop, .op_nil, .op_return });
    const call = try instructionAt(&out_chunk, 2);
    try testing.expectEqual(@as(u8, 1), out_chunk.code.items[call + 1]); // 1 argument
    try testing.expectEqual(@as(u8, 0), out_chunk.code.items[call + 2]); // no block, no spread
}

test "Compiler: Local variable names are exported to chunk metadata for REPL introspection" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\def test_func(width, height)
        \\  area = width * height
        \\end
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    // Scan constants to find the compiled `test_func` closure chunk
    var child_chunk: ?*chunk.Chunk = null;
    for (out_chunk.constants.items) |c_val| {
        if (c_val.isObject() and c_val.asObj().obj_type == .function) {
            const func: *value.ObjFunction = @alignCast(@fieldParentPtr("obj", c_val.asObj()));
            if (func.name != null and std.mem.eql(u8, func.name.?.chars, "test_func")) {
                child_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(func.chunk.?)));
                break;
            }
        }
    }

    try testing.expect(child_chunk != null);
    const locals = child_chunk.?.local_names.items;

    // Verify exactly how the compiler maps parameters and locals to stack memory slots
    try testing.expect(locals.len >= 5);
    try testing.expectEqualStrings("<anonymous>", locals[0]); // Slot 0: The closure itself
    try testing.expectEqualStrings("width", locals[1]); // Slot 1: Positional Param 1
    try testing.expectEqualStrings("height", locals[2]); // Slot 2: Positional Param 2
    try testing.expectEqualStrings("<anonymous>", locals[3]); // Slot 3: Implicit Block `&b`
    try testing.expectEqualStrings("area", locals[4]); // Slot 4: Inner Local Variable
}

test "Compiler: Multiple assignment optimization skips heap allocation for static arrays" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source = "x, y = 10, 20";
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Verify op_build_array and op_unpack are completely absent
    var found_build = false;
    var found_unpack = false;
    for (out_chunk.code.items) |byte| {
        if (byte == @backingInt(chunk.OpCode.op_build_array)) found_build = true;
        if (byte == @backingInt(chunk.OpCode.op_unpack)) found_unpack = true;
    }

    try testing.expect(!found_build);
    try testing.expect(!found_unpack);
}

test "Compiler: Deep spatial tuple destructuring emits recursive unpacks" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\points.each do |((x, y), z)|
        \\end
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Scan constants to find the compiled block chunk
    var child_chunk: ?*chunk.Chunk = null;
    for (out_chunk.constants.items) |c_val| {
        if (c_val.isObject() and c_val.asObj().obj_type == .function) {
            const func: *value.ObjFunction = @alignCast(@fieldParentPtr("obj", c_val.asObj()));
            if (func.name == null) {
                child_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(func.chunk.?)));
                break;
            }
        }
    }

    try testing.expect(child_chunk != null);

    // Verify op_unpack was emitted exactly twice (once for outer tuple, once for inner (x, y))
    var unpack_count: usize = 0;
    for (child_chunk.?.code.items) |byte| {
        if (byte == @backingInt(chunk.OpCode.op_unpack)) unpack_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), unpack_count);
}

// --- Destructuring and `rescue =>` store into every kind of variable ---

const StoreCase = struct {
    name: []const u8,
    source: []const u8,
    expected: union(enum) { number: f64, string: []const u8 },
};

// Destructuring and `rescue => target` store a value that is already on the
// stack, unlike `target = value`, so every target kind needs its own check.
const store_cases = [_]StoreCase{
    .{ .name = "ivars from a literal", .expected = .{ .number = 21 }, .source =
    \\class P
    \\  def run
    \\    @a, @b = [1, 2]
    \\    @a + @b * 10
    \\  end
    \\end
    \\P.new.run
    },
    .{ .name = "ivars from a runtime array, read by another method", .expected = .{ .number = 43 }, .source =
    \\class P
    \\  attr_reader :b
    \\  def run(pair)
    \\    @a, @b = pair
    \\    @a
    \\  end
    \\end
    \\p = P.new
    \\p.run([3, 4]) + p.b * 10
    },
    .{ .name = "ivar splat", .expected = .{ .number = 21 }, .source =
    \\class P
    \\  def run
    \\    @a, *@rest = [1, 2, 3]
    \\    @a + @rest.size * 10
    \\  end
    \\end
    \\P.new.run
    },
    .{ .name = "ivars inside a block", .expected = .{ .number = 32 }, .source =
    \\class P
    \\  def run
    \\    [1].each { |x| @a, @b = [x + 1, x + 2] }
    \\    @a + @b * 10
    \\  end
    \\end
    \\P.new.run
    },
    .{ .name = "every kind in one statement", .expected = .{ .number = 4321 }, .source =
    \\class P
    \\  def run
    \\    @a, b, @@c, $d = [1, 2, 3, 4]
    \\    @a + b * 10 + @@c * 100 + $d * 1000
    \\  end
    \\end
    \\P.new.run
    },
    .{ .name = "rescue into an ivar", .expected = .{ .string = "boom" }, .source =
    \\class P
    \\  def run
    \\    begin
    \\      raise "boom"
    \\    rescue => @e
    \\    end
    \\    @e.message
    \\  end
    \\end
    \\P.new.run
    },
    .{ .name = "typed rescue clauses into an ivar", .expected = .{ .string = "typed" }, .source =
    \\class P
    \\  def run
    \\    begin
    \\      raise(ArgumentError.new("typed"))
    \\    rescue TypeError => @e
    \\      return "wrong clause"
    \\    rescue ArgumentError => @e
    \\    end
    \\    @e.message
    \\  end
    \\end
    \\P.new.run
    },
    .{ .name = "rescue into an ivar inside a block", .expected = .{ .string = "in block" }, .source =
    \\class P
    \\  def run
    \\    [1].each do |x|
    \\      begin
    \\        raise "in block"
    \\      rescue => @e
    \\      end
    \\    end
    \\    @e.message
    \\  end
    \\end
    \\P.new.run
    },
    .{ .name = "class vars", .expected = .{ .number = 21 }, .source =
    \\class P
    \\  def run
    \\    @@a, @@b = [1, 2]
    \\    @@a + @@b * 10
    \\  end
    \\end
    \\P.new.run
    },
    .{ .name = "rescue into a class var", .expected = .{ .string = "cv" }, .source =
    \\class P
    \\  def run
    \\    begin
    \\      raise "cv"
    \\    rescue => @@e
    \\    end
    \\    @@e.message
    \\  end
    \\end
    \\P.new.run
    },
    .{ .name = "captured locals from a block", .expected = .{ .number = 32 }, .source =
    \\def f
    \\  a = 0
    \\  b = 0
    \\  [1].each { |x| a, b = [x + 1, x + 2] }
    \\  a + b * 10
    \\end
    \\f()
    },
    .{ .name = "rescue into a captured local", .expected = .{ .string = "inner" }, .source =
    \\def f
    \\  e = nil
    \\  [1].each do |x|
    \\    begin
    \\      raise "inner"
    \\    rescue => e
    \\    end
    \\  end
    \\  e.message
    \\end
    \\f()
    },
    .{ .name = "$globals from a method are visible to others", .expected = .{ .number = 321 }, .source =
    \\def set_all
    \\  $a, $b = [1, 2]
    \\  $c = 3
    \\end
    \\def read_all
    \\  $a + $b * 10 + $c * 100
    \\end
    \\set_all()
    \\read_all()
    },
    .{ .name = "rescue into a $global", .expected = .{ .string = "gv" }, .source =
    \\def f
    \\  begin
    \\    raise "gv"
    \\  rescue => $e
    \\  end
    \\end
    \\f()
    \\$e.message
    },
    .{ .name = "top-level destructuring keeps self and makes script globals", .expected = .{ .number = 79 }, .source =
    \\s = self
    \\a, b = [7, 8]
    \\def g
    \\  b + 1
    \\end
    \\self == s ? a * 10 + g() : -1
    },
};

test "Compiler: destructuring and rescue store into ivars, cvars, globals and captured locals" {
    for (store_cases) |case| {
        errdefer std.debug.print("store case '{s}' failed\n", .{case.name});
        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        try registry.registerStandardLibrary(&vm);
        const res = try run(&vm, case.source);
        try testing.expectEqual(.ok, res.status);
        switch (case.expected) {
            .number => |n| try testing.expectEqual(n, res.top.asNumber()),
            .string => |s| {
                try testing.expect(res.top.isString());
                try testing.expectEqualStrings(s, res.top.asString().chars);
            },
        }
    }
}

test "Compiler: sigil parameters and index or attribute destructuring targets get a located parse error" {
    // Formal parameters follow Ruby: a sigil name is never a parameter. Index and
    // attribute targets are not destructuring or rescue targets either.
    const cases = [_]struct { source: []const u8, culprit: []const u8 }{
        .{ .source = "[[1, 2]].each { |(@a, b)| b }", .culprit = "@a" },
        .{ .source = "[[1, 2]].each { |(a, @@b)| a }", .culprit = "@@b" },
        .{ .source = "[1].each { |@a| 1 }", .culprit = "@a" },
        .{ .source = "[1].each { |*$rest| 1 }", .culprit = "$rest" },
        .{ .source = "def f(@a)\n  1\nend", .culprit = "@a" },
        .{ .source = "def f(**@@opts)\n  1\nend", .culprit = "@@opts" },
        .{ .source = "g = ->($x) { 1 }", .culprit = "$x" },
        .{ .source = "a = [0, 0]\na[0], b = [1, 2]", .culprit = "," },
        .{ .source = "o = 1\no.x, y = [1, 2]", .culprit = "," },
        .{ .source = "begin\n  1\nrescue => o.x\nend", .culprit = "." },
    };
    for (cases) |case| {
        errdefer std.debug.print("rejection case '{s}' failed\n", .{case.source});
        var doc = try Document.parse(testing.allocator, case.source);
        defer doc.deinit();
        try testing.expect(doc.diagnostics.len > 0);
        // Located at the offending token, not at the start of the file
        const loc = doc.diagnostics[0].loc;
        try testing.expectEqualStrings(case.culprit, case.source[loc.offset .. loc.offset + loc.length]);
    }
}

test "Compiler: compiles bitwise and shift operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: 10 << 2
    const left = try b.number("10", 0);
    const right = try b.number("2", 0);
    const bin_node = try b.binary(.shift_left, left, right, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(bin_node);

    // Verify correct mapping
    try testing.expectEqual(chunk.OpCode.op_shift_left, @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[4])));
}

test "Compiler: Logical OR short-circuit stack equilibrium" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // AST: true || false
    const left = try b.booleanNode(true, 0);
    const right = try b.booleanNode(false, 0);
    const or_node = try b.binary(.logical_or, left, right, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(or_node);

    // The compilation of the entire script pushes exactly 1 boolean onto the stack,
    // but the `comp.compile(or_node)` method implicitly emits an `op_return` which pops it.
    // Thus, the net stack tracking effect should be exactly 0.
    try testing.expectEqual(@as(usize, 0), comp.current_stack_depth);
    try testing.expectEqual(@as(usize, 1), out_chunk.max_stack_slots);
}

test "Compiler Guardrail: Method call exceeding MAX_ARGS triggers error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const call_name = try b.intern("heavy_method");
    var args = std.ArrayList(ast.NamedArg).empty;
    defer args.deinit(testing.allocator);

    const val = try b.number("1", 0);
    for (0..limits.MAX_ARGS + 1) |_| {
        try args.append(testing.allocator, .{ .name = .none, .value = val, .modifier = null });
    }

    const args_span = try b.addNamedArgs(args.items);
    const call_node = try b.methodCall(.none, call_name, args_span, .none, false, 0, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    const result = comp.compile(call_node);

    // Validate the compiler rejected the oversized payload
    try testing.expectError(error.TooManyArguments, result);
}

test "Compiler Guardrail: Rejects programmatically built deep trees" {
    // The parser bounds depth for source code, but trees built directly with
    // ast.Builder must be rejected by the compiler itself.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    var node = try b.booleanNode(true, 0);
    for (0..limits.MAX_AST_DEPTH + 10) |_| node = try b.unary(.not, node, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try testing.expectError(error.AstTooDeep, comp.compile(node));
}

test "Compiler Guardrail: Nested closures share one depth budget" {
    // Each closure body compiles in a child Compiler; the child used to restart
    // at depth 0, so nested lambdas recursed natively without any bound.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const no_params = try b.addParams(&.{});
    var node = try b.booleanNode(true, 0);
    for (0..limits.MAX_AST_DEPTH + 10) |_| node = try b.lambdaExpr(no_params, node, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try testing.expectError(error.AstTooDeep, comp.compile(node));
}

test "Compiler Guardrail: Inline-cache indexes past 16 bits are a compile error" {
    // Regression: the u16 inline-cache operand used to overflow silently
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // A local's calls, so only the method caches grow (a global's reads have caches too).
    try buf.appendSlice(testing.allocator, "def f\n  x = 1\n");
    for (0..limits.MAX_INLINE_CACHES + 2) |_| try buf.appendSlice(testing.allocator, "  x.foo\n");
    try buf.appendSlice(testing.allocator, "end\n");

    var doc = try Document.parse(testing.allocator, buf.items);
    defer doc.deinit();
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try testing.expectError(error.TooManyInlineCaches, comp.compile(doc.tree.root));
}

/// A parameter-list shape. Frame layout: slot 0 = closure, then the positionals,
/// the kwarg map (if any keyword), the block slot, and one slot per keyword;
/// the highest slot must not exceed MAX_ARGS.
const SlotShape = struct {
    name: []const u8,
    keywords: usize = 0,
    block_param: bool = false,
    block_literal: bool = false,
    /// Most positionals that still fit: one more must be TooManyParameters.
    max_positionals: usize,
};

/// `def f(p0.., k0: 1.., &blk)` returning `p{last} + k{last}`, followed by a call
/// passing 0..positionals-1; or `f do |p0..| 1 end` for block literals.
fn slotShapeSource(shape: SlotShape, positionals: usize) ![]u8 {
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, if (shape.block_literal) "f do |" else "def f(");
    for (0..positionals) |i| try buf.print(a, "{s}p{d}", .{ if (i > 0) ", " else "", i });
    for (0..shape.keywords) |i| try buf.print(a, ", k{d}: {d}", .{ i, i + 1 });
    if (shape.block_param) try buf.appendSlice(a, ", &blk");
    if (shape.block_literal) {
        try buf.appendSlice(a, "|\n  1\nend\n");
    } else {
        try buf.print(a, ")\n  p{d}", .{positionals - 1});
        if (shape.keywords > 0) try buf.print(a, " + k{d}", .{shape.keywords - 1});
        try buf.appendSlice(a, "\nend\nf(");
        for (0..positionals) |i| try buf.print(a, "{s}{d}", .{ if (i > 0) ", " else "", i });
        try buf.appendSlice(a, ")\n");
    }
    return buf.toOwnedSlice(a);
}

test "Compiler Guardrail: Frame-slot check matches the real slot layout" {
    const kw = 6;
    const shapes = [_]SlotShape{
        // Closure slot + positionals + block slot.
        .{ .name = "positional only", .max_positionals = limits.MAX_ARGS - 1 },
        .{ .name = "block literal", .block_literal = true, .max_positionals = limits.MAX_ARGS - 1 },
        // ... + kwarg map + one virtual slot per keyword.
        .{ .name = "positional + kwargs", .keywords = kw, .max_positionals = limits.MAX_ARGS - 2 - kw },
        // &blk reuses the block slot, so it costs nothing extra.
        .{ .name = "positional + kwargs + &blk", .keywords = kw, .block_param = true, .max_positionals = limits.MAX_ARGS - 2 - kw },
    };
    for (shapes) |shape| {
        errdefer std.debug.print("slot shape '{s}' failed\n", .{shape.name});

        // The largest accepted layout compiles (it used to panic computing the
        // virtual keyword slots in a u8) and, for defs, binds every slot correctly.
        const at_max = try slotShapeSource(shape, shape.max_positionals);
        defer testing.allocator.free(at_max);
        if (shape.block_literal) {
            try compileOnly(at_max);
        } else {
            const expected = shape.max_positionals - 1 + shape.keywords;
            try expectRunsTo(at_max, @floatFromInt(expected));
        }

        // One more positional is a clean compile error, not an overflow.
        const over = try slotShapeSource(shape, shape.max_positionals + 1);
        defer testing.allocator.free(over);
        try testing.expectError(error.TooManyParameters, compileOnly(over));
    }
}

test "Compiler Edge Case: Hash literals with > 255 entries emit op_build_map_wide" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    var entries: std.ArrayList(ast.HashEntry) = .empty;
    defer entries.deinit(testing.allocator);

    // One more entry than a u8 count operand can hold
    const val = try b.number("1", 0);
    for (0..limits.MAX_SHORT_CONSTANTS + 1) |i| {
        var buf: [10]u8 = undefined;
        const key_str = try std.mem.print(&buf, "k{d}", .{i});
        const key = try b.stringNode(key_str, 0);
        try entries.append(testing.allocator, .{ .key = key, .value = val });
    }

    const span = try b.addHashEntries(entries.items);
    const map_node = try b.hashLiteral(span, 0, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(map_node);

    // Verify op_build_map_wide is present in the bytecode!
    var found_wide = false;
    for (out_chunk.code.items) |byte| {
        if (byte == @backingInt(chunk.OpCode.op_build_map_wide)) found_wide = true;
    }

    // If it fell back to the standard op_build_map, this will fail
    try testing.expect(found_wide);
}

test "Compiler: Deep namespace constant resolution does not leak memory" {
    const source =
        \\class A
        \\  class B
        \\    class C
        \\      class D
        \\        VAL = 10
        \\      end
        \\    end
        \\  end
        \\end
        \\
        \\return A::B::C::D::VAL
    ;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    // The testing allocator will automatically panic if `emitVariableLoad` fails to free
    // the fully qualified path names during the namespace traversal loop.
    try comp.compile(doc.tree.root);
}

test "Compiler: Destructuring aborts gracefully without stack corruption" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // One more identifier than MAX_SHORT_CONSTANTS
    var elements: std.ArrayList(ast.NodeIndex) = .empty;
    defer elements.deinit(testing.allocator);

    for (0..limits.MAX_SHORT_CONSTANTS + 1) |i| {
        var buf: [16]u8 = undefined;
        const str = try std.mem.print(&buf, "v{d}", .{i});
        const name_id = try b.intern(str);
        // Build raw identifier nodes
        const id_node = try b.createNode(.identifier, 0, @backingInt(name_id));
        try elements.append(testing.allocator, id_node);
    }

    const span = try b.addNodes(elements.items);
    const tuple_node = try b.arrayLiteral(span, 0, 0);

    // Pass the massive array destructuring node as a parameter to a block: `do |(v0...v255)|`
    const block_node = try b.block(&.{tuple_node}, &.{}, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &[_]resolver.ResolvedSymbol{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    // This MUST fail with TooManyConstants. If the `errdefer` stack restoration is missing
    // inside `compileDestructureNode`, the compiler's internal `std.debug.assert` for
    // `current_stack_depth` will instantly panic and crash the test.
    const result = comp.compile(block_node);
    try testing.expectError(error.TooManyConstants, result);
}

test "Compiler: op_switch table entries are emitted in strictly sorted order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // Construct case statement with unsorted keys: when 30, when 10, when 20
    const cond = try b.number("0", 0);

    const w1_cond = try b.addNodes(&.{try b.number("30", 0)});
    const w1_body = try b.number("3", 0);

    const w2_cond = try b.addNodes(&.{try b.number("10", 0)});
    const w2_body = try b.number("1", 0);

    const w3_cond = try b.addNodes(&.{try b.number("20", 0)});
    const w3_body = try b.number("2", 0);

    const branch1 = ast.WhenBranch{ .conditions = w1_cond, .body = w1_body };
    const branch2 = ast.WhenBranch{ .conditions = w2_cond, .body = w2_body };
    const branch3 = ast.WhenBranch{ .conditions = w3_cond, .body = w3_body };

    const branches = try b.addWhenBranches(&.{ branch1, branch2, branch3 });
    const case_node = try b.caseStmt(cond, branches, .none, 0);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(case_node);

    // op_switch sits at code[2], case_count (3) at code[3]
    // Table entries start at byte offset 4 (6 bytes per entry)
    const table_start = 4;

    const readConstVal = struct {
        fn read(ch: *chunk.Chunk, idx: usize) f64 {
            const high: u16 = ch.code.items[idx];
            const low: u16 = ch.code.items[idx + 1];
            const const_idx = (high << 8) | low;
            return ch.constants.items[const_idx].asNumber();
        }
    }.read;

    const val1 = readConstVal(&out_chunk, table_start);
    const val2 = readConstVal(&out_chunk, table_start + 6);
    const val3 = readConstVal(&out_chunk, table_start + 12);

    // Verify the compiler re-ordered [30, 10, 20] -> [10, 20, 30]
    try testing.expectEqual(@as(f64, 10.0), val1);
    try testing.expectEqual(@as(f64, 20.0), val2);
    try testing.expectEqual(@as(f64, 30.0), val3);
}

test "Compiler: case with more than MAX_JUMP_TABLE_CASES literal conditions does not overflow" {
    // The u16 condition counter used to overflow; now falls back to linear compares
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "case 1\nwhen 1");
    for (0..limits.MAX_JUMP_TABLE_CASES + 1) |_| try buf.appendSlice(testing.allocator, ",1");
    try buf.appendSlice(testing.allocator, "\n  10\nend\n");
    try expectRunsTo(buf.items, 10);
}

test "Compiler: case with duplicate literal keys keeps first-match order" {
    // The VM binary-searches the jump table, so equal keys used to resolve to
    // an arbitrary branch instead of the first `when`.
    try expectRunsTo("case 1 when 1 then 10 when 1 then 20 end", 10);
    try expectRunsTo("case \"b\" when \"a\", \"b\" then 1 when \"b\" then 2 else 3 end", 1);
}

test "Compiler: Constant Folding optimizer" {
    const source = "val = 10 * 5.0 + 2";

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    // 1. Verify Top-Level Variables safely remained Globals (0 locals)
    try std.testing.expectEqual(@as(usize, 0), comp.locals.items.len);

    // 2. Verify Constant Folding completely eliminated the math ops from the bytecode stream
    var has_math = false;
    for (main_chunk.code.items) |byte| {
        const op: chunk.OpCode = @fromBackingInt(byte);
        if (op == .op_multiply or op == .op_add) {
            has_math = true;
        }
    }

    // The expression "10 * 5.0 + 2" should have been folded at compile time
    try std.testing.expect(!has_math);
}

/// The constants `source` compiles to (the main chunk's).
fn compiledConstants(allocator: std.mem.Allocator, source: []const u8, out: *std.ArrayList(f64)) !void {
    var vm = try VM.init(allocator, std.testing.io);
    defer vm.deinit();
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(allocator);
    var comp = Compiler.forDocument(allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    for (main_chunk.constants.items) |c| if (c.isNumber()) try out.append(allocator, c.asNumber());
}

test "Compiler: a negated literal, and arithmetic on one, is a single constant" {
    // `-5 * 2` is `(-5) * 2` to the parser, with a negation under the multiplication;
    // the fold stopped at the negation, so 5 and 2 were constants and three ops ran.
    const cases = [_]struct { src: []const u8, folded: f64 }{
        .{ .src = "x = -5 * 2", .folded = -10 },
        .{ .src = "x = -(3 + 4)", .folded = -7 },
        .{ .src = "x = 2 - -3", .folded = 5 },
        .{ .src = "x = --8", .folded = 8 },
    };
    for (cases) |case| {
        var numbers: std.ArrayList(f64) = .empty;
        defer numbers.deinit(std.testing.allocator);
        try compiledConstants(std.testing.allocator, case.src, &numbers);
        try std.testing.expectEqualSlices(f64, &.{case.folded}, numbers.items);
    }
}

test "Compiler: equal literals share one constant slot" {
    // Numbers, strings (by text) and symbols each have one slot however often they appear.
    var numbers: std.ArrayList(f64) = .empty;
    defer numbers.deinit(std.testing.allocator);
    try compiledConstants(std.testing.allocator, "x = [1, 1, 1, 2.5, 2.5, -1, -1]", &numbers);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2.5, -1 }, numbers.items);

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    var doc = try Document.parse(std.testing.allocator, "x = [\"a\", \"a\", :s, :s, \"b\"]");
    defer doc.deinit();
    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);
    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    var strings: usize = 0;
    var symbols: usize = 0;
    for (main_chunk.constants.items) |c| {
        if (c.isString()) strings += 1;
        if (c.isSymbol()) symbols += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), strings); // "a", "b" and the name "x"
    try std.testing.expectEqual(@as(usize, 1), symbols);
}

test "Compiler: Jump patch alignments for nested and/or" {
    // Each jump carries a 4-byte offset; the listed opcodes must sit exactly at
    // these offsets or a jump would land inside an operand.
    const OpAt = struct { usize, chunk.OpCode };
    const cases = [_]struct {
        outer: ast.BinaryOp,
        inner: ast.BinaryOp,
        a: bool,
        expected: []const OpAt,
    }{
        // A and (B or C)
        .{ .outer = .logical_and, .inner = .logical_or, .a = true, .expected = &.{
            .{ 0, .op_true },  .{ 1, .op_jump_if_false }, .{ 6, .op_pop },
            .{ 7, .op_false }, .{ 8, .op_jump_if_false }, .{ 13, .op_jump },
            .{ 18, .op_pop },  .{ 19, .op_true },         .{ 20, .op_return },
        } },
        // A or (B and C)
        .{ .outer = .logical_or, .inner = .logical_and, .a = false, .expected = &.{
            .{ 0, .op_false }, .{ 1, .op_jump_if_false }, .{ 6, .op_jump },
            .{ 11, .op_pop },  .{ 12, .op_true },         .{ 13, .op_jump_if_false },
            .{ 18, .op_pop },  .{ 19, .op_true },         .{ 20, .op_return },
        } },
    };

    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var b = ast.Builder.init(arena.allocator());
        defer b.deinit();

        // Operands: A, B = !A, C = true
        const lhs = try b.booleanNode(c.a, 0);
        const inner = try b.binary(c.inner, try b.booleanNode(!c.a, 0), try b.booleanNode(true, 0), 0);
        const root = try b.binary(c.outer, lhs, inner, 0);

        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(testing.allocator);

        var comp = Compiler.init(testing.allocator, &b.tree, &[_]resolver.ResolvedSymbol{}, &[_]u32{}, &out_chunk, &vm);
        defer comp.deinit();
        try comp.compile(root);

        for (c.expected) |e| {
            try testing.expectEqual(e[1], @as(chunk.OpCode, @fromBackingInt(out_chunk.code.items[e[0]])));
        }
    }
}

test "Compiler: Exhaustive runtime execution of Pratt parser logic jumps" {
    // Tests that the Parser and Compiler integrate perfectly for deeply nested
    // short-circuit paths. If a jump skips the wrong number of bytes,
    // the VM will panic trying to execute the jump offset payload as an instruction.
    const source =
        \\def test_logic(a, b, c, d)
        \\  a and (b or c) and d
        \\end
        \\
        \\[
        \\  test_logic(true, false, false, true),   # true and (false) and true -> false
        \\  test_logic(true, false, true, false),   # true and (true) and false -> false
        \\  test_logic(true, true, false, true),    # true and (true) and true -> true
        \\  test_logic(false, true, true, true),    # false and (...) -> false
        \\  test_logic(true, false, true, true)     # true and (true) and true -> true
        \\]
    ;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    const arr_obj = vm.stack[vm.stack_top - 1].asArray();
    try testing.expectEqual(@as(usize, 5), arr_obj.items.items.len);
    try testing.expectEqual(false, arr_obj.items.items[0].asBool());
    try testing.expectEqual(false, arr_obj.items.items[1].asBool());
    try testing.expectEqual(true, arr_obj.items.items[2].asBool());
    try testing.expectEqual(false, arr_obj.items.items[3].asBool());
    try testing.expectEqual(true, arr_obj.items.items[4].asBool());
}

// --- Non-local jumps out of begin/rescue/ensure must unwind the handler ---

test "Compiler: return inside begin/rescue pops the handler" {
    const source =
        \\def f
        \\  begin
        \\    return 1
        \\  rescue => e
        \\    puts "x"
        \\  end
        \\end
        \\f()
        \\[1].fetch(99).foo
    ;
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const res = try run(&vm, source);
    // A clean uncaught runtime error, not a jump into the stale rescue body
    try testing.expectEqual(.runtime_error, res.status);
}

test "Compiler: break/next out of begin/rescue pops the handler" {
    // The inner rescue must be gone once control leaves it, so only the outer
    // rescue may catch the later error (hits == 1, not 100+). `{0s}` is the
    // looping construct, `{1s}` the jump keyword.
    const template =
        \\def g
        \\  hits = 0
        \\  begin
        \\    {0s}
        \\      begin
        \\        {1s}
        \\      rescue => e
        \\        hits += 100
        \\      end
        \\    end
        \\    [1].fetch(99).foo
        \\  rescue => e
        \\    hits += 1
        \\  end
        \\  hits
        \\end
        \\g()
    ;
    // A `while` loop jumps within the frame; a block returns from its closure
    const loops = .{ "i = 0\n    while i < 3\n      i += 1", "[1, 2, 3].each do |x|" };
    inline for (loops) |loop| {
        inline for (.{ "break", "next" }) |keyword| {
            expectRunsTo(std.fmt.comptimePrint(template, .{ loop, keyword }), 1) catch |err| {
                std.debug.print("rescue case '{s}' / '{s}' failed\n", .{ loop, keyword });
                return err;
            };
        }
    }
}

test "Compiler: return and break out of begin run the ensure body" {
    const source =
        \\def f(log)
        \\  begin
        \\    return 1
        \\  ensure
        \\    log.push(1)
        \\  end
        \\end
        \\def g(log)
        \\  while true
        \\    begin
        \\      break
        \\    rescue => e
        \\      log.push(100)
        \\    ensure
        \\      log.push(10)
        \\    end
        \\  end
        \\  log
        \\end
        \\log = []
        \\f(log)
        \\g(log)
        \\log.size * 1000 + log[0] + log[1]
    ;
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const res = try run(&vm, source);
    try testing.expectEqual(.ok, res.status);
    try testing.expectEqual(@as(f64, 2011), res.top.asNumber());
}

// --- GC rooting of functions under construction ---

/// A swept ObjFunction is dropped from the GC's tracking list but its pointer
/// stays in the constant pool, so "every function constant is still tracked"
/// detects the use-after-free deterministically (the freed slot is often
/// rewritten by the compiler, so behaviour alone can look fine).
fn expectFunctionsTracked(vm: *VM, c: *const chunk.Chunk) !void {
    for (c.constants.items) |val| {
        if (!val.isObject() or val.asObj().obj_type != .function) continue;
        const func: *value.ObjFunction = @alignCast(@fieldParentPtr("obj", val.asObj()));
        var tracked = false;
        for (vm.gc.functions.items) |f| {
            if (f == func) tracked = true;
        }
        try testing.expect(tracked);
        if (func.chunk) |c_ptr| try expectFunctionsTracked(vm, @ptrCast(@alignCast(c_ptr)));
    }
}

test "Compiler: functions stay rooted while def/attr macros allocate under stress GC" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // `audit_gc_greet` is a top-level def whose name is not interned beforehand,
    // so allocating its name string collects while the ObjFunction is fresh.
    // (Method names are interned by makeMethodNameConstant first and can't hit it.)
    const source =
        \\def audit_gc_greet(who)
        \\  "hi " + who
        \\end
        \\class Person
        \\  attr_accessor :name
        \\  attr_reader :age
        \\  def initialize(name, age)
        \\    @name = name
        \\    @age = age
        \\  end
        \\  def label(suffix)
        \\    "person" + suffix
        \\  end
        \\end
        \\p = Person.new("Leo", 30)
        \\p.name = "Leon"
        \\[p.name, p.age, p.label("!"), audit_gc_greet("x")]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    // Collect on every allocation: the function's name string and the child
    // chunk's constants used to be allocated while the ObjFunction was unrooted.
    vm.gc.stress = true;
    const compile_result = comp.compile(doc.tree.root);
    vm.gc.stress = false;
    try compile_result;
    try expectFunctionsTracked(&vm, &out_chunk);

    try testing.expectEqual(.ok, vm.interpret(&out_chunk));
    const arr = vm.stack[vm.stack_top - 1].asArray();
    try testing.expectEqualStrings("Leon", arr.items.items[0].asString().chars);
    try testing.expectEqual(@as(f64, 30), arr.items.items[1].asNumber());
    try testing.expectEqualStrings("person!", arr.items.items[2].asString().chars);
    try testing.expectEqualStrings("hi x", arr.items.items[3].asString().chars);
}

test "Compiler: assignment inside a def makes a method local, never a top-level write" {
    // Methods may read top-level variables, but a plain assignment inside a def (or a block
    // nested in one) always creates a local. Before, it overwrote a top-level variable of the
    // same name, but only when the def came after that variable in the source.
    const cases = [_]struct { src: []const u8, expected: f64 }{
        .{ .src = "x = 1\ndef f\n  x = 2\nend\nf()\nx", .expected = 1 },
        .{ .src = "def f\n  x = 2\nend\nx = 1\nf()\nx", .expected = 1 },
        .{ .src = "x = 1\ndef f\n  x = 2\n  x * 10\nend\nf()", .expected = 20 },
        .{ .src = "a = 1\ndef g\n  a, b = [5, 6]\n  a + b\nend\ng() * 100 + a", .expected = 1101 },
        .{ .src = "e = 7\ndef h\n  begin\n    raise \"boom\"\n  rescue => e\n    1\n  end\nend\nh()\ne", .expected = 7 },
        .{ .src = "n = 5\ndef bump\n  n = 0\n  n += 3\n  n\nend\nbump() * 10 + n", .expected = 35 },
        .{ .src = "x = 1\ndef f\n  [1].each { |i| x = 99 }\n  0\nend\nf()\nx", .expected = 1 },
        .{ .src = "count = 3\nclass C\n  def run\n    count = 100\n    count\n  end\nend\nc = C.new\nc.run + count", .expected = 103 },
        // Unchanged: reads of top-level variables, top-level blocks/lambdas writing them,
        // blocks updating their def's own locals, and $globals.
        .{ .src = "w = 5\ndef area\n  w * 2\nend\narea()", .expected = 10 },
        .{ .src = "total = 0\n[1, 2, 3].each { |i| total = total + i }\ntotal", .expected = 6 },
        .{ .src = "total = 1\nadd = ->(n) { total = total + n }\nadd.call(10)\ntotal", .expected = 11 },
        .{ .src = "def acc\n  sum = 0\n  [1, 2, 3].each { |i| sum = sum + i }\n  sum\nend\nacc()", .expected = 6 },
        .{ .src = "$g = 1\ndef setg\n  $g = 2\nend\nsetg()\n$g", .expected = 2 },
    };
    for (cases) |case| {
        errdefer std.debug.print("script:\n{s}\n", .{case.src});
        try expectRunsTo(case.src, case.expected);
    }
}

test "Compiler: destructured block parameters shadow outer variables like plain ones" {
    // `|(x, y)|` used to write through to an outer `x` (as an upvalue) instead of binding a
    // block-local parameter, so the outer variable changed after the loop.
    const cases = [_]struct { src: []const u8, expected: f64 }{
        .{ .src = "x = 5\n[[1, 2]].each { |(x, y)| x }\nx", .expected = 5 },
        .{ .src = "def f\n  x = 5\n  [[1, 2]].each { |(x, y)| x }\n  x\nend\nf()", .expected = 5 },
        .{ .src = "x = 7\ny = 8\n[[1, [2, 3]]].each { |(x, (y, z))| x }\nx * 10 + y", .expected = 78 },
        // The parameters themselves are bound inside the block.
        .{ .src = "s = 0\n[[1, [2, 3]], [4, [5, 6]]].each { |(a, (b, c))| s = s + a * 100 + b * 10 + c }\ns", .expected = 579 },
        .{ .src = "[[1, 2]].map { |(x, y)| x * 10 + y }[0]", .expected = 12 },
        // Unchanged reference behaviour of a plain parameter.
        .{ .src = "x = 5\n[1].each { |x| x }\nx", .expected = 5 },
    };
    for (cases) |case| {
        errdefer std.debug.print("script:\n{s}\n", .{case.src});
        try expectRunsTo(case.src, case.expected);
    }
}

test "Compiler: `case` picks the `when ... then` branch for constants and names" {
    const cases = [_]struct { src: []const u8, expected: f64 }{
        .{ .src = "case (1..2)\nwhen Range then 1\nelse 2\nend", .expected = 1 },
        .{ .src = "K = 3\ncase 3\nwhen 1 then 10\nwhen K then 30\nend", .expected = 30 },
        .{ .src = "k = 4\ncase 4\nwhen k then 40\nelse 0\nend", .expected = 40 },
        .{ .src = "case \"s\"\nwhen Array then 1\nwhen String then 2\nend", .expected = 2 },
    };
    for (cases) |case| {
        errdefer std.debug.print("script:\n{s}\n", .{case.src});
        try expectRunsTo(case.src, case.expected);
    }
}

fn expectCompileError(source: []const u8, expected: anyerror, line: u32, col: u32, message: []const u8) !void {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try testing.expectError(expected, comp.compile(doc.tree.root));
    const diagnostic = comp.errorDiagnostic() orelse return error.MissingDiagnostic;
    try testing.expectEqualStrings(message, diagnostic.message);
    try testing.expectEqual(line, doc.line_index.getLine(diagnostic.loc.offset) + 1);
    try testing.expectEqual(col, doc.line_index.getUtf8Column(diagnostic.loc.offset) + 1);
}

test "Compiler: a failed compile reports where and why" {
    // Callers could only print the error name, such as "error.ProtectedSymbol".
    try expectCompileError("w = 1\ncube = 5", error.ProtectedSymbol, 2, 1, "'cube' is a built-in and can't be assigned");
    try expectCompileError("def puts(x)\n  x\nend", error.ProtectedSymbol, 1, 1, "'puts' is a built-in and can't be redefined");
    // Inside a def (a child compiler), the error still reaches the caller's compiler.
    try expectCompileError("def f\n  x = 1\n  sphere = 2\nend", error.ProtectedSymbol, 3, 3, "'sphere' is a built-in and can't be assigned");
    try expectCompileError("class Math\nend", error.ProtectedSymbol, 1, 1, "'Math' is a built-in and can't be redefined");

    const many_args = comptime blk: {
        var src: []const u8 = "f(";
        for (0..limits.MAX_ARGS) |_| src = src ++ "1, ";
        break :blk src ++ "1)";
    };
    try expectCompileError(many_args, error.TooManyArguments, 1, 1, "a call takes at most 255 arguments");
}

/// Compiles the single expression `build` makes and returns the compile error's message.
/// The diagnostic of compiling the tree `build` makes, which must fail with `expected`
/// (its message is the caller's to free).
fn compileFailure(build: *const fn (*ast.Builder) anyerror!ast.NodeIndex, expected: anyerror) !Diagnostic {
    var b = ast.Builder.init(testing.allocator);
    defer b.deinit();
    const root = try build(&b);
    const symbols = try testing.allocator.alloc(resolver.ResolvedSymbol, b.tree.nodes.items.len);
    defer testing.allocator.free(symbols);
    @memset(symbols, .{ .kind = .unresolved, .index = 0 });

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &b.tree, symbols, &.{0}, &out_chunk, &vm);
    defer comp.deinit();
    try testing.expectError(expected, comp.compile(root));
    var diagnostic = comp.errorDiagnostic().?;
    diagnostic.message = try testing.allocator.dupe(u8, diagnostic.message);
    return diagnostic;
}

fn straySplat(b: *ast.Builder) anyerror!ast.NodeIndex {
    return b.splatExpr(try b.number("1", 0), 0);
}

test "Compiler: a node it can't compile is an error, not nil" {
    // Unhandled nodes used to compile to nil: a half-built `for` parsed and did nothing.
    // A stray splat was reported as one, but as an internal error, a bug in KupCAD.
    const splat = try compileFailure(straySplat, error.MisplacedSplat);
    defer testing.allocator.free(splat.message);
    try testing.expectEqual(.@"misplaced-splat", splat.code);
    try testing.expectEqualStrings("'*' and '**' only spread values inside an array, a hash or a call's arguments", splat.message);

    // nil and doc comments still compile, now on purpose.
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const res = try run(&vm, "## @label size\nx = nil");
    try testing.expectEqual(.ok, res.status);
}
