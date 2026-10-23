//! VM tests of arrays, maps and ranges: building, indexing, iterating and their methods.

const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../core/document.zig").Document;
const VM = @import("vm.zig").VM;
const helpers = @import("vm_test_helpers.zig");
const executeAndAssertStack = helpers.executeAndAssertStack;
const compileAndRun = helpers.compileAndRun;

test "VM: executes dynamic array building and spreading" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    try out_chunk.writeOp(testing.allocator, .op_build_array, 0);
    try out_chunk.write(testing.allocator, 0, 0);

    const c42 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(c42), 0);
    try out_chunk.writeOp(testing.allocator, .op_array_push, 0);

    const c1 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(1.0));
    const c2 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(2.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(c1), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(c2), 0);
    try out_chunk.writeOp(testing.allocator, .op_build_array, 0);
    try out_chunk.write(testing.allocator, 2, 0);

    try out_chunk.writeOp(testing.allocator, .op_array_spread, 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);
    out_chunk.max_stack_slots = 5;

    const final_arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(final_arr_val.isObject());
    const arr: *value.ObjArray = @alignCast(@fieldParentPtr("obj", final_arr_val.asObj()));
    try testing.expectEqual(@as(usize, 3), arr.items.items.len);
    try testing.expectEqual(@as(f64, 42.0), arr.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 1.0), arr.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 2.0), arr.items.items[2].asNumber());
}

test "VM: op_unpack correctly destructs array into stack slots" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const val1 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(10.0));
    const val2 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(20.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(val1), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(val2), 0);

    try out_chunk.writeOp(testing.allocator, .op_build_array, 0);
    try out_chunk.write(testing.allocator, 2, 0);
    try out_chunk.writeOp(testing.allocator, .op_unpack, 0);
    try out_chunk.write(testing.allocator, 3, 0);
    try out_chunk.writeOp(testing.allocator, .op_pop, 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);
    out_chunk.max_stack_slots = 5;

    const final_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 20.0), final_val.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    // -1 = last, -2 = middle, -3 = first
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[2].asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));

    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 25.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[1].asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 35.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[1].asNumber());
}

test "VM Syntax: Return with multiple comma-separated values returns an Array" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\def get_coords
        \\  return 10, 20, 30
        \\end
        \\get_coords
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
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[2].asNumber());
}

test "VM Syntax: Map compound index assignment (map[:key] += val)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\stats = { "score" => 100, :multiplier => 2 }
        \\stats["score"] += 50
        \\stats[:multiplier] *= 3
        \\[stats["score"], stats[:multiplier]]
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

    // 100 + 50 = 150
    try testing.expectEqual(@as(f64, 150.0), arr_obj.items.items[0].asNumber());
    // 2 * 3 = 6
    try testing.expectEqual(@as(f64, 6.0), arr_obj.items.items[1].asNumber());
}

test "VM Syntax: Multiple assignment handles array padding and trimming accurately" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\# 1. RHS array is too short -> pad missing variables with nil
        \\x, y, z = [10]
        \\
        \\# 2. RHS array is too long -> trim excess elements
        \\a, b = [100, 200, 300, 400]
        \\
        \\[x, y.nil?, z.nil?, a, b]
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

    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber()); // x = 10
    try testing.expectEqual(true, arr_obj.items.items[1].asBool()); // y = nil
    try testing.expectEqual(true, arr_obj.items.items[2].asBool()); // z = nil
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[3].asNumber()); // a = 100
    try testing.expectEqual(@as(f64, 200.0), arr_obj.items.items[4].asNumber()); // b = 200
}

test "VM Syntax: Negative array index compound assignment (arr[-1] += val)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\arr = [10, 20, 30]
        \\arr[-1] += 15
        \\arr[-2] *= 2
        \\[arr[0], arr[1], arr[2]]
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
    try testing.expectEqual(@as(f64, 40.0), arr_obj.items.items[1].asNumber()); // 20 * 2
    try testing.expectEqual(@as(f64, 45.0), arr_obj.items.items[2].asNumber()); // 30 + 15
}

test "VM: decompose() splits disjoint bodies into an array" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Union two cubes that don't touch, then decompose them back into 2 parts
    const source =
        \\c1 = cube(10).translate(-50, 0, 0)
        \\c2 = cube(10).translate(50, 0, 0)
        \\fused = c1 + c2
        \\parts = fused.decompose
        \\parts
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
    const arr = result.asArray().items.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expect(arr[0].isGeometry());
    try testing.expect(arr[1].isGeometry());
}

test "VM: Array#sort natively evaluates iterative QuickSort" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests both implicit native sorting and explicit custom block sorting
    const source =
        \\arr1 = [5, 1, 4, 2, 3].sort
        \\arr2 = ["charlie", "alpha", "bravo"].sort
        \\arr3 = [2, 5, 1].sort { |a, b| b <=> a } # Reverse sort
        \\arr4 = ["a", "ccc", "bb"].sort { |a, b| a.length <=> b.length } # Sort by property
        \\[arr1, arr2, arr3, arr4]
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
    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    // arr1: [1, 2, 3, 4, 5]
    const a1 = arr_obj.items.items[0].asArray().items.items;
    try testing.expectEqual(@as(f64, 1.0), a1[0].asNumber());
    try testing.expectEqual(@as(f64, 5.0), a1[4].asNumber());

    // arr2: ["alpha", "bravo", "charlie"]
    const a2 = arr_obj.items.items[1].asArray().items.items;
    try testing.expectEqualStrings("alpha", a2[0].asString().chars);
    try testing.expectEqualStrings("charlie", a2[2].asString().chars);

    // arr3: [5, 2, 1]
    const a3 = arr_obj.items.items[2].asArray().items.items;
    try testing.expectEqual(@as(f64, 5.0), a3[0].asNumber());
    try testing.expectEqual(@as(f64, 1.0), a3[2].asNumber());

    // arr4: ["a", "bb", "ccc"]
    const a4 = arr_obj.items.items[3].asArray().items.items;
    try testing.expectEqualStrings("a", a4[0].asString().chars);
    try testing.expectEqualStrings("ccc", a4[2].asString().chars);
}

test "VM: Array#sort and Array#reduce handle empty and single-element arrays safely" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\[
        \\  [].sort,
        \\  [42].sort,
        \\  [].reduce(10) { |acc, x| acc + x },
        \\  [].reduce { |acc, x| acc + x }
        \\]
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
    try std.testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    try std.testing.expectEqual(@as(usize, 0), arr_obj.items.items[0].asArray().items.items.len);
    try std.testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[1].asArray().items.items[0].asNumber());
    try std.testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[2].asNumber());
    try std.testing.expect(arr_obj.items.items[3].isNil());
}

test "VM: Array Concatenation roots operands safely" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source = "[1, 2] + [3, 4]";

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
    try testing.expectEqual(@as(usize, 4), arr.items.items.len);
    try testing.expectEqual(@as(f64, 4.0), arr.items.items[3].asNumber());
}

test "VM: Native memory allocation strictly respects limits and refuses to grow Array lists" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();

    // Lock the sandbox to exactly its baseline init size + 1KB for safety bounds
    vm.gc.max_memory_limit = vm.gc.bytes_allocated + 1024;

    // Trigger an out-of-memory array allocation dynamically
    const source =
        \\arr = []
        \\i = 0
        \\while i < 1000
        \\  arr.push(10)
        \\  i += 1
        \\end
    ;

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // It should cleanly catch the out of bounds expansion instead of crashing!
    const result = vm.interpret(&out_chunk);
    try std.testing.expectEqual(.runtime_error, result);
}

test "VM: Map#to_a, Map#map, and Array#to_h convert seamlessly" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. `orig.to_a()` natively extracts pairs to [[k, v], ...]
    // 2. `orig.map()` without block routes securely through the same to_a logic
    // 3. `pairs.to_h()` flawlessly reconstructs it
    // 4. Checking against order-independent keys ensures Hash wyhash randomness doesn't flake the test
    const source =
        \\orig = { a: 10, b: 20 }
        \\
        \\pairs_a = orig.to_a
        \\pairs_b = orig.map
        \\rebuilt = pairs_a.to_h
        \\
        \\custom_h = orig.map { |k, v| [k, v * 2] }.to_h
        \\
        \\[pairs_a.length, pairs_b.length, rebuilt[:a], rebuilt[:b], custom_h[:a], custom_h[:b]]
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
    try std.testing.expectEqual(@as(usize, 6), arr_obj.items.items.len);

    try std.testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[0].asNumber()); // to_a() length
    try std.testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[1].asNumber()); // map() fallback length

    // Original values properly reconstructed via to_h()
    try std.testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[2].asNumber()); // rebuilt[:a]
    try std.testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[3].asNumber()); // rebuilt[:b]

    // Custom block multipliers evaluated properly
    try std.testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[4].asNumber()); // custom_h[:a]
    try std.testing.expectEqual(@as(f64, 40.0), arr_obj.items.items[5].asNumber()); // custom_h[:b]
}

test "VM: Array concatenation via op_add" {
    // Tests that [1, 2] + [3, 4] natively merges into [1, 2, 3, 4]
    const source =
        \\a = [1, 2]
        \\b = [3, 4]
        \\a + b
    ;

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();
    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &main_chunk, 1);
    try std.testing.expect(result.isObject());
    try std.testing.expectEqual(.array, result.asObj().obj_type);

    const arr = result.asArray();
    try std.testing.expectEqual(@as(usize, 4), arr.items.items.len);

    // Verify values were copied faithfully
    try std.testing.expectEqual(@as(f64, 1.0), arr.items.items[0].asNumber());
    try std.testing.expectEqual(@as(f64, 2.0), arr.items.items[1].asNumber());
    try std.testing.expectEqual(@as(f64, 3.0), arr.items.items[2].asNumber());
    try std.testing.expectEqual(@as(f64, 4.0), arr.items.items[3].asNumber());
}

// Number -> integer conversions: NaN, inf and out-of-range operands
test "VM: bitwise operands and array indexes reject non-integral numbers" {
    // `message` set: the expression must raise that; otherwise it evaluates to `number`.
    // Each case used to reach @intFromFloat unchecked (a panic in Debug, UB in release).
    const cases = [_]struct { expr: []const u8, number: f64 = 0, message: ?[]const u8 = null }{
        // Addition shared the bitwise path and converted its operands too
        .{ .expr = "1e300 + huge", .number = 2e300 },
        .{ .expr = "inf_v - 1", .number = std.math.inf(f64) },
        .{ .expr = "inf_v | 1", .message = "RangeError" },
        // inf - inf is the NaN that reaches bytecode (multiply/divide raise on NaN)
        .{ .expr = "(inf_v - inf_v) ^ 1", .message = "RangeError" },
        .{ .expr = "1 & huge", .message = "RangeError" },
        .{ .expr = "1 << 64", .message = "Shift count" },
        .{ .expr = "1 >> -1", .message = "Shift count" },
        .{ .expr = "1 << inf_v", .message = "RangeError" },
        // In-range behaviour is unchanged: truncation, wrapping `<<`, arithmetic `>>`
        .{ .expr = "6 & 3", .number = 2 },
        .{ .expr = "5.9 | 0", .number = 5 },
        .{ .expr = "-8 >> 1", .number = -4 },
        .{ .expr = "1 << 63", .number = -0x1p63 },
        .{ .expr = "[1, 2][inf_v]", .message = "out of bounds" },
        .{ .expr = "[1, 2][-inf_v]", .message = "out of bounds" },
        .{ .expr = "[1, 2][huge]", .message = "out of bounds" },
        .{ .expr = "[1, 2][-1]", .number = 2 },
        .{ .expr = "a = [1, 2]\n  a[inf_v] = 3", .message = "out of bounds" },
    };
    for (cases) |case| {
        errdefer std.debug.print("failing case: {s}\n", .{case.expr});
        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        try registry.registerStandardLibrary(&vm);
        vm.mute_errors = true;
        // Scripts can't make Infinity (arithmetic raises RangeError), but a host can pass
        // one in, as `--param x=inf` does.
        try vm.setGlobal("inf_v", value.Value.initNumber(std.math.inf(f64)));

        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(testing.allocator);

        // Operands come from variables so the compiler cannot constant-fold them
        const source = try testing.allocator.print(
            \\huge = 1e300
            \\result = begin
            \\  {s}
            \\rescue RangeError => e
            \\  "RangeError: " + e.message
            \\rescue IndexError => e
            \\  "IndexError: " + e.message
            \\end
        , .{case.expr});
        defer testing.allocator.free(source);

        try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
        const result = vm.globals.get("result") orelse return error.MissingGlobal;
        if (case.message) |message| {
            try testing.expect(result.isString());
            try testing.expect(std.mem.find(u8, result.asString().chars, message) != null);
        } else {
            try testing.expect(result.isNumber());
            try testing.expectEqual(case.number, result.asNumber());
        }
    }
}
