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
const lexer = @import("../frontend/kupcad/lexer.zig");
const token = @import("../core/token.zig");
const Parser = @import("../frontend/kupcad/parser.zig").Parser;

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

/// `prefix * count ++ middle ++ suffix * count ++ tail`
const NestCase = struct {
    name: []const u8,
    prefix: []const u8,
    middle: []const u8,
    suffix: []const u8,
    tail: []const u8 = "",
    count: usize = DEEP,
};

fn buildNest(c: NestCase) ![]u8 {
    const body = try repeatWrap(c.prefix, c.middle, c.suffix, c.count);
    defer testing.allocator.free(body);
    return std.mem.concat(testing.allocator, u8, &.{ body, c.tail });
}

test "Audit depth: deeply nested constructs report a depth error" {
    // Each row used to recurse without a bound (stack overflow in the parser,
    // resolver or compiler) because only parseExpression counted depth.
    const cases = [_]NestCase{
        .{ .name = "if", .prefix = "if true\n", .middle = "1\n", .suffix = "end\n" },
        .{ .name = "while", .prefix = "while true\n", .middle = "1\n", .suffix = "end\n" },
        .{ .name = "case", .prefix = "case 1\nwhen 1\n", .middle = "1\n", .suffix = "end\n" },
        .{ .name = "begin", .prefix = "begin\n", .middle = "1\n", .suffix = "end\n" },
        .{ .name = "def", .prefix = "def f\n", .middle = "1\n", .suffix = "end\n" },
        .{ .name = "class", .prefix = "class A\n", .middle = "", .suffix = "end\n" },
        .{ .name = "module", .prefix = "module M\n", .middle = "", .suffix = "end\n" },
        .{ .name = "do block", .prefix = "f do\n", .middle = "1\n", .suffix = "end\n" },
        // `elsif` recurses into parseIfOrUnless directly, not through a block
        .{ .name = "elsif", .prefix = "", .middle = "if false\n1\n", .suffix = "elsif false\n1\n", .tail = "end\n" },
        // Infix links are built in a loop but each nests the tree one level deeper
        .{ .name = "method chain", .prefix = "", .middle = "a", .suffix = ".b" },
        .{ .name = "binary chain", .prefix = "", .middle = "x = a", .suffix = " + a", .count = 20000 },
    };
    for (cases) |c| {
        const src = try buildNest(c);
        defer testing.allocator.free(src);
        expectDepthRejected(src) catch |err| {
            std.debug.print("depth case '{s}' failed\n", .{c.name});
            return err;
        };
    }
}

test "Audit depth: nesting below the limit still parses and compiles" {
    // Guards against over-counting: legitimate deep code must not be rejected
    const cases = [_]NestCase{
        .{ .name = "binary chain", .prefix = "", .middle = "x = 1", .suffix = " + 1", .count = limits.MAX_AST_DEPTH / 2 },
        .{ .name = "method chain", .prefix = "", .middle = "x = 1", .suffix = ".to_s", .count = limits.MAX_AST_DEPTH / 2 },
        .{ .name = "if", .prefix = "if true\n", .middle = "1\n", .suffix = "end\n", .count = limits.MAX_AST_DEPTH / 8 },
    };
    for (cases) |c| {
        const src = try buildNest(c);
        defer testing.allocator.free(src);
        compileOnly(src) catch |err| {
            std.debug.print("depth case '{s}' failed\n", .{c.name});
            return err;
        };
    }
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

test "Audit depth: nested closures share one depth budget" {
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

// --- Finding 2: inline cache index overflow --------------------------------

test "Audit limits: inline-cache indexes past 16 bits are a compile error" {
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

test "Audit limits: disassembler decodes inline-cache operands, 32-bit jumps and switch tables" {
    const source =
        \\x = 1
        \\if x
        \\  x.foo
        \\end
        \\case x
        \\when 1 then 10
        \\when 2, 3 then 20
        \\else 30
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
    try testing.expect(std.mem.indexOf(u8, text, "op_switch        3 cases") != null);
    // Staying in sync means the final instruction is decoded as op_return
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, text, "\n"), "op_return"));

    // Every printed jump / switch target must land on an instruction boundary
    var starts: std.ArrayListUnmanaged(usize) = .empty;
    defer starts.deinit(testing.allocator);
    var targets: std.ArrayListUnmanaged(usize) = .empty;
    defer targets.deinit(testing.allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 4 and std.ascii.isDigit(line[0])) {
            try starts.append(testing.allocator, try std.fmt.parseInt(usize, line[0..4], 10));
        }
        if (std.mem.lastIndexOf(u8, line, "-> ")) |arrow| {
            try targets.append(testing.allocator, try std.fmt.parseInt(usize, line[arrow + 3 ..], 10));
        }
    }
    // At least the two `if` jumps plus the switch's three entries and default
    try testing.expect(targets.items.len >= 6);
    for (targets.items) |t| {
        try testing.expect(std.mem.indexOfScalar(usize, starts.items, t) != null);
    }
}

// --- Findings 3 & 4: case jump table ----------------------------------------

test "Audit case: more than MAX_JUMP_TABLE_CASES literal conditions do not overflow" {
    // The u16 condition counter used to overflow; now falls back to linear compares
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "case 1\nwhen 1");
    for (0..limits.MAX_JUMP_TABLE_CASES + 1) |_| try buf.appendSlice(testing.allocator, ",1");
    try buf.appendSlice(testing.allocator, "\n  10\nend\n");
    try expectRunsTo(buf.items, 10);
}

fn expectRunsTo(source: []const u8, expected: f64) !void {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const res = try run(&vm, source);
    try testing.expectEqual(.ok, res.status);
    try testing.expectEqual(expected, res.top.asNumber());
}

test "Audit case: duplicate literal keys keep first-match order" {
    // The VM binary-searches the jump table, so equal keys used to resolve to
    // an arbitrary branch instead of the first `when`.
    try expectRunsTo("case 1 when 1 then 10 when 1 then 20 end", 10);
    try expectRunsTo("case \"b\" when \"a\", \"b\" then 1 when \"b\" then 2 else 3 end", 1);
}

// --- Finding 5: parameter count ---------------------------------------------

/// `open p0, p1, ... close` with each parameter rendered by `fmt` from its index.
fn paramList(open: []const u8, comptime fmt: []const u8, count: usize, close: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, open);
    for (0..count) |i| {
        if (i > 0) try buf.appendSlice(testing.allocator, ", ");
        try buf.print(testing.allocator, fmt, .{i});
    }
    try buf.appendSlice(testing.allocator, close);
    return buf.toOwnedSlice(testing.allocator);
}

const ParamCase = struct {
    name: []const u8,
    open: []const u8,
    fmt: enum { positional, keyword },
    close: []const u8,
};

fn paramCaseSource(c: ParamCase, count: usize) ![]u8 {
    return switch (c.fmt) {
        .positional => paramList(c.open, "p{d}", count, c.close),
        .keyword => paramList(c.open, "k{d}: 1", count, c.close),
    };
}

test "Audit params: more than MAX_ARGS parameters is a parse diagnostic" {
    const cases = [_]ParamCase{
        .{ .name = "def positional", .open = "def f(", .fmt = .positional, .close = ")\n  1\nend\n" },
        .{ .name = "def keyword", .open = "def f(", .fmt = .keyword, .close = ")\n  1\nend\n" },
        .{ .name = "def without parens", .open = "def f ", .fmt = .positional, .close = "\n  1\nend\n" },
        .{ .name = "block", .open = "f do |", .fmt = .positional, .close = "|\n  1\nend\n" },
    };
    for (cases) |c| {
        errdefer std.debug.print("param case '{s}' failed\n", .{c.name});

        const over = try paramCaseSource(c, limits.MAX_ARGS + 1);
        defer testing.allocator.free(over);
        var doc = try Document.parse(testing.allocator, over);
        defer doc.deinit();
        try testing.expect(hasDiagnostic(&doc, "Too many parameters"));

        // Exactly MAX_ARGS is still accepted by the parser
        const at_limit = try paramCaseSource(c, limits.MAX_ARGS);
        defer testing.allocator.free(at_limit);
        var ok_doc = try Document.parse(testing.allocator, at_limit);
        defer ok_doc.deinit();
        try testing.expect(!hasDiagnostic(&ok_doc, "Too many parameters"));
    }
}

test "Audit params: frame slot overflow from mixed params is a compile error" {
    // MAX_ARGS parameters in total pass the parser's count check, but keywords
    // also need the kwarg map slot, the block slot and one virtual slot each,
    // which overflows the u8 frame slots.
    const keywords = 5;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "def f(");
    for (0..limits.MAX_ARGS - keywords) |i| try buf.print(testing.allocator, "p{d}, ", .{i});
    for (0..keywords) |i| try buf.print(testing.allocator, "{s}k{d}: 1", .{ if (i > 0) ", " else "", i });
    try buf.appendSlice(testing.allocator, ")\n  1\nend\n");
    try testing.expectError(error.TooManyParameters, compileOnly(buf.items));

    // A near-limit layout still compiles. (MAX_ARGS - 1 positionals pass the
    // slot check but panic computing the first virtual slot: known bug.)
    const fits = try paramList("def f(", "p{d}", limits.MAX_ARGS - 2, ")\n  1\nend\n");
    defer testing.allocator.free(fits);
    try compileOnly(fits);
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

test "Audit rescue: break/next out of begin/rescue pops the handler" {
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

test "Audit limits: Parser.init rejects more than MAX_TOKENS tokens" {
    // Token indices are u24. Only the tag count is checked (before anything is
    // read), so a tags-only list is enough to hit the cap without ~16M real tokens.
    const tags = try testing.allocator.alloc(lexer.Tag, limits.MAX_TOKENS + 1);
    defer testing.allocator.free(tags);
    @memset(tags, .eof);
    const tokens: token.TokenList(lexer.Tag) = .{ .tags = tags, .starts = &.{}, .lengths = &.{} };
    // Not expectError: on failure it would print all 16M tags
    if (Parser.init(tokens, "", testing.allocator)) |parsed| {
        var parser = parsed;
        parser.deinit();
        return error.TestExpectedTooManyTokens;
    } else |err| try testing.expectEqual(error.TooManyTokens, err);
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
    try testing.expectEqualStrings("hi x", arr.items.items[3].asString().chars);
}
