//! Regression tests for issues found in the Oct 2026 audit.
//! Frontend + compiler robustness: every oversized or deeply nested input must
//! produce a clean diagnostic / compile error instead of an assert, overflow,
//! out-of-bounds write or stack overflow.

const std = @import("std");
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const limits = @import("../core/limits.zig");
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const Compiler = @import("compiler.zig").Compiler;
const Document = @import("../core/document.zig").Document;
const VM = @import("../vm/vm.zig").VM;
const disassembler = @import("../tools/dev/disassembler.zig");

// Comfortably above MAX_AST_DEPTH so every repro overshoots the limit
const DEEP: usize = 3000;

/// Builds `prefix * count ++ middle ++ suffix * count` into an owned buffer.
fn repeatWrap(prefix: []const u8, middle: []const u8, suffix: []const u8, count: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    for (0..count) |_| try buf.appendSlice(testing.allocator, prefix);
    try buf.appendSlice(testing.allocator, middle);
    for (0..count) |_| try buf.appendSlice(testing.allocator, suffix);
    return buf.toOwnedSlice(testing.allocator);
}

fn hasDiagnostic(doc: *const Document, needle: []const u8) bool {
    for (doc.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

/// Parses (with semantic resolution, which walks the whole tree) and asserts the
/// parser rejected the input with a depth diagnostic, then confirms the
/// compiler copes with whatever tree was produced.
fn expectDepthRejected(source: []const u8) !void {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expect(hasDiagnostic(&doc, "Maximum AST depth exceeded"));

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    comp.compile(doc.tree.root) catch |err| try testing.expectEqual(error.AstTooDeep, err);
}

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
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const status = vm.interpret(&out_chunk);
    const top = if (vm.stack_top > 0) vm.stack[vm.stack_top - 1] else value.Value.initNil();
    return .{ .status = status, .top = top };
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
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
}

// --- Finding 1: AST depth -------------------------------------------------

test "Audit depth: deeply nested if statements report a depth error" {
    const src = try repeatWrap("if true\n", "1\n", "end\n", DEEP);
    defer testing.allocator.free(src);
    try expectDepthRejected(src);
}

test "Audit depth: deeply nested class statements report a depth error" {
    const src = try repeatWrap("class A\n", "", "end\n", DEEP);
    defer testing.allocator.free(src);
    try expectDepthRejected(src);
}

test "Audit depth: deeply nested def statements report a depth error" {
    const src = try repeatWrap("def f\n", "1\n", "end\n", DEEP);
    defer testing.allocator.free(src);
    try expectDepthRejected(src);
}

test "Audit depth: long elsif chain reports a depth error" {
    const src = try repeatWrap("", "if false\n1\n", "elsif false\n1\n", DEEP);
    defer testing.allocator.free(src);
    const full = try std.mem.concat(testing.allocator, u8, &.{ src, "end\n" });
    defer testing.allocator.free(full);
    try expectDepthRejected(full);
}

test "Audit depth: long method chain reports a depth error" {
    const src = try repeatWrap("", "a", ".b", 5000);
    defer testing.allocator.free(src);
    try expectDepthRejected(src);
}

test "Audit depth: long left-associative binary chain reports a depth error" {
    // Used to overflow the stack inside the resolver's recursive visitor
    const src = try repeatWrap("", "x = a", " + a", 20000);
    defer testing.allocator.free(src);
    try expectDepthRejected(src);
}

test "Audit depth: chains below the limit still parse and compile" {
    const src = try repeatWrap("", "x = 1", " + 1", 500);
    defer testing.allocator.free(src);
    try compileOnly(src);
}

test "Audit depth: compiler rejects programmatically built deep trees" {
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

// --- Finding 2: inline cache index overflow --------------------------------

test "Audit limits: more than 65536 inline-cache sites is a compile error" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "x = 1\n");
    for (0..limits.MAX_INLINE_CACHES + 2) |_| try buf.appendSlice(testing.allocator, "x.foo\n");

    var doc = try Document.parse(testing.allocator, buf.items);
    defer doc.deinit();
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try testing.expectError(error.TooManyInlineCaches, comp.compile(doc.tree.root));
}

test "Audit limits: disassembler decodes inline-cache operands and 32-bit jumps" {
    const source =
        \\x = 1
        \\if x
        \\  x.foo
        \\end
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disassembler.disassembleChunk(testing.allocator, &out_chunk, "main", &out.writer);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "| ic 0") != null);
    // Staying in sync means the final instruction is decoded as op_return
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, text, "\n"), "op_return"));
}

// --- Findings 3 & 4: case jump table ----------------------------------------

test "Audit case: more than 65535 literal conditions do not overflow" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "case 1\nwhen 1");
    for (0..limits.MAX_JUMP_TABLE_CASES + 1) |_| try buf.appendSlice(testing.allocator, ",1");
    try buf.appendSlice(testing.allocator, "\n  10\nend\n");

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const res = try run(&vm, buf.items);
    try testing.expectEqual(.ok, res.status);
    try testing.expectEqual(@as(f64, 10), res.top.asNumber());
}

test "Audit case: duplicate literal keys keep first-match order" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const res = try run(&vm, "case 1 when 1 then 10 when 1 then 20 end");
    try testing.expectEqual(.ok, res.status);
    try testing.expectEqual(@as(f64, 10), res.top.asNumber());

    var vm2 = try VM.init(testing.allocator, testing.io);
    defer vm2.deinit();
    try registry.registerStandardLibrary(&vm2);
    const res2 = try run(&vm2, "case \"b\" when \"a\", \"b\" then 1 when \"b\" then 2 else 3 end");
    try testing.expectEqual(.ok, res2.status);
    try testing.expectEqual(@as(f64, 1), res2.top.asNumber());
}

// --- Finding 5: parameter count ---------------------------------------------

fn paramSource(comptime fmt: []const u8, count: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "def f(");
    for (0..count) |i| {
        if (i > 0) try buf.appendSlice(testing.allocator, ", ");
        try buf.print(testing.allocator, fmt, .{i});
    }
    try buf.appendSlice(testing.allocator, ")\n  1\nend\n");
    return buf.toOwnedSlice(testing.allocator);
}

test "Audit params: 300 positional parameters are rejected by the parser" {
    const src = try paramSource("p{d}", 300);
    defer testing.allocator.free(src);
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expect(hasDiagnostic(&doc, "Too many parameters"));
}

test "Audit params: 300 keyword parameters are rejected by the parser" {
    const src = try paramSource("k{d}: 1", 300);
    defer testing.allocator.free(src);
    var doc = try Document.parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expect(hasDiagnostic(&doc, "Too many parameters"));
}

test "Audit params: frame slot overflow from mixed params is a compile error" {
    // 250 positionals + 5 keywords pass the parser's count check but need
    // 250 + kwarg map + block + 5 virtual slots = 257 > u8 slots.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "def f(");
    for (0..250) |i| try buf.print(testing.allocator, "p{d}, ", .{i});
    try buf.appendSlice(testing.allocator, "k0: 1, k1: 1, k2: 1, k3: 1, k4: 1)\n  1\nend\n");
    try testing.expectError(error.TooManyParameters, compileOnly(buf.items));
}

// --- Finding 6: non-local jumps out of begin/rescue/ensure -------------------

test "Audit rescue: return inside begin/rescue pops the handler" {
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

test "Audit rescue: break out of begin/rescue in a loop pops the handler" {
    const source =
        \\def g
        \\  hits = 0
        \\  begin
        \\    i = 0
        \\    while i < 1
        \\      i += 1
        \\      begin
        \\        break
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
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const res = try run(&vm, source);
    try testing.expectEqual(.ok, res.status);
    // Only the outer rescue may catch the later error
    try testing.expectEqual(@as(f64, 1), res.top.asNumber());
}

test "Audit rescue: next inside begin/rescue in a loop pops the handler" {
    const source =
        \\def g
        \\  hits = 0
        \\  begin
        \\    i = 0
        \\    while i < 3
        \\      i += 1
        \\      begin
        \\        next
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
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const res = try run(&vm, source);
    try testing.expectEqual(.ok, res.status);
    try testing.expectEqual(@as(f64, 1), res.top.asNumber());
}

test "Audit rescue: return and break run the ensure body" {
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

// --- Finding 7: source size / token count ----------------------------------

test "Audit limits: Document.parse rejects sources over MAX_SOURCE_BYTES" {
    const src = try testing.allocator.alloc(u8, limits.MAX_SOURCE_BYTES + 1);
    defer testing.allocator.free(src);
    @memset(src, ' ');
    try testing.expectError(error.SourceTooLarge, Document.parse(testing.allocator, src));
}

// --- GC rooting of functions under construction (reported by the VM audit) ---

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

test "Audit GC: functions stay rooted while def/attr macros allocate under stress GC" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
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
        \\[p.name, p.age, p.label("!")]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
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
}
