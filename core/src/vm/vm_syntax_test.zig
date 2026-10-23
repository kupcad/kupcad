//! VM tests of the language's expressions and control flow: operators, assignments,
//! conditionals, loops, case, modifiers, safe navigation and the other syntax forms.

const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../frontend/document.zig").Document;
const VM = @import("vm.zig").VM;
const helpers = @import("vm_test_helpers.zig");
const executeAndAssertStack = helpers.executeAndAssertStack;

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

    const final_value = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(final_value.isNumber());
    try testing.expectEqual(@as(f64, -30.0), final_value.asNumber());
}

test "VM: natively executes op_switch jump table" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const test_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));
    const case1_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(10.0));
    const case2_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(test_val), 0);
    try out_chunk.writeOp(testing.allocator, .op_switch, 0);
    try out_chunk.write(testing.allocator, 2, 0);

    try out_chunk.write(testing.allocator, @intCast((case1_val >> 8) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast(case1_val & 0xFF), 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);

    try out_chunk.write(testing.allocator, @intCast((case2_val >> 8) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast(case2_val & 0xFF), 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 3, 0);

    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 6, 0);

    const b1_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(100.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(b1_val), 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    const b2_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(200.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(b2_val), 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    const bdef_val = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(300.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(bdef_val), 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);
    out_chunk.max_stack_slots = 5;

    const final_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 200.0), final_val.asNumber());
}

test "VM: executes logical short-circuiting and comparisons correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const five = try b.number("5", 0);
    const three = try b.number("3", 0);
    const gte_node = try b.binary(.greater_equal, five, three, 0);

    var chunk1 = chunk.Chunk.init();
    defer chunk1.free(testing.allocator);
    var comp1 = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &chunk1, &vm);
    defer comp1.deinit();
    try comp1.compile(gte_node);

    const result1 = try executeAndAssertStack(&vm, &chunk1, 1);
    try testing.expectEqual(true, result1.asBool());

    vm.stack_top = 0; // Reset

    const f_node = try b.booleanNode(false, 0);
    const num_node = try b.number("100", 0);
    const and_node = try b.binary(.logical_and, f_node, num_node, 0);

    var chunk2 = chunk.Chunk.init();
    defer chunk2.free(testing.allocator);
    var comp2 = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &chunk2, &vm);
    defer comp2.deinit();
    try comp2.compile(and_node);

    const result2 = try executeAndAssertStack(&vm, &chunk2, 1);
    try testing.expectEqual(false, result2.asBool());
}

test "VM: defined? is nil for a missing name and true for a local" {
    // It built a `defined_expr` node by hand, a shape the parser never made; `defined?` is
    // the call the compiler turns into a check (manifest's `defined_chk`).
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var doc = try Document.parse(testing.allocator, "here = 1\n[defined?(missing_var), defined?(here)]");
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const items = result.asArray().items.items;
    try testing.expect(items[0].isNil());
    try testing.expectEqual(true, items[1].asBool());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 7.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Result should be an array: [20, 30]
    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(arr_val.isObject() and arr_val.asObj().obj_type == .array);

    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[1].asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Stack: [Point closure, [15, 40]]
    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(arr_val.isArray());

    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 15.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 40.0), arr_obj.items.items[1].asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));

    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[0].asNumber()); // false || 42 -> 42
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[1].asNumber()); // 100 || 50 -> 100
    try testing.expectEqual(true, arr_obj.items.items[2].asBool()); // !nil -> true
    try testing.expectEqual(false, arr_obj.items.items[3].asBool()); // !10 -> false
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", result.asObj()));
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // The stack must contain EXACTLY 1 item (the final result: 60.0).
    // If it contains 4, the compiler is leaking assignment expressions
    try testing.expectEqual(@as(f64, 60.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // The entire script must collapse perfectly back down to exactly 1 return value
    try testing.expectEqual(@as(f64, 7.0), result.asNumber());
}

test "VM Syntax: Trailing statement modifiers (if, unless, while, until) execute correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\x = 10 if true
        \\y = 20 unless false
        \\c1 = 0
        \\c1 += 1 while c1 < 5
        \\c2 = 0
        \\c2 += 1 until c2 == 5
        \\[x, y, c1, c2]
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
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[2].asNumber());
    try testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[3].asNumber());
}

test "VM Syntax: Case statement handles multiple comma-separated conditions per when clause" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def classify(val)
        \\  case val
        \\  when 1, 2, 3
        \\    100
        \\  when 4, 5
        \\    200
        \\  else
        \\    300
        \\  end
        \\end
        \\[classify(2), classify(5), classify(9)]
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
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 200.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 300.0), arr_obj.items.items[2].asNumber());
}

test "VM Syntax: Chained assignments evaluate with right-associativity" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\a = b = c = 42
        \\[a, b, c]
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
    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[2].asNumber());
}

test "VM: Condition-less case statements execute as sequential boolean checks" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\x = 10
        \\y = 20
        \\res = case
        \\when x == 100
        \\  "first"
        \\when y == 20
        \\  "second"
        \\else
        \\  "fallback"
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
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", result.asObj()));
    try testing.expectEqualStrings("second", str_obj.chars);
}

test "VM: Evaluates static multiple assignment optimization (Deficit and Excess)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests deficit (c gets nil) and excess (5 is popped and ignored) without allocating an array
    const source =
        \\a, b, c = 1, 2
        \\d, e = 3, 4, 5
        \\[c, e]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expect(arr_val.isObject() and arr_val.asObj().obj_type == .array);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));

    try testing.expect(arr_obj.items.items[0].isNil()); // 'c' should be nil
    try testing.expectEqual(@as(f64, 4.0), arr_obj.items.items[1].asNumber()); // 'e' should be 4
}

test "VM: Property assignments and invoke fallbacks trigger Polymorphic Inline Caching" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // This script passes two different class instances through the same function.
    // `obj.val = 42` compiles to `op_set_property`.
    // `obj.val` compiles to `op_invoke` (0 args), which falls back to property lookup.
    // Both operations should successfully populate slots 1 and 2 of their respective Inline Caches!
    const source =
        \\class ItemA
        \\end
        \\class ItemB
        \\end
        \\
        \\def process(obj)
        \\  obj.val = 42
        \\  obj.val
        \\end
        \\
        \\process(ItemA.new)
        \\process(ItemB.new)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    // Catch syntax errors immediately before they corrupt the test
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Safely check the type without panicking
    try testing.expect(result.isNumber());
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());

    // Extract the `process` function's chunk to inspect its caches
    var process_chunk: ?*chunk.Chunk = null;
    for (out_chunk.constants.items) |c_val| {
        if (c_val.isObject() and c_val.asObj().obj_type == .function) {
            const func: *value.ObjFunction = @alignCast(@fieldParentPtr("obj", c_val.asObj()));
            if (func.name != null and std.mem.eql(u8, func.name.?.chars, "process")) {
                process_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(func.chunk.?)));
                break;
            }
        }
    }

    try testing.expect(process_chunk != null);

    // We expect the caches to be fully polymorphic (both slots filled)
    var polymorphic_count: usize = 0;
    for (process_chunk.?.inline_caches.items) |ic| {
        if (ic.cached_class_1 != null and ic.cached_class_2 != null) {
            polymorphic_count += 1;
        }
    }

    // There should be exactly two polymorphic hits: one for op_set_property, one for op_invoke
    try testing.expectEqual(@as(usize, 2), polymorphic_count);
}

test "VM: Spaceship Operator (<=>) natively compares types" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests: Number vs Number, String vs String, and fallback (nil)
    const source =
        \\[
        \\  10 <=> 20,
        \\  20 <=> 10,
        \\  10 <=> 10,
        \\  "apple" <=> "banana",
        \\  "zebra" <=> "alpha",
        \\  "same" <=> "same",
        \\  10 <=> "10"
        \\]
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

    try testing.expectEqual(@as(usize, 7), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, -1.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 1.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 0.0), arr_obj.items.items[2].asNumber());
    try testing.expectEqual(@as(f64, -1.0), arr_obj.items.items[3].asNumber());
    try testing.expectEqual(@as(f64, 1.0), arr_obj.items.items[4].asNumber());
    try testing.expectEqual(@as(f64, 0.0), arr_obj.items.items[5].asNumber());
    try testing.expect(arr_obj.items.items[6].isNil()); // Type mismatch
}

test "VM: Augmented assignments (%=, **=, &=) evaluate correctly" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\a = 11
        \\a %= 3
        \\b = 2
        \\b **= 4
        \\c = 3
        \\c &= 1
        \\[a, b, c]
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
    try std.testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[0].asNumber());
    try std.testing.expectEqual(@as(f64, 16.0), arr_obj.items.items[1].asNumber());
    try std.testing.expectEqual(@as(f64, 1.0), arr_obj.items.items[2].asNumber());
}

test "VM: Parentheses gracefully ignore internal newlines" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();

    const source =
        \\val = (
        \\  10 + 20
        \\)
        \\val
    ;

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(std.testing.allocator);
    var comp = Compiler.forDocument(std.testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try std.testing.expectEqual(@as(f64, 30.0), result.asNumber());
}

test "VM: Bitwise and shift operators evaluate correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // 10 | 2 = 10 (1010 | 0010 = 1010)
    // 10 ^ 2 = 8  (1010 ^ 0010 = 1000)
    // 10 << 2 = 40
    // 10 >> 1 = 5
    const source =
        \\[ 10 | 2, 10 ^ 2, 10 << 2, 10 >> 1 ]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Run execution and verify stack equilibrium
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Validate results array
    const arr_obj = result.asArray();
    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 8.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 40.0), arr_obj.items.items[2].asNumber());
    try testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[3].asNumber());
}

test "VM: op_switch binary search correctly matches first, middle, last, and missing cases" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\def test_switch(x)
        \\  case x
        \\  when 50
        \\    "fifty"
        \\  when 10
        \\    "ten"
        \\  when 30
        \\    "thirty"
        \\  else
        \\    "default"
        \\  end
        \\end
        \\
        \\a = test_switch(10)  # Tests first element after sorting
        \\b = test_switch(30)  # Tests middle element
        \\c = test_switch(50)  # Tests last element after sorting
        \\d = test_switch(99)  # Tests missing key / else fallback
        \\[a, b, c, d]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    // Enforces zealous GC mode and asserts expected_stack_top == 1
    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(arr_val.isArray());

    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    try testing.expectEqualStrings("ten", arr_obj.items.items[0].asString().chars);
    try testing.expectEqualStrings("thirty", arr_obj.items.items[1].asString().chars);
    try testing.expectEqualStrings("fifty", arr_obj.items.items[2].asString().chars);
    try testing.expectEqualStrings("default", arr_obj.items.items[3].asString().chars);
}

test "VM: Constant Folding evaluates all arithmetic operations correctly" {
    // These expressions will all be evaluated at compile-time by the Peephole Optimizer
    const source =
        \\ [
        \\   10 + 5,      # 15
        \\   10 - 5,      # 5
        \\   10 * 5,      # 50
        \\   10 / 2,      # 5
        \\   10 % 3,      # 1
        \\   2 ** 3,      # 8
        \\   (2 + 3) * 4  # 20
        \\ ]
    ;

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();

    // Register standard library so we have Array methods
    try registry.registerStandardLibrary(&vm);

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Use the strict helper to catch leaks and get the final yielded array
    const final_val = try executeAndAssertStack(&vm, &main_chunk, 1);

    try std.testing.expect(final_val.isObject() and final_val.asObj().obj_type == .array);

    const arr = final_val.asArray().items.items;
    try std.testing.expectEqual(@as(f64, 15.0), arr[0].asNumber());
    try std.testing.expectEqual(@as(f64, 5.0), arr[1].asNumber());
    try std.testing.expectEqual(@as(f64, 50.0), arr[2].asNumber());
    try std.testing.expectEqual(@as(f64, 5.0), arr[3].asNumber());
    try std.testing.expectEqual(@as(f64, 1.0), arr[4].asNumber());
    try std.testing.expectEqual(@as(f64, 8.0), arr[5].asNumber());
    try std.testing.expectEqual(@as(f64, 20.0), arr[6].asNumber());
}

test "VM: unary + and ~ work on numbers and reject the rest" {
    // Both parsed, but the compiler had no case for them: "internal compiler error".
    const support = @import("../test_support.zig");
    try support.expectScripts(&.{
        .{ .src = "r = [~5, +3, ~-1, +(-2), ~2.9]", .expected = .{ .nums = &.{ -6, 3, 0, -2, -3 } } },
        .{ .src = support.rescued("~\"s\""), .expected = .{ .str = "TypeError: unary '~' expects a number, got String" } },
        .{ .src = support.rescued("+nil"), .expected = .{ .str = "TypeError: unary '+' expects a number, got nil" } },
        .{ .src = support.rescued("~1e300"), .expected = .{ .str = "RangeError: Bitwise operand 1e300 is not a finite 64-bit integer." } },
    });
}
