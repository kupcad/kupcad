//! VM tests of strings and symbols: interpolation, formatting, inspection and String methods.

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
const helpers = @import("vm_test_helpers.zig");
const executeAndAssertStack = helpers.executeAndAssertStack;

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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber()); // m2[:a]
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[1].asNumber()); // m3["a"]

    // :test.to_s() == "test"
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", arr_obj.items.items[2].asObj()));
    try testing.expectEqualStrings("test", str_obj.chars);

    // "test".to_sym() == :test
    try testing.expectEqual(true, arr_obj.items.items[3].asBool());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const outer_arr = result.asArray().items.items;

    // Check String Concatenation
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", outer_arr[0].asObj()));
    try testing.expectEqualStrings("Hello World", str_obj.chars);

    // Check Array Concatenation
    const inner_arr = outer_arr[1].asArray().items.items;
    try testing.expectEqual(@as(usize, 4), inner_arr.len);
    try testing.expectEqual(@as(f64, 1.0), inner_arr[0].asNumber());
    try testing.expectEqual(@as(f64, 4.0), inner_arr[3].asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", result.asObj()));
    try testing.expectEqualStrings("Result: 12!", str_obj.chars);
}

test "VM: String interpolation supports Numbers and Booleans" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source = "\"Test #{42} - #{true}\"";

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    _ = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expect(vm.stack[0].isString());
    try testing.expectEqualStrings("Test 42 - true", vm.stack[0].asString().chars);
}

test "VM Syntax: Percent word (%w) and symbol (%i) array literals compile to valid arrays" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\words = %w[gear shaft motor]
        \\symbols = %i[r h d]
        \\[words.length(), symbols[0] == :r]
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
    try testing.expectEqual(true, arr_obj.items.items[1].asBool());
}

test "VM: Heredoc strings evaluate and assign correctly" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\example_text = <<EOF
        \\line 1
        \\line 2
        \\EOF
        \\example_text
    ;

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(std.testing.allocator);
    var comp = Compiler.forDocument(std.testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try std.testing.expect(result.isString());
    try std.testing.expectEqualStrings("line 1\nline 2\n", result.asString().chars);
}

test "VM: String#length and String#size evaluate correctly" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\["hello".length, "world".size, "".length]
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
    try std.testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[0].asNumber());
    try std.testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[1].asNumber());
    try std.testing.expectEqual(@as(f64, 0.0), arr_obj.items.items[2].asNumber());
}

test "VM: Heredoc strings act as raw strings (no interpolation)" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Because it acts like a single-quoted string, `#{val}` should not be evaluated.
    const source =
        \\val = 42
        \\example_text = <<EOF
        \\The value is #{val}
        \\EOF
        \\example_text
    ;

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(std.testing.allocator);
    var comp = Compiler.forDocument(std.testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try std.testing.expect(result.isString());

    // Asserts that the interpolation syntax was ignored and treated as raw text
    try std.testing.expectEqualStrings("The value is #{val}\n", result.asString().chars);
}

test "VM: String ranges root boundary strings safely" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Evaluates "a", evaluates "c", then allocates an array to hold the range
    const source = "('a'..'c')";

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
    try testing.expectEqual(@as(usize, 3), arr.items.items.len); // ["a", "b", "c"]

    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", arr.items.items[2].asObj()));
    try testing.expectEqualStrings("c", str_obj.chars);
}

test "VM: op_switch binary search handles mixed numbers and strings safely" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\def test_mixed(x)
        \\  case x
        \\  when "apple"
        \\    1
        \\  when 20
        \\    2
        \\  when "banana"
        \\    3
        \\  when 5
        \\    4
        \\  else
        \\    0
        \\  end
        \\end
        \\
        \\res_num = test_mixed(20)
        \\res_str = test_mixed("banana")
        \\res_miss = test_mixed("cherry")
        \\[res_num, res_str, res_miss]
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

    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 0.0), arr_obj.items.items[2].asNumber());
}

test "VM: op_add gracefully falls back to heap for strings exceeding 1KB" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Exponentially double a string's length 11 times.
    // Length starts at 1, ends at 2^11 = 2048 bytes.
    // This explicitly forces op_add to breach the 1024 MAX_STACK_STRING_LEN
    // and utilize the heap fallback path without leaking memory.
    const source =
        \\s = "A"
        \\i = 0
        \\while i < 11
        \\  s = s + s
        \\  i = i + 1
        \\end
        \\s.length()
    ;

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Execute with strict stack equilibrium to ensure the temporary heap buffer is freed
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try std.testing.expect(result.isNumber());
    try std.testing.expectEqual(@as(f64, 2048.0), result.asNumber());
}

test "VM: op_interpolate gracefully falls back to heap for strings exceeding 1KB" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Build a 1024-byte string, then interpolate it three times into a single expression.
    // The resulting string will be 3072 bytes, forcing the FBA to return OutOfMemory,
    // which triggers the dynamic ArrayList heap fallback.
    const source =
        \\base = "A"
        \\i = 0
        \\while i < 10
        \\  base = base + base
        \\  i = i + 1
        \\end
        \\res = "#{base}#{base}#{base}"
        \\res.length()
    ;

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Execute with strict stack equilibrium to ensure the ArrayList fallback cleans up correctly
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try std.testing.expect(result.isNumber());
    try std.testing.expectEqual(@as(f64, 3072.0), result.asNumber());
}
