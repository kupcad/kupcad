//! VM tests of classes and modules: methods, super, attributes, class methods and variables,
//! singletons, mixins, constructors and visibility.

const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../frontend/document.zig").Document;
const VM = @import("vm.zig").VM;
const helpers = @import("vm_test_helpers.zig");
const support = @import("../test_support.zig");
const executeAndAssertStack = helpers.executeAndAssertStack;
const writeGlobalOp = helpers.writeGlobalOp;
const compileAndRun = helpers.compileAndRun;
const expectGlobalString = helpers.expectGlobalString;

test "VM: Math module namespace and functions" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Prove Math::PI via property access
    const math_str = try out_chunk.addConstant(testing.allocator, try vm.allocateString("Math"));
    const pi_str = try out_chunk.addConstant(testing.allocator, try vm.allocateString("PI"));

    try writeGlobalOp(&out_chunk, .op_get_global, math_str);
    try out_chunk.writeOp(testing.allocator, .op_get_property, 0);
    try out_chunk.write(testing.allocator, @intCast(pi_str), 0);

    // --- MANUAL INLINE CACHE ---
    const ic_idx1 = try out_chunk.addInlineCache(testing.allocator);
    try out_chunk.write(testing.allocator, @intCast((ic_idx1 >> 8) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast(ic_idx1 & 0xFF), 0);

    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 5;

    const final_value = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, std.math.pi), final_value.asNumber());

    // Clean up and prove Math.sin(0) = 0
    vm.stack_top = 0;
    out_chunk.code.clearRetainingCapacity();

    const sin_str = try out_chunk.addConstant(testing.allocator, try vm.allocateString("sin"));
    const arg_0 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(0));

    try writeGlobalOp(&out_chunk, .op_get_global, math_str); // Receiver (Math)
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(arg_0), 0); // Argument (0)

    try out_chunk.writeOp(testing.allocator, .op_invoke, 0); // Invoke method on receiver
    try out_chunk.write(testing.allocator, @intCast(sin_str), 0);
    try out_chunk.write(testing.allocator, 1, 0); // 1 arg
    try out_chunk.write(testing.allocator, 0, 0); // CallFlags

    // --- MANUAL INLINE CACHE ---
    const ic_idx2 = try out_chunk.addInlineCache(testing.allocator);
    try out_chunk.write(testing.allocator, @intCast((ic_idx2 >> 8) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast(ic_idx2 & 0xFF), 0);

    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    const result_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 0.0), result_val.asNumber());
}

test "VM: String Native Methods (split, replace)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    // Built by hand, so registered as the compiler registers its chunks: under -Dgc-stress the
    // values it holds were swept before the run began.
    try vm.gc.trackChunk(&out_chunk);

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
    try out_chunk.write(testing.allocator, 0, 0); // CallFlags

    // --- MANUAL INLINE CACHE ---
    const ic_idx = try out_chunk.addInlineCache(testing.allocator);
    try out_chunk.write(testing.allocator, @intCast((ic_idx >> 8) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast(ic_idx & 0xFF), 0);

    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 5;
    const arr = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(arr.isObject() and arr.asObj().obj_type == .array);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr.asObj()));
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
    try out_chunk.write(testing.allocator, 0, 0); // CallFlags

    // --- MANUAL INLINE CACHE ---
    const ic_idx = try out_chunk.addInlineCache(testing.allocator);
    try out_chunk.write(testing.allocator, @intCast((ic_idx >> 8) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast(ic_idx & 0xFF), 0);

    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 6;
    const slice_arr = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expect(slice_arr.isObject() and slice_arr.asObj().obj_type == .array);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", slice_arr.asObj()));

    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[1].asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expectEqual(@as(f64, 10.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());
}

test "VM: Explicit block capturing (&block) and first-class invocation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\def run_block(&b)
        \\  b.call(42)
        \\end
        \\run_block { |x| x * 2 }
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // We intentionally DO NOT override doc.symbols here, so `x` stays a clean local!

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 84.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Result should be an array: [3, 4]
    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
    try testing.expectEqual(@as(usize, 6), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 9.0), arr_obj.items.items[0].asNumber()); // max
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[1].asNumber()); // min
    try testing.expectEqual(@as(f64, 16.0), arr_obj.items.items[2].asNumber()); // sum
    try testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[3].asNumber()); // first
    try testing.expectEqual(@as(f64, 9.0), arr_obj.items.items[4].asNumber()); // last
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[5].asNumber()); // flat length
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
    try testing.expectEqual(@as(usize, 6), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 3.14), arr_obj.items.items[0].asNumber()); // round(2)
    try testing.expectEqual(@as(f64, 4.0), arr_obj.items.items[1].asNumber()); // ceil()
    try testing.expectEqual(@as(f64, 3.0), arr_obj.items.items[2].asNumber()); // floor()

    // 42.to_s() == "42"
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", arr_obj.items.items[3].asObj()));
    try testing.expectEqualStrings("42", str_obj.chars);

    try testing.expectEqual(@as(f64, 42.5), arr_obj.items.items[4].asNumber()); // "42.5".to_f()
    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[5].asNumber()); // "42".to_i()
}

test "VM: case statement subsumption (===) with ranges and classes" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[0].asNumber()); // Matches Class
    try testing.expectEqual(@as(f64, 200.0), arr_obj.items.items[1].asNumber()); // Matches Range
    try testing.expectEqual(@as(f64, 300.0), arr_obj.items.items[2].asNumber()); // Fallback
}

test "VM: case matches a class as is_a? does, a built-in value's too" {
    try support.expectScripts(&.{.{
        .src =
        \\def kind(x)
        \\  case x
        \\  when Solid
        \\    "solid"
        \\  when Path
        \\    "path"
        \\  when Proc
        \\    "proc"
        \\  when Number
        \\    "number"
        \\  when Object
        \\    x.is_a?(String) ? "string" : "other"
        \\  end
        \\end
        \\r = [cube(1), polyline([[0, 0], [1, 1]]), -> { 1 }, 2, "s", :sym].map { |x| kind(x) }.join(",")
        ,
        .expected = .{ .str = "solid,path,proc,number,string,other" },
    }});
}

test "VM: a shape's class is its kind, each a Shape, printed without being built" {
    try support.expectScripts(&.{
        .{ .src = "r = [cube(1), square(1), line([0, 0], [1, 0]), assemble(name: \"Arm\", parts: [cube(1)])].map { |x| x.class }.join(\",\")", .expected = .{ .str = "Solid,Sketch,Path,Assembly" } },
        .{ .src = "r = [cube(1), square(1), line([0, 0], [1, 0])].all? { |x| x.is_a?(Shape) }", .expected = .{ .boolean = true } },
        .{ .src = "r = [cube(1).is_a?(Solid), cube(1).is_a?(Sketch), square(1).is_a?(Solid), assemble(name: \"A\", parts: [cube(1)]).is_a?(Shape)].inspect", .expected = .{ .str = "[true, false, false, false]" } },
        // A class method makes the same kind as the global function
        .{ .src = "r = [Solid.cube(1).class, Sketch.square(1).class, Path.line([0, 0], [1, 0]).class].join(\",\")", .expected = .{ .str = "Solid,Sketch,Path" } },
        // inspect names the kind: what a shape measures is the kernel's, which printing mustn't start
        .{ .src = "r = [cube(1), square(1).translate(x: 1), assemble(name: \"Arm\", parts: [cube(1), cube(2)])].inspect", .expected = .{ .str = "[#<Solid>, #<Sketch>, #<Assembly Arm, 2 parts>]" } },
        .{ .src = "r = case square(1)\nwhen Solid then \"solid\"\nwhen Shape then \"shape\"\nend", .expected = .{ .str = "shape" } },
        .{ .src = comptime support.rescued("cube(1).extrude(2)"), .expected = .{ .str = "NoMethodError: undefined method 'extrude' for Solid" } },
    });
}

test "VM: a built-in value class can't be subclassed, an error class can" {
    try support.expectScripts(&.{
        .{ .src = comptime support.rescued("class Bracket < Solid\nend"), .expected = .{ .str = "TypeError: Solid can't be subclassed: its values come from literals, constructors and methods; a class of your own can hold one" } },
        .{ .src = comptime support.rescued("class Any < Shape\nend"), .expected = .{ .str = "TypeError: Shape can't be subclassed: its values come from literals, constructors and methods; a class of your own can hold one" } },
        // Accepted, a method of its instance read the instance as a number and crashed
        .{ .src = comptime support.rescued("class N < Number\nend\nN.new.abs"), .expected = .{ .str = "TypeError: Number can't be subclassed: its values come from literals, constructors and methods; a class of your own can hold one" } },
        .{ .src = comptime support.rescued("class L < Array\nend"), .expected = .{ .str = "TypeError: Array can't be subclassed: its values come from literals, constructors and methods; a class of your own can hold one" } },
        .{ .src = "class FitError < StandardError\nend\nr = begin\n  raise FitError, \"too tight\"\nrescue FitError => e\n  e.message\nend", .expected = .{ .str = "too tight" } },
    });
}

test "VM: Object Reflection (is_a? and respond_to?)" {
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
        \\  d.respond_to?(:bark),
        \\  d.respond_to?("speak"),
        \\  d.respond_to?(:meow),
        \\  [1, 2, 3].respond_to?(:push)
        \\]
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
    try testing.expectEqual(@as(usize, 8), arr_obj.items.items.len);

    // d.is_a?(Dog) -> true
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());
    // d.is_a?(Animal) -> true (Testing superclass inheritance tracking)
    try testing.expectEqual(true, arr_obj.items.items[1].asBool());
    // d.is_a?(String) -> false
    try testing.expectEqual(false, arr_obj.items.items[2].asBool());
    // "test".is_a?(String) -> true (Testing primitive class tracking)
    try testing.expectEqual(true, arr_obj.items.items[3].asBool());

    // d.respond_to?(:bark) -> true
    try testing.expectEqual(true, arr_obj.items.items[4].asBool());
    // d.respond_to?("speak") -> true (Testing superclass method tracking and String arg)
    try testing.expectEqual(true, arr_obj.items.items[5].asBool());
    // d.respond_to?(:meow) -> false
    try testing.expectEqual(false, arr_obj.items.items[6].asBool());
    // [1, 2, 3].respond_to?(:push) -> true (Testing primitive methods)
    try testing.expectEqual(true, arr_obj.items.items[7].asBool());
}

test "VM: Reflection methods safely pop implicit blocks without corrupting stack" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\val = "hello"
        \\check1 = val.is_a?(String)
        \\check2 = val.respond_to?("split")
        \\[check1, check2]
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 35.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 30.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));

    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    // Because they share the same @@c, both should read `2`!
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[1].asNumber());
}

test "VM: super correctly resolves and executes Native C++ methods" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Create a safe custom native base class instead of subclassing `Array`
    const base_name = try vm.allocateString("NativeBase");
    vm.push(base_name); // Protect from GC
    const name_str: *value.ObjString = @alignCast(@fieldParentPtr("obj", base_name.asObj()));
    const base_class = try vm.gc.allocateClass(&vm, name_str, null);
    try vm.setGlobal("NativeBase", value.Value.initObj(&base_class.obj));
    _ = vm.pop();

    // Bind a native method to it that returns 42
    const native_func = struct {
        fn run(vm_opaque: *anyopaque, call: value.NativeArgs) anyerror!value.Value {
            const arg_count = call.count;
            const args = call.ptr;
            _ = vm_opaque;
            _ = arg_count;
            _ = args;
            return value.Value.initNumber(42.0);
        }
    }.run;
    const native_obj = try vm.gc.allocateNative("native_func", native_func);

    // --- Allocate a Value key for the method name ---
    const get_val_key = try vm.allocateString("get_val");
    try base_class.methods.put(vm.gc.trackingAllocator(), get_val_key, value.Value.initObj(&native_obj.obj));

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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expectEqual(@as(f64, 142.0), result.asNumber()); // 42 (Native) + 100
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 30.0), result.asNumber());
}

test "VM: Inline Caching correctly populates and accelerates method invocations" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class MathTool
        \\  def calc(val)
        \\    val * 2
        \\  end
        \\end
        \\tool = MathTool.new()
        \\
        \\acc = 0
        \\i = 0
        \\while (i < 2)
        \\  acc = acc + tool.calc(10)
        \\  i = i + 1
        \\end
        \\acc
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 40.0), result.asNumber()); // 20 + 20

    // Assert method invocation inline caches specifically cached the function pointers
    var populated_method_caches: usize = 0;
    for (out_chunk.inline_caches.items) |ic| {
        if (ic.cached_class_1 != null and !ic.cached_val_1.isNil()) {
            populated_method_caches += 1;
        }
    }

    // `tool.calc` should have definitively cached the closure pointer
    try testing.expect(populated_method_caches >= 1);
}

test "VM: Polymorphic inline cache correctly overwrites when receiver class changes" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // This proves that passing different classes to the same function `fetch`
    // safely overwrites the inline cache without crashing or reading the wrong class layout.
    const source =
        \\class A
        \\  def get_val() 10 end
        \\end
        \\class B
        \\  def get_val() 20 end
        \\end
        \\
        \\def fetch(obj)
        \\  obj.get_val()
        \\end
        \\
        \\[fetch(A.new()), fetch(B.new())]
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
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());
}

test "VM Syntax: Parenthesis-less method defs and command-syntax invocation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def calculate a, b
        \\  a * b
        \\end
        \\calculate 6, 7
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
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());
}

test "VM Syntax: Namespaced class declaration and scope resolution method invocation" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\module Hardware
        \\  class Screw
        \\    def self.build()
        \\      42
        \\    end
        \\  end
        \\end
        \\Hardware::Screw.build()
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
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());
}

test "VM Syntax: Module nested class declaration and scope resolution lookup" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\module Drive
        \\  class Gear
        \\    def self.teeth()
        \\      32
        \\    end
        \\  end
        \\end
        \\Drive::Gear.teeth()
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
    try testing.expectEqual(@as(f64, 32.0), result.asNumber());
}

test "VM Syntax: a class declared by its path joins the namespace it names, and a nested class is its own" {
    try support.expectScripts(&.{
        // `class Fasteners::Nut` read its path as a plain name: a string out of range
        .{ .src = "module Fasteners\nend\nclass Fasteners::Nut\n  def size\n    3\n  end\nend\nr = Fasteners::Nut.new.size", .expected = .{ .num = 3 } },
        .{ .src = "module Fasteners\nend\nclass Fasteners::Nut\nend\nr = Fasteners::Nut.inspect", .expected = .{ .str = "Fasteners::Nut" } },
        // Reopened by either form, with a superclass, a class nested in it, locals around it
        .{
            .src = "a = 1\nmodule Fasteners\n  class Base\n    def kind\n      :fastener\n    end\n  end\nend\n" ++
                "class Fasteners::Nut < Fasteners::Base\n  def size\n    3\n  end\n  class Thread\n  end\nend\nb = 2\n" ++
                "module Fasteners\n  class Nut\n    def pitch\n      0.5\n    end\n  end\nend\n" ++
                "n = Fasteners::Nut.new\nr = [n.kind, n.size, n.pitch, Fasteners::Nut::Thread.inspect, a + b].inspect",
            .expected = .{ .str = "[:fastener, 3, 0.5, \"Fasteners::Nut::Thread\", 3]" },
        },
        // A nested class reopened a top-level class of its name, and was new when reopened
        .{ .src = "class Nut\nend\nmodule Fasteners\n  class Nut\n    def size\n      3\n    end\n  end\nend\nr = Nut.new.respond_to?(:size)", .expected = .{ .boolean = false } },
        .{ .src = "module F\n  class Nut\n    def a\n      1\n    end\n  end\nend\nmodule F\n  class Nut\n    def b\n      2\n    end\n  end\nend\nr = F::Nut.new.a + F::Nut.new.b", .expected = .{ .num = 3 } },
        // A namespace that isn't there, or isn't one
        .{ .src = support.rescued("class Missing::Nut\nend"), .expected = .{ .str = "NameError: Undefined variable 'Missing'" } },
    });
}

test "VM Syntax: a module declared again adds to itself, and is its own beside a top-level one" {
    try support.expectScripts(&.{
        // Each `module A` made a new module: the first one's members were lost
        .{ .src = "module A\n  def self.x\n    1\n  end\nend\nmodule A\n  def self.y\n    2\n  end\nend\nr = A.x + A.y", .expected = .{ .num = 3 } },
        // A class declared by its path stays when its namespace is declared again
        .{ .src = "module F\nend\nclass F::Nut\n  def size\n    3\n  end\nend\nmodule F\nend\nr = F::Nut.new.size", .expected = .{ .num = 3 } },
        // Nested: reopened by its full name, apart from a top-level module of its name
        .{
            .src = "module Std\nend\nmodule Hw\n  module Std\n    def self.x\n      1\n    end\n  end\nend\n" ++
                "module Hw\n  module Std\n    def self.y\n      2\n    end\n  end\nend\nr = [Hw::Std.x + Hw::Std.y, Std.respond_to?(:x)].inspect",
            .expected = .{ .str = "[3, false]" },
        },
        // It prints by its name, as a class (it was <Object>)
        .{ .src = "module Hw\n  module Std\n  end\nend\nr = \"#{Hw} #{Hw::Std}\"", .expected = .{ .str = "Hw Hw::Std" } },
        // A name something else has is a TypeError, as in Ruby: each replaced the other
        .{ .src = support.rescued("class K\nend\nmodule K\nend"), .expected = .{ .str = "TypeError: K is not a module" } },
        .{ .src = support.rescued("module M\nend\nclass M\nend"), .expected = .{ .str = "TypeError: M is not a class" } },
        .{ .src = support.rescued("Parts = [1]\nmodule Parts\nend"), .expected = .{ .str = "TypeError: Parts is not a module" } },
    });
}

test "VM Syntax: Subclasses inherit, share, and mutate parent class variables (@@var)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Component
        \\  def register
        \\    @@total_count = (defined?(@@total_count) ? @@total_count : 0) + 1
        \\  end
        \\  def self.count
        \\    defined?(@@total_count) ? @@total_count : 0
        \\  end
        \\end
        \\
        \\class Bolt < Component
        \\  def build
        \\    self.register
        \\  end
        \\end
        \\
        \\b1 = Bolt.new
        \\b1.build
        \\b2 = Bolt.new
        \\b2.build
        \\[Component.count, Bolt.count]
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

    // Both parent Component and child Bolt reflect total_count == 2
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[1].asNumber());
}

test "VM Syntax: super call accurately forwards keyword arguments and blocks" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class BaseShape
        \\  def render(scale:, &block)
        \\    block.call(scale * 10)
        \\  end
        \\end
        \\
        \\class CustomShape < BaseShape
        \\  def render(scale:, &block)
        \\    super(scale: scale + 1, &block)
        \\  end
        \\end
        \\
        \\shape = CustomShape.new()
        \\shape.render(scale: 2) do |val|
        \\  val + 5
        \\end
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
    // scale: (2 + 1) * 10 = 30; block(30) -> 30 + 5 = 35
    try testing.expectEqual(@as(f64, 35.0), result.asNumber());
}

test "VM: Implicit bare super forwards blocks and keyword arguments natively" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Bare `super` in Child#run should capture both `scale: 2` and the `do ... end` block natively!
    const source =
        \\class BaseShape
        \\  def run(scale:, &block)
        \\    block.call(scale * 10)
        \\  end
        \\end
        \\
        \\class ChildShape < BaseShape
        \\  def run(scale:, &block)
        \\    super
        \\  end
        \\end
        \\
        \\ChildShape.new().run(scale: 2) do |val|
        \\  val + 5
        \\end
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
    try testing.expectEqual(@as(f64, 25.0), result.asNumber());
}

test "VM: Singleton Class blocks (class << self) define class methods seamlessly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class MathTools
        \\  class << self
        \\    def double(x)
        \\      x * 2
        \\    end
        \\    def triple(x)
        \\      x * 3
        \\    end
        \\  end
        \\end
        \\
        \\[MathTools.double(10), MathTools.triple(10)]
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

    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[1].asNumber());
}

test "VM: Private inline modifiers encapsulate methods correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class SecretData
        \\  def access
        \\    self.get_secret
        \\  end
        \\
        \\  private def get_secret
        \\    42
        \\  end
        \\end
        \\
        \\obj = SecretData.new
        \\obj.access
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Calling via the public method should work securely!
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());
}

test "VM: attr_accessor, attr_reader, attr_writer macro expansion" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class Person
        \\  attr_accessor :name
        \\  attr_reader :age
        \\  attr_writer :secret
        \\
        \\  def initialize(name, age)
        \\    @name = name
        \\    @age = age
        \\  end
        \\
        \\  def update_secret(s)
        \\    self.secret = s # Hits the attr_writer seamlessly
        \\    @secret
        \\  end
        \\end
        \\
        \\p = Person.new("Leo", 30)
        \\p.name = "Leon"
        \\[p.name, p.age, p.update_secret("shh")]
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

    try testing.expectEqualStrings("Leon", @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[0].asObj()))).chars);
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqualStrings("shh", @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[2].asObj()))).chars);
}

test "VM: Private method called on another instance of the same class is allowed" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Inside the class, a private method may be called on any instance of it (it used to
    // require the receiver to be `self`, which the docs never promised).
    const source =
        \\class Account
        \\  def initialize(bal) @bal = bal end
        \\  def compare(other)
        \\    other.balance
        \\  end
        \\  private def balance() @bal end
        \\end
        \\a = Account.new(100)
        \\b = Account.new(200)
        \\a.compare(b)
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
}

test "VM: Private class methods encapsulated on class object" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class Vault
        \\  def self.open
        \\    self.internal_key
        \\  end
        \\  private def self.internal_key
        \\    999
        \\  end
        \\end
        \\Vault.open
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 999.0), result.asNumber());
}

test "VM: Subclass inherits and executes parent private method via self" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class Parent
        \\  private def secret() 100 end
        \\  def compute() self.secret() + 1 end
        \\end
        \\class Child < Parent
        \\  def child_compute() self.secret() + 5 end
        \\end
        \\c = Child.new()
        \\[c.compute(), c.child_compute()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    try testing.expectEqual(@as(f64, 101.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 105.0), arr_obj.items.items[1].asNumber());
}

test "VM: attr_accessor multiple attributes and compound assignment" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class Box3D
        \\  attr_accessor :width, :height, :depth
        \\  def initialize(w, h, d)
        \\    @width = w
        \\    @height = h
        \\    @depth = d
        \\  end
        \\end
        \\b = Box3D.new(10, 20, 30)
        \\b.width += 5
        \\b.height *= 2
        \\b.depth -= 10
        \\[b.width, b.height, b.depth]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    try testing.expectEqual(@as(f64, 15.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 40.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[2].asNumber());
}

test "VM: attr_accessor defined in included module" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\module Positionable
        \\  attr_accessor :x, :y
        \\end
        \\class Node
        \\  include Positionable
        \\  def initialize
        \\    @x = 0
        \\    @y = 0
        \\  end
        \\end
        \\n = Node.new
        \\n.x = 10
        \\n.y = 25
        \\[n.x, n.y]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 25.0), arr_obj.items.items[1].asNumber());
}

test "VM: attr_accessor inside singleton class (class << self)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class AppConfig
        \\  class << self
        \\    attr_accessor :mode
        \\  end
        \\end
        \\AppConfig.mode = "production"
        \\AppConfig.mode
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
    try testing.expectEqualStrings("production", str_obj.chars);
}

test "VM Syntax:A - Uninitialized instance variables gracefully return nil" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class Config
        \\  def check
        \\    # @color was never initialized!
        \\    if @color
        \\      @color
        \\    else
        \\      "default_blue"
        \\    end
        \\  end
        \\end
        \\
        \\c = Config.new
        \\c.check
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
    try testing.expectEqualStrings("default_blue", str_obj.chars);
}

test "VM: Destructuring assignments route correctly to Class Variables via emitVariableStore" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class Config
        \\  def init()
        \\    @@width, @@height = [100, 50]
        \\  end
        \\  def area()
        \\    @@width * @@height
        \\  end
        \\end
        \\
        \\c = Config.new()
        \\c.init()
        \\c.area()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // 100 * 50 = 5000
    try testing.expectEqual(@as(f64, 5000.0), result.asNumber());
}

test "VM: Advanced and Variadic Math methods evaluate correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\[
        \\  Math.min(10, 5, 20),
        \\  Math.max(10, 5, 20),
        \\  Math.clamp(15, 0, 10),
        \\  Math.lerp(0, 10, 0.5),
        \\  Math.hypot(3, 4),
        \\  Math.sign(-42)
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

    try testing.expectEqual(@as(usize, 6), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[2].asNumber());
    try testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[3].asNumber());
    try testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[4].asNumber());
    try testing.expectEqual(@as(f64, -1.0), arr_obj.items.items[5].asNumber());
}

test "VM Syntax: Endless methods evaluate correctly without 'end' keyword" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\# 1. Without arguments
        \\def get_val = 42
        \\
        \\# 2. With arguments and mathematical expressions
        \\def double(x) = x * 2
        \\
        \\# 3. With string interpolation
        \\def greet(name) = "Hello, #{name}!"
        \\
        \\# 4. As class methods and with modifiers (e.g. private)
        \\class SecretAgent
        \\  def access = self.secret
        \\  private def secret = 100
        \\end
        \\
        \\# 5. With keyword arguments and defaults!
        \\def calc_area(width:, height: 10) = width * height
        \\
        \\agent = SecretAgent.new
        \\[
        \\  get_val,
        \\  double(21),
        \\  greet("World"),
        \\  agent.access,
        \\  calc_area(width: 5),
        \\  calc_area(width: 5, height: 20)
        \\]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    // Ensure the parser successfully processed the `=` signs without syntax errors
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Execute the compiled bytecode
    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    try testing.expectEqual(@as(usize, 6), arr_obj.items.items.len);

    // 1. get_val() == 42
    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[0].asNumber());

    // 2. double(21) == 42
    try testing.expectEqual(@as(f64, 42.0), arr_obj.items.items[1].asNumber());

    // 3. greet("World") == "Hello, World!"
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", arr_obj.items.items[2].asObj()));
    try testing.expectEqualStrings("Hello, World!", str_obj.chars);

    // 4. agent.access() == 100
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[3].asNumber());

    // 5. calc_area(width: 5) == 50 (Uses default height of 10)
    try testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[4].asNumber());

    // 6. calc_area(width: 5, height: 20) == 100
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[5].asNumber());
}

test "VM: op_get_property gracefully falls back to method lookup on compound assignments" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // `c.score += 10` compiles to:
    // 1. op_get_property ("score")
    // 2. op_add
    // 3. op_set_property ("score")
    // Because `score` is defined as a method (not a raw field), our `null` fallback
    // inside `getPropertyCached` MUST trigger so the VM successfully calls the method!
    const source =
        \\class Counter
        \\  def initialize
        \\    @val = 5
        \\  end
        \\  def score = @val
        \\  def add_score(v) = @val += v
        \\end
        \\c = Counter.new
        \\c.add_score(10)
        \\c.score
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // If the method fallback failed, it would crash or return nil (causing a math error)
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 15.0), result.asNumber());
}

test "VM: Method dispatch fails gracefully on unknown class methods" {
    const alloc = testing.allocator;

    const source = "Solid.non_existent_constructor(10)";

    var doc = try Document.parse(alloc, source);
    defer doc.deinit();

    var vm = try VM.init(alloc, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var exec_chunk = chunk.Chunk.init();
    defer exec_chunk.free(alloc);

    var comp = Compiler.forDocument(alloc, &doc, &exec_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = vm.interpret(&exec_chunk);
    try testing.expectEqual(.runtime_error, result);
}

test "VM: Bound methods are called with .call()" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Calculator
        \\  def add(a, b)
        \\    a + b
        \\  end
        \\end
        \\calc = Calculator.new
        \\m = calc.method(:add)
        \\[m.call(10, 20), m.call(15, 25)]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    _ = try executeAndAssertStack(&vm, &out_chunk, 1);

    const arr_obj = vm.stack[0].asArray();
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 40.0), arr_obj.items.items[1].asNumber());
}

test "VM: Bound methods support inheritance and super" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Base
        \\  def greet
        \\    100
        \\  end
        \\end
        \\class Derived < Base
        \\  def greet
        \\    super + 50
        \\  end
        \\end
        \\
        \\obj = Derived.new
        \\m = obj.method(:greet)
        \\m.call
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    _ = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 150.0), vm.stack[0].asNumber());
}

test "VM: Bound methods retain receiver instance state" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Counter
        \\  def set(val)
        \\    @val = val
        \\  end
        \\  def inc(amount)
        \\    @val = @val + amount
        \\  end
        \\end
        \\
        \\c = Counter.new
        \\c.set(10)
        \\m = c.method(:inc)
        \\m.call(5)
        \\m.call(5)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    _ = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 20.0), vm.stack[0].asNumber());
}

test "VM: Bound methods can be passed as arguments" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\class Multiplier
        \\  def mult(x)
        \\    x * 3
        \\  end
        \\end
        \\
        \\def apply_func(func, val)
        \\  func.call(val)
        \\end
        \\
        \\obj = Multiplier.new
        \\apply_func(obj.method(:mult), 10)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    _ = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 30.0), vm.stack[0].asNumber());
}

test "VM: Array#reduce evaluates block cleanly via block-aware wrapMethod" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests reducing with and without an explicit initial value
    const source =
        \\res1 = [1, 2, 3].reduce(10) { |acc, x| acc + x }
        \\res2 = [1, 2, 3, 4].reduce { |acc, x| acc + x }
        \\[res1, res2]
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

    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 16.0), arr_obj.items.items[0].asNumber()); // 10 + 1 + 2 + 3
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[1].asNumber()); // 1 + 2 + 3 + 4
}

test "VM: Deep inheritance chain properly shares and mutates class variables" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class Root
        \\  def initialize
        \\    @@shared = 10
        \\  end
        \\  def read_root
        \\    @@shared
        \\  end
        \\end
        \\
        \\class Middle < Root
        \\end
        \\
        \\class Leaf < Middle
        \\  def mutate
        \\    @@shared += 42
        \\  end
        \\end
        \\
        \\r = Root.new
        \\l = Leaf.new
        \\l.mutate
        \\r.read_root
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // The Leaf successfully mutated the Root's variable (10 + 42 = 52)
    try testing.expectEqual(@as(f64, 52.0), result.asNumber());
}

// Calling a class directly runs a native initialize
test "VM: class with a native initialize can be called directly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    // Exception's initialize is a native; the call-syntax path used to cast it to a
    // closure. A closure initialize must yield the instance there too, as with `.new`.
    const source =
        \\class Box
        \\  def initialize(w)
        \\    @w = w
        \\  end
        \\  def width
        \\    @w
        \\  end
        \\end
        \\box_width = Box(7).width
        \\err = ArgumentError("bad width")
        \\direct = err.message
        \\is_instance = err.is_a?(ArgumentError)
        \\raised = begin
        \\  raise ArgumentError("bad height")
        \\rescue ArgumentError => e
        \\  e.message
        \\end
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    try testing.expectEqual(@as(f64, 7), vm.globals.get("box_width").?.asNumber());
    try expectGlobalString(&vm, "direct", "bad width");
    try testing.expect(vm.globals.get("is_instance").?.asBool());
    try expectGlobalString(&vm, "raised", "bad height");
}

test "VM: rescuing one error class does not catch another" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    const source =
        \\r = begin
        \\  begin
        \\    cube(-1)
        \\  rescue TypeError => e
        \\    "wrong handler"
        \\  end
        \\rescue ValueError => e
        \\  "outer ValueError handler"
        \\end
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    try expectGlobalString(&vm, "r", "outer ValueError handler");
}
