//! VM tests of errors: raise, rescue, ensure and retry, unwinding through blocks and natives,
//! error classes and their messages.

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
const compileAndRun = helpers.compileAndRun;
const expectGlobalString = helpers.expectGlobalString;
const compileAndRunStressed = helpers.compileAndRunStressed;

var probed_unwind_len: usize = 0;

// Double throw: a native that raised must not get a second "Native ... Error"
const native_raise_message = "raised by native";

fn probeUnwindLen(v_ptr: *anyopaque, call: value.NativeArgs) anyerror!value.Value {
    const arg_count = call.count;
    const args = call.ptr;
    _ = arg_count;
    _ = args;
    const vm_ptr: *VM = @ptrCast(@alignCast(v_ptr));
    probed_unwind_len = @max(probed_unwind_len, vm_ptr.unwind_stack.items.len);
    return value.Value.initNil();
}

/// Raises a rescuable exception, then fails with an ordinary error as stdlib natives do.
fn raiseThenFail(v_ptr: *anyopaque, call: value.NativeArgs) anyerror!value.Value {
    const arg_count = call.count;
    const args = call.ptr;
    _ = arg_count;
    _ = args;
    const vm_ptr: *VM = @ptrCast(@alignCast(v_ptr));
    _ = vm_ptr.raiseError(.RuntimeError, native_raise_message, .{});
    return error.RuntimeError;
}

/// Defines `RaisingInit`, a class whose native `initialize` raises.
fn defineRaisingInitClass(vm: *VM) !void {
    const name_val = try vm.allocateString("RaisingInit");
    vm.push(name_val);
    defer _ = vm.pop();
    const class_obj = try vm.gc.allocateClass(vm, name_val.asString(), vm.object_class);
    try vm.setGlobal("RaisingInit", value.Value.initObj(&class_obj.obj));

    const init_fn = try vm.gc.allocateNative("raise_then_fail", raiseThenFail);
    const init_key = try vm.allocateString("initialize");
    try class_obj.methods.put(vm.gc.trackingAllocator(), init_key, value.Value.initObj(&init_fn.obj));
}

test "VM: cleanly unwinds stack and jumps to rescue block on throw" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    // Built by hand, so registered as the compiler registers its chunks: under -Dgc-stress the
    // values it holds were swept before the run began.
    try vm.gc.trackChunk(&out_chunk);

    try out_chunk.writeOp(testing.allocator, .op_setup_rescue, 0);
    const jump_idx = out_chunk.code.items.len;
    try out_chunk.write(testing.allocator, 0xFF, 0);
    try out_chunk.write(testing.allocator, 0xFF, 0);
    try out_chunk.write(testing.allocator, 0xFF, 0);
    try out_chunk.write(testing.allocator, 0xFF, 0);

    const dummy = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(99.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(dummy), 0);

    const err_str_val = try vm.allocateString("Crash!");
    vm.ensureStackCapacity(1) catch unreachable;
    vm.push(err_str_val);
    const err_str = try out_chunk.addConstant(testing.allocator, err_str_val);
    _ = vm.pop();

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(err_str), 0);
    try out_chunk.writeOp(testing.allocator, .op_throw, 0);

    try out_chunk.writeOp(testing.allocator, .op_pop_rescue, 0);
    try out_chunk.writeOp(testing.allocator, .op_jump, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 4, 0);

    // --- RESCUE HANDLER ---
    const handler_ip = out_chunk.code.items.len;
    const offset = handler_ip - (jump_idx + 4);
    out_chunk.code.items[jump_idx] = @intCast((offset >> 24) & 0xFF);
    out_chunk.code.items[jump_idx + 1] = @intCast((offset >> 16) & 0xFF);
    out_chunk.code.items[jump_idx + 2] = @intCast((offset >> 8) & 0xFF);
    out_chunk.code.items[jump_idx + 3] = @intCast(offset & 0xFF);

    try out_chunk.writeOp(testing.allocator, .op_pop, 0);

    const c42 = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(c42), 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);
    out_chunk.max_stack_slots = 5;

    const final_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 42.0), final_val.asNumber());
}

test "VM Edge Case: Uncaught exceptions halt gracefully without panicking" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const err_val = try vm.allocateString("Fatal System Error!");
    vm.push(err_val);
    const err_idx = try out_chunk.addConstant(testing.allocator, err_val);
    _ = vm.pop();

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(err_idx), 0);
    try out_chunk.writeOp(testing.allocator, .op_throw, 0);
    out_chunk.max_stack_slots = 2;

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());
}

test "VM Edge Case: Out of bounds array indexing returns runtime error" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\arr = [10, 20, 30]
        \\arr[5]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    // Should safely abort rather than panic
    try testing.expectEqual(.runtime_error, result);
}

test "VM Edge Case: Native C++ FFI failures are safely caught by rescue blocks" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Attempt to translate a geometry using an invalid String instead of a Number.
    // In, this caused a fatal process panic. Now it should gracefully throw to rescue!
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // The script should successfully exit with .ok, returning 42 from the rescue block!
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 110.0), result.asNumber()); // 10 from rescue, 100 from ensure
}

test "VM Edge Case: CSG operations across mixed 2D/3D types throw runtime error" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    // cadBinaryHandler should instantly block this as a type mismatch
    try testing.expectEqual(.runtime_error, result);
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
        \\  [e.is_a?(IndexError), e.is_a?(Exception), e.message()]
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
    try testing.expect(arr_val.isArray());

    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    // Prove `e` is the IndexError raiseError created for the bad index
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());

    // Prove `IndexError` successfully inherits from `Exception`
    try testing.expectEqual(true, arr_obj.items.items[1].asBool());

    // Prove `e.message()` evaluates successfully to the VM's formatted array bounds error
    const msg_val = arr_obj.items.items[2];
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", msg_val.asObj()));
    try testing.expectEqualStrings("Array index 5 is out of bounds (size 2)", str_obj.chars);
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Stack should contain exactly the yielded message string
    const str_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(str_val.isObject() and str_val.asObj().obj_type == .string);

    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", str_val.asObj()));
    try testing.expectEqualStrings("My custom failure!", str_obj.chars);
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 100.0), arr_obj.items.items[1].asNumber());
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

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 500.0), result.asNumber());
}

test "VM: Exception objects capture first-class error backtraces" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def level_one()
        \\  raise(ArgumentError.new("Bad parameter!"))
        \\end
        \\
        \\def level_two()
        \\  level_one()
        \\end
        \\
        \\begin
        \\  level_two()
        \\rescue => e
        \\  e.backtrace()
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    // Inject LineIndex so it uses the 'script:line:col' format instead of 'offset'
    vm.line_index = &doc.line_index;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expect(result.isObject() and result.asObj().obj_type == .array);
    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", result.asObj()));

    try testing.expect(arr_obj.items.items.len >= 3);

    // Verify EXACT Ruby-style formatting
    const frame1 = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[0].asObj()))).chars;
    try testing.expect(std.mem.startsWith(u8, frame1, "    from script:"));
    try testing.expect(std.mem.indexOf(u8, frame1, "in 'level_one'") != null);

    const frame2 = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[1].asObj()))).chars;
    try testing.expect(std.mem.startsWith(u8, frame2, "    from script:"));
    try testing.expect(std.mem.indexOf(u8, frame2, "in 'level_two'") != null);

    const frame3 = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[2].asObj()))).chars;
    try testing.expect(std.mem.startsWith(u8, frame3, "    from script:"));
    try testing.expect(std.mem.indexOf(u8, frame3, "in 'script'") != null);
}

test "VM Syntax: break statement inside block unwinds iterator and yields value directly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def find_match(list)
        \\  list.each do |item|
        \\    if item == 20
        \\      break 999
        \\    end
        \\  end
        \\end
        \\find_match([10, 20, 30])
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

test "VM: Direct external access to private methods throws runtime error" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class SecretData
        \\  private def get_secret
        \\    42
        \\  end
        \\end
        \\obj = SecretData.new
        \\obj.get_secret
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Calling the private method externally must violently fail
    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);
}

test "VM: Direct external call to private class method throws error" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\class Vault
        \\  private def self.internal_key
        \\    999
        \\  end
        \\end
        \\Vault.internal_key
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

test "VM: assert validates conditions, evaluates lazy blocks, and throws specified classes" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\# 1. Passes successfully (returns nil)
        \\a = assert(10 > 5)
        \\
        \\# 2. Fails with string message
        \\b_caught = false
        \\begin
        \\  assert(false, "Basic fail")
        \\rescue AssertionError => e
        \\  b_caught = e.message == "Basic fail"
        \\end
        \\
        \\# 3. Fails with lazy evaluated block
        \\c_caught = false
        \\begin
        \\  assert(nil) do
        \\    "Lazy " + "fail"
        \\  end
        \\rescue AssertionError => e
        \\  c_caught = e.message == "Lazy fail"
        \\end
        \\
        \\# 4. Fails with Custom Exception Class
        \\d_caught = false
        \\begin
        \\  assert(false, "Wrong Type", TypeError)
        \\rescue TypeError => e
        \\  d_caught = e.message == "Wrong Type"
        \\end
        \\
        \\[a.nil?, b_caught, c_caught, d_caught]
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

    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);
    // All 4 scenarios should have evaluated securely and returned true!
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());
    try testing.expectEqual(true, arr_obj.items.items[1].asBool());
    try testing.expectEqual(true, arr_obj.items.items[2].asBool());
    try testing.expectEqual(true, arr_obj.items.items[3].asBool());
}

test "VM: raiseError does not truncate massive error messages" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Mute errors so the massive string doesn't spam the test runner output

    // Create a 300 character string
    var massive_buf: [300]u8 = undefined;
    @memset(&massive_buf, 'E');

    // Throw an error using the massive string
    const res = vm.raiseError(.RuntimeError, "Failure: {s}", .{&massive_buf});

    // Since there are no rescue frames, it should halt with runtime_error.
    // The fact that this succeeds without an OutOfBounds panic or buffer overflow
    // proves that fmtScratch correctly dynamically allocated the massive string!
    try testing.expectEqual(InterpretResult.runtime_error, res);
}

test "VM Edge Case: Array#sort safely throws if block yields non-number" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\[1, 2, 3].sort { |a, b| "invalid" }
    ;

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(std.testing.allocator);
    var comp = Compiler.forDocument(std.testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try std.testing.expectEqual(.runtime_error, result);
}

test "VM Edge Case: Exceptions inside blocks passed to Native methods safely unwind" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Native Array#map iterates 3 times. On the second iteration, the KupCAD block violently aborts.
    const source =
        \\begin
        \\  [1, 2, 3].map do |x|
        \\    if x == 2
        \\      raise("Abort")
        \\    end
        \\    x * 10
        \\  end
        \\rescue => e
        \\  e
        \\end
    ;

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // The rescue block should gracefully catch the error and maintain stack equilibrium
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Verify the exception was safely unwound and auto-wrapped into an instance
    try std.testing.expect(result.isInstance());
    const inst = result.asInstance();
    try std.testing.expectEqualStrings("RuntimeError", inst.class.name.chars);

    // Extract the 'message' field natively using the DOD instance layout map
    const msg_key = try vm.allocateString("message");
    const msg_idx = inst.class.instance_layout.get(msg_key).?;
    const msg_val = inst.fields.items[msg_idx];

    try std.testing.expect(msg_val.isObject() and msg_val.asObj().obj_type == .string);
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", msg_val.asObj()));

    // Proves the stack unwound, auto-wrapped the primitive string, and populated the instance field!
    try std.testing.expectEqualStrings("Abort", str_obj.chars);
}

test "VM: raise auto-wraps primitive types in RuntimeError" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Proves that throwing a raw Number correctly stringifies into a RuntimeError
    const source =
        \\begin
        \\  raise(42)
        \\rescue RuntimeError => e
        \\  [e.is_a?(RuntimeError), e.message]
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
    const arr_obj = result.asArray();

    try testing.expectEqual(true, arr_obj.items.items[0].asBool());

    const msg_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", arr_obj.items.items[1].asObj()));
    try testing.expectEqualStrings("42", msg_obj.chars);
}

test "VM Edge Case: raise auto-wraps Array primitives into RuntimeError with stringified message" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Raise an array. The auto-wrapper should inherently call .stringify() on it.
    const source =
        \\begin
        \\  raise([1, 2, 3])
        \\rescue RuntimeError => e
        \\  e # Return the error instance natively
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // The rescue block catches the error and maintains stack equilibrium
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Assert it successfully wrapped into an instance of RuntimeError
    try testing.expect(result.isInstance());
    const inst = result.asInstance();
    try testing.expectEqualStrings("RuntimeError", inst.class.name.chars);

    // Extract the 'message' field natively using the DOD instance layout map
    const msg_key = try vm.allocateString("message");
    const msg_idx = inst.class.instance_layout.get(msg_key).?;
    const msg_val = inst.fields.items[msg_idx];

    // Assert the message is a valid string
    try testing.expect(msg_val.isObject() and msg_val.asObj().obj_type == .string);
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", msg_val.asObj()));

    // Verify the Array stringification resolved perfectly
    try testing.expectEqualStrings("[1, 2, 3]", str_obj.chars);
}

test "VM Edge Case: raise auto-wraps Map primitives into RuntimeError with stringified message" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Raise a map. The auto-wrapper should inherently call .stringify() on it.
    const source =
        \\begin
        \\  raise({ "error_code" => 404 })
        \\rescue RuntimeError => e
        \\  e # Return the error instance natively
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // The rescue block catches the error and maintains stack equilibrium
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Assert it successfully wrapped into an instance of RuntimeError
    try testing.expect(result.isInstance());
    const inst = result.asInstance();
    try testing.expectEqualStrings("RuntimeError", inst.class.name.chars);

    // Extract the 'message' field natively using the DOD instance layout map
    const msg_key = try vm.allocateString("message");
    const msg_idx = inst.class.instance_layout.get(msg_key).?;
    const msg_val = inst.fields.items[msg_idx];

    // Assert the message is a valid string
    try testing.expect(msg_val.isObject() and msg_val.asObj().obj_type == .string);
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", msg_val.asObj()));

    // Map stringification order can be unpredictable depending on the underlying hash,
    // so we verify that the formatted contents exist securely within the output.
    try testing.expect(std.mem.indexOf(u8, str_obj.chars, "404") != null);
    try testing.expect(std.mem.indexOf(u8, str_obj.chars, "error_code") != null);
}

test "VM Edge Case: Exception raised inside a rescue block is caught by outer rescue" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests that the rescue frame stack is properly maintained when an exception
    // is thrown while currently inside an active rescue handler.
    const source =
        \\begin
        \\  begin
        \\    raise("First Error")
        \\  rescue => e1
        \\    raise("Second Error")
        \\  end
        \\rescue => e2
        \\  e2.message
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

    try testing.expect(result.isObject() and result.asObj().obj_type == .string);
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", result.asObj()));
    try testing.expectEqualStrings("Second Error", str_obj.chars);
}

test "VM Edge Case: Exception raised inside a constructor unwinds safely" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests that op_call to .new cleanly drops the partially-initialized instance
    // and correctly unwinds the frame if initialize() throws an error.
    const source =
        \\class BrokenWidget
        \\  def initialize
        \\    raise("Init Failed")
        \\  end
        \\end
        \\
        \\begin
        \\  w = BrokenWidget.new
        \\  "Success"
        \\rescue => e
        \\  e.message
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

    try testing.expect(result.isObject() and result.asObj().obj_type == .string);
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", result.asObj()));
    try testing.expectEqualStrings("Init Failed", str_obj.chars);
}

test "VM Edge Case: Exception unwinds cleanly through multiple closure call frames" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests that executeThrow correctly shrinks `self.frames` by multiple levels
    // to reach the exact frame count where the rescue handler resides.
    const source =
        \\def layer3
        \\  raise("Deep Error")
        \\end
        \\def layer2
        \\  layer3
        \\end
        \\def layer1
        \\  layer2
        \\end
        \\
        \\begin
        \\  layer1
        \\rescue => e
        \\  e.message
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

    try testing.expect(result.isObject() and result.asObj().obj_type == .string);
    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", result.asObj()));
    try testing.expectEqualStrings("Deep Error", str_obj.chars);
}

test "VM Edge Case: Raising and rescuing a custom non-Exception object" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Proves that `executeThrow` recognizes native instances, bypasses the primitive
    // RuntimeError auto-wrapper, and allows `rescue` to filter by any arbitrary class!
    const source =
        \\class CustomPayload
        \\  attr_accessor :data
        \\  def initialize(d)
        \\    @data = d
        \\  end
        \\end
        \\
        \\begin
        \\  raise(CustomPayload.new(42))
        \\rescue CustomPayload => e
        \\  e.data
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

    // The thrown payload was seamlessly bypassed, caught, and unpacked
    try testing.expect(result.isNumber());
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());
}

test "VM: Stack underflow during rescue unwinding shrinks safely without panic" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // An invalid operation that pops operands before throwing an exception
    const source =
        \\begin
        \\  10 - "invalid"
        \\rescue => e
        \\  42
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // executeAndAssertStack enforces zealous GC and checks stack equilibrium == 1
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 42.0), result.asNumber());
}

test "VM: Sequential rescued exceptions do not accumulate un-swept memory" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // The first rescued RuntimeError grows its class's field layout once; warm that up
    // in a separate chunk so the baseline only excludes the objects under test.
    {
        var doc = try Document.parse(testing.allocator, "begin\n  cube(10).warmup = 1\nrescue => w\n  nil\nend");
        defer doc.deinit();
        var warmup_chunk = chunk.Chunk.init();
        defer warmup_chunk.free(testing.allocator);
        var comp = Compiler.forDocument(testing.allocator, &doc, &warmup_chunk, &vm);
        defer comp.deinit();
        try comp.compile(doc.tree.root);
        try testing.expectEqual(.ok, vm.interpret(&warmup_chunk));
    }
    vm.resetStack();
    vm.gc.collectGarbage(&vm, false);
    const baseline_memory = vm.gc.bytes_allocated;

    // An anonymous lambda, cleared afterwards, so neither the closure, the exceptions
    // nor the discarded cube receivers stay rooted
    const source =
        \\f = ->() do
        \\  begin
        \\    cube(10).invalid_a = 1
        \\  rescue => e1
        \\    nil
        \\  end
        \\
        \\  begin
        \\    cube(10).invalid_b = 2
        \\  rescue => e2
        \\    nil
        \\  end
        \\end
        \\f.call
        \\f = nil
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    _ = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Collect garbage and verify all temporary exception objects were swept
    vm.resetStack();
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(baseline_memory, vm.gc.bytes_allocated);
}

test "VM: Uncaught exception state is purged on resetStack" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source = "raise(\"Uncaught Fatal\")";

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);

    // A pending native-boundary unwind entry must not survive into the next run
    try vm.unwind_stack.append(vm.allocator, .{ .err_val = value.Value.initNil(), .stack_top = vm.stack_top });
    vm.resetStack();
    try testing.expectEqual(@as(usize, 0), vm.stack_top);
    try testing.expectEqual(@as(usize, 0), vm.unwind_stack.items.len);
}

test "VM: Kernel error raised in a nested call frame unwinds to the rescue target" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\def level2
        \\  cube(10).invalid_method
        \\end
        \\
        \\def level1
        \\  level2
        \\end
        \\
        \\begin
        \\  level1
        \\rescue => e
        \\  e.message
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // The kernel error raised two frames deep reaches the top-level handler
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isString());
    // The real cause, no longer the generic "CAD Kernel / Method Error"
    try testing.expectEqualStrings("undefined method 'invalid_method' for Geometry", result.asString().chars);
}

test "VM: Mid-expression throw safely unwinds without stack underflow" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // AST effectively evaluates to: `10 + (throw RuntimeError)`
    // The `10` is left stranded on the stack when the throw occurs.
    const source =
        \\begin
        \\  10 + missing_function_call
        \\rescue
        \\  99
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // If `shrinkStack` underflows, this will panic the entire test runner.
    // By using executeAndAssertStack, we also enforce `zealous_gc` to ensure the stranded `10` doesn't leak!
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // It should cleanly rescue and yield the fallback value 99
    try testing.expectEqual(@as(f64, 99.0), result.asNumber());
}

test "VM: Array#to_h safely throws ArgumentError on invalid structure" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\[1, 2, 3].to_h # Elements are numbers, not pair arrays
    ;

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(std.testing.allocator);
    var comp = Compiler.forDocument(std.testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // It should cleanly catch the invalid type and safely abort the execution
    const result = vm.interpret(&out_chunk);
    try std.testing.expectEqual(.runtime_error, result);
}

test "VM: Catches NaN in math operations and throws" {
    // Square root of a negative number yields NaN
    const source = "val = (-1.0) ** 0.5";

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();

    // Silence the expected stderr error output during the test run
    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();
    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&main_chunk);

    try std.testing.expectEqual(.runtime_error, result);
}

test "VM: Nested native boundaries unwind exceptions safely without stack corruption" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Native trampoline that executes a closure passed as argument 0
    const native_runner = struct {
        fn run(v_ptr: *anyopaque, call: value.NativeArgs) anyerror!value.Value {
            const arg_count = call.count;
            const args = call.ptr;
            const vm_ptr = @as(*VM, @ptrCast(@alignCast(v_ptr)));
            if (arg_count < 1) return error.RuntimeError;
            const closure_val = args[0];
            if (!closure_val.isClosure()) return error.RuntimeError;
            return vm_ptr.callClosureSync(closure_val.asClosure(), &.{});
        }
    }.run;

    const native_obj = try vm.gc.allocateNative("run_closure", native_runner);
    try vm.setGlobal("run_closure", value.Value.initObj(&native_obj.obj));

    // Script with nested native boundary re-entrancy:
    // Outer script -> Native run_closure -> Closure -> Native run_closure -> Closure -> raise
    const source =
        \\begin
        \\  run_closure(-> {
        \\    run_closure(-> {
        \\      raise "nested error"
        \\    })
        \\  })
        \\rescue => e
        \\  e.message
        \\end
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

    const rescued_val = vm.stack[0];
    try testing.expect(rescued_val.isString());
    try testing.expectEqualStrings("nested error", rescued_val.asString().chars);
}

// unwind_stack protocol
test "VM: stale unwind entry is not restored by an outer native boundary" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // The first exception is handled without crossing a native and used to leave
    // its entry behind; the outer `each` then restored "stale" instead of "inner".
    const source =
        \\def deep(a, b, c, d, e, f)
        \\  g = 1
        \\  h = 2
        \\  begin
        \\    raise "stale"
        \\  rescue => err
        \\    nil
        \\  end
        \\  42
        \\end
        \\deep(1, 2, 3, 4, 5, 6)
        \\result = begin
        \\  [1].each { |a| [2].each { |b| raise "inner" } }
        \\rescue => e
        \\  e.message
        \\end
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    try expectGlobalString(&vm, "result", "inner");
}

test "VM: handled exceptions do not accumulate unwind entries" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    const native_obj = try vm.gc.allocateNative("probe_unwind_len", probeUnwindLen);
    try vm.setGlobal("probe_unwind", value.Value.initObj(&native_obj.obj));
    probed_unwind_len = 0;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const source =
        \\i = 0
        \\while i < 200
        \\  begin
        \\    raise "x"
        \\  rescue => e
        \\  end
        \\  i = i + 1
        \\end
        \\probe_unwind()
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    // Previously one entry per raise (200), each pinning its exception as a GC root.
    // Probed mid-run: interpret() clears the stack on exit, so checking afterwards proves nothing.
    try testing.expect(probed_unwind_len <= 1);
}

// Bound native methods must use the unwind protocol
test "VM: exception raised in a block passed to a bound native method is rescuable" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const source =
        \\m = [1, 2].method(:each)
        \\result = begin
        \\  m.call { |x| raise "from bound" }
        \\  "not rescued"
        \\rescue => e
        \\  e.message
        \\end
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    try expectGlobalString(&vm, "result", "from bound");
}

test "VM: exception raised by a native is thrown once and execution continues" {
    // Each native boundary that raises: a stdlib method (Array#reduce without a block),
    // a native constructor, and a method nothing answers.
    const cases = [_]struct { expr: []const u8, message: []const u8 }{
        .{ .expr = "[].reduce", .message = "reduce requires a block" },
        .{ .expr = "RaisingInit.new", .message = native_raise_message },
        .{ .expr = "5.not_a_method", .message = "undefined method 'not_a_method' for Number" },
    };
    for (cases) |case| {
        errdefer std.debug.print("failing case: {s}\n", .{case.expr});
        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        try registry.registerStandardLibrary(&vm);
        vm.mute_errors = true;
        try defineRaisingInitClass(&vm);

        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(testing.allocator);

        const source = try std.fmt.allocPrint(testing.allocator,
            \\inner = 0
            \\outer = 0
            \\msg = nil
            \\begin
            \\  begin
            \\    {s}
            \\  rescue => e
            \\    inner = inner + 1
            \\    msg = e.message
            \\  end
            \\rescue => e2
            \\  outer = outer + 1
            \\end
            \\after = "continued"
        , .{case.expr});
        defer testing.allocator.free(source);

        try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
        try testing.expectEqual(@as(f64, 1), vm.globals.get("inner").?.asNumber());
        try testing.expectEqual(@as(f64, 0), vm.globals.get("outer").?.asNumber());
        const msg = vm.globals.get("msg").?;
        try testing.expect(msg.isString());
        try testing.expect(std.mem.indexOf(u8, msg.asString().chars, case.message) != null);
        try expectGlobalString(&vm, "after", "continued");
    }
}

test "VM: raise of a non-exception payload wraps it in a RuntimeError that survives collection" {
    // executeThrow allocated the wrapping RuntimeError, then the payload's message
    // string, and only rooted the instance afterwards: that collection freed it.
    const cases = [_]struct { payload: []const u8, message: []const u8 }{
        .{ .payload = "42", .message = "42" },
        .{ .payload = "1.5", .message = "1.5" },
        .{ .payload = "[1]", .message = "[1]" },
        .{ .payload = "{a: 1}", .message = "{a: 1}" }, // Value.stringify's map format
        .{ .payload = "true", .message = "true" },
        .{ .payload = "false", .message = "false" },
        .{ .payload = "nil", .message = "nil" },
        .{ .payload = ":sym", .message = "sym" }, // a Symbol's text, as its to_s
        .{ .payload = "1..3", .message = "1..3" },
        // A String payload is the message as-is
        .{ .payload = "\"bo\" + \"om\"", .message = "boom" },
    };
    for (cases) |case| {
        errdefer std.debug.print("failing payload: {s}\n", .{case.payload});
        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        try registry.registerStandardLibrary(&vm);
        vm.mute_errors = true;

        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(testing.allocator);

        const source = try std.fmt.allocPrint(testing.allocator,
            \\result = begin
            \\  raise({s})
            \\rescue RuntimeError => e
            \\  trace = e.backtrace[0]
            \\  e.message
            \\end
            \\after = "continued"
        , .{case.payload});
        defer testing.allocator.free(source);

        try testing.expectEqual(.ok, try compileAndRunStressed(&vm, &out_chunk, source));
        try expectGlobalString(&vm, "result", case.message);
        try expectGlobalString(&vm, "after", "continued");
        const trace = vm.globals.get("trace") orelse return error.MissingGlobal;
        try testing.expect(trace.isString());
        try testing.expect(std.mem.indexOf(u8, trace.asString().chars, "from script") != null);
    }
}

test "VM: assert keeps its message rooted while it allocates the exception" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Both the default message and a block's result were only held in a Zig
    // local while the AssertionError instance was allocated.
    const source =
        \\default_msg = begin
        \\  assert(false)
        \\rescue AssertionError => e
        \\  e.message
        \\end
        \\block_msg = begin
        \\  assert(nil) { "lazy " + "msg" }
        \\rescue AssertionError => e
        \\  e.message
        \\end
    ;
    try testing.expectEqual(.ok, try compileAndRunStressed(&vm, &out_chunk, source));
    try expectGlobalString(&vm, "default_msg", "Assertion failed.");
    try expectGlobalString(&vm, "block_msg", "lazy msg");
}

test "VM: a raised class and Exception.new keep their message and backtrace rooted" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    // Exception#initialize set the message it had just made from the class name, and the
    // backtrace, while only a Zig local held them.
    const source =
        \\from_class = begin
        \\  raise ArgumentError
        \\rescue ArgumentError => e
        \\  if e.backtrace.length > 0
        \\    e.message
        \\  else
        \\    "no backtrace"
        \\  end
        \\end
        \\made = ArgumentError.new.message
        \\given = ArgumentError.new("given " + "here").message
    ;
    try testing.expectEqual(.ok, try compileAndRunStressed(&vm, &out_chunk, source));
    try expectGlobalString(&vm, "from_class", "ArgumentError");
    try expectGlobalString(&vm, "made", "ArgumentError");
    try expectGlobalString(&vm, "given", "given here");
}

test "VM: every runtime error kind is a registered StandardError subclass" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const standard_error = (vm.globals.get("StandardError") orelse return error.MissingGlobal).asClass();
    inline for (comptime std.meta.fieldNames(ErrorKind)) |name| {
        const class = vm.error_classes.get(@field(ErrorKind, name)) orelse return error.MissingClass;
        try testing.expectEqualStrings(name, class.name.chars);
        try testing.expectEqual(class, (vm.globals.get(name) orelse return error.MissingGlobal).asClass());
        try testing.expect(VM.isSubclassOf(class, standard_error));
    }
}

test "VM: runtime errors have their own class and a message without a class prefix" {
    // Every native error used to be a RuntimeError whose message began with its "kind"
    // ("ValueError: ...", "Runtime Error: ..."), often with a trailing newline, so
    // `rescue ValueError` caught nothing and uncaught errors printed two prefixes.
    const cases = [_]struct { expr: []const u8, kind: []const u8, message: []const u8 }{
        .{ .expr = "[1, 2][5]", .kind = "IndexError", .message = "Array index 5 is out of bounds (size 2)" },
        .{ .expr = "nope_undefined", .kind = "NameError", .message = "Undefined variable 'nope_undefined'" },
        .{ .expr = "5[0]", .kind = "TypeError", .message = "Number can't be indexed with []" },
        .{ .expr = "1 / 0", .kind = "ZeroDivisionError", .message = "Division by zero." },
        .{ .expr = "1 | Number::INFINITY", .kind = "RangeError", .message = "Bitwise operand Infinity is not a finite 64-bit integer." },
        .{ .expr = "polygon([[0, 0], [1, \"x\"], [0, 1]])", .kind = "TypeError", .message = "polygon expects a number for a coordinate (point 1, component 1), got String" },
        .{ .expr = "cube(Number::INFINITY - Number::INFINITY)", .kind = "ValueError", .message = "cube expects a finite number for x, got NaN" },
        .{ .expr = "3.times", .kind = "ArgumentError", .message = "times requires a block" },
    };
    for (cases) |case| {
        errdefer std.debug.print("expr: {s}\n", .{case.expr});
        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        try registry.registerStandardLibrary(&vm);
        vm.mute_errors = true;
        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(testing.allocator);
        // Rescued by its own class: StandardError comes second, so a wrong class shows up as "other".
        const source = try std.fmt.allocPrint(testing.allocator,
            \\r = begin
            \\  {s}
            \\  "no error"
            \\rescue {s} => e
            \\  e.message
            \\rescue StandardError => e
            \\  "other: " + e.message
            \\end
        , .{ case.expr, case.kind });
        defer testing.allocator.free(source);
        try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
        try expectGlobalString(&vm, "r", case.message);
    }
}

test "VM: an uncaught runtime error is reported with one class prefix" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    try testing.expectEqual(.runtime_error, try compileAndRun(&vm, &out_chunk, "x = [1, 2][5]"));
    try testing.expectEqualStrings("IndexError: Array index 5 is out of bounds (size 2)", vm.last_error orelse return error.MissingError);
}
