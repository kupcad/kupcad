//! Every public limit in limits.zig, met by the input a hostile or careless script could
//! give it: the run must stop with a clean error that says what was exceeded (or, for a
//! limit with a fallback, still give the right answer). A limit added to limits.zig
//! without a case in CASES fails to compile, so none goes untested.

const std = @import("std");
const testing = std.testing;
const limits = @import("limits.zig");
const Document = @import("document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const chunk = @import("../vm/chunk.zig");
const VM = @import("../vm/vm.zig").VM;
const InterpretResult = @import("../vm/vm.zig").InterpretResult;
const support = @import("../test_support.zig");

/// The budget the runaway-loop and runaway-heap cases run under: the interactive limits
/// themselves would take seconds of a Debug test run to reach, and the mechanism is the same.
const SMALL_INSTRUCTION_BUDGET: usize = 10_000;
const SMALL_MEMORY_BUDGET: usize = 1024 * 1024;

/// One check per limit, by the limit's name.
const CASES = .{
    .MAX_CONSTANTS = constants,
    .MAX_SHORT_CONSTANTS = shortConstants,
    .MAX_LOCALS = locals,
    .MAX_UPVALUES = upvalues,
    .MAX_ARGS = args,
    .MAX_HASH_ENTRIES = hashEntries,
    .MAX_AST_DEPTH = astDepth,
    .INTERACTIVE_INSTRUCTION_LIMIT = instructionBudget,
    .INTERACTIVE_MEMORY_LIMIT = memoryBudget,
    .DEFAULT_INSTRUCTION_LIMIT = defaultInstructionLimit,
    .MAX_SEGMENTS = segments,
    .MAX_PATTERN_COUNT = patternCount,
    .MAX_RANGE_MATERIALIZE = rangeMaterialize,
    .MAX_NEWTON_TRIALS = newtonTrials,
    .MAX_MARCHING_STEPS = marchingSteps,
    .MAX_SOURCE_BYTES = sourceBytes,
    .MAX_TOKENS = tokens,
    .MAX_INLINE_CACHES = inlineCaches,
    .MAX_JUMP_TABLE_CASES = jumpTableCases,
};

comptime {
    for (std.meta.declarations(limits)) |name| {
        if (!@hasField(@TypeOf(CASES), name)) {
            @compileError("limits." ++ name ++ " has no hostile-input case in limits_test.zig");
        }
    }
}

test "limits: every limit stops a hostile script with a clean error" {
    inline for (@typeInfo(@TypeOf(CASES)).@"struct".field_names) |name| {
        errdefer std.debug.print("limit: {s}\n", .{name});
        try @field(CASES, name)();
    }
}

// --- The cases ---

const TOO_MANY_VARIABLES = std.fmt.comptimePrint("too many variables in one function (at most {d}, and {d} captured from outside)", .{ limits.MAX_LOCALS, limits.MAX_UPVALUES });

fn constants() !void {
    // Distinct literals, each one a constant of the script's function.
    try expectCompileMessage(&.{rep("x = {d}.5\n", limits.MAX_CONSTANTS + 1)}, "this function has too many constants (literals and names); split it up");
}

fn shortConstants() !void {
    // Past the one-byte operand, constants switch to the wide form and still load.
    const count = limits.MAX_SHORT_CONSTANTS + 10;
    try expectRunsTo(&.{rep("r = {d}\n", count)}, count - 1);
}

fn locals() !void {
    try expectCompileMessage(&.{ text("def f\n"), rep("  a{d} = 1\n", limits.MAX_LOCALS + 1), text("end\n") }, TOO_MANY_VARIABLES);
}

fn upvalues() !void {
    // A lambda reading one more of its def's variables than it can capture.
    const count = limits.MAX_UPVALUES + 1;
    try expectCompileMessage(&.{ text("def f\n"), rep("  a{d} = 1\n", count), text("  g = ->() do\n"), rep("    a{d}\n", count), text("  end\nend\n") }, TOO_MANY_VARIABLES);
}

fn args() !void {
    try expectCompileMessage(&.{ text("puts(0"), rep(", {d}", limits.MAX_ARGS), text(")\n") }, std.fmt.comptimePrint("a call takes at most {d} arguments", .{limits.MAX_ARGS}));
}

fn hashEntries() !void {
    // The same key and value throughout, so constants run out only if the check is missing.
    try expectCompileMessage(&.{ text("m = {"), rep("1 => 1, ", limits.MAX_HASH_ENTRIES + 1), text("}\n") }, std.fmt.comptimePrint("a map literal holds at most {d} entries; add the rest with []=", .{limits.MAX_HASH_ENTRIES}));
}

fn astDepth() !void {
    const depth = limits.MAX_AST_DEPTH + 1;
    try expectCompileMessage(&.{ text("x = "), rep("(", depth), text("1"), rep(")", depth) }, "Maximum AST depth exceeded");
}

fn instructionBudget() !void {
    var vm = try support.initVm();
    defer vm.deinit();
    vm.instruction_limit = SMALL_INSTRUCTION_BUDGET;
    try testing.expectEqual(InterpretResult.execution_limit_exceeded, try support.runOn(&vm, "while true\nend"));
    try testing.expect(std.mem.indexOf(u8, vm.last_error orelse "", "Execution limit") != null);
}

fn memoryBudget() !void {
    var vm = try support.initVm();
    defer vm.deinit();
    vm.setMemoryLimit(vm.gc.bytes_allocated + SMALL_MEMORY_BUDGET);
    const result = try support.runOn(&vm, "a = []\nwhile true\n  a.push(\"item #{a.length}\")\nend");
    try testing.expectEqual(InterpretResult.runtime_error, result);
    // The cap is met by whichever allocation crosses it: an object's (a Sandbox Error) or
    // the array's growth (an OutOfMemoryError naming what couldn't grow).
    const message = vm.last_error orelse return error.MissingError;
    try testing.expect(std.mem.indexOf(u8, message, "memory") != null);
}

fn defaultInstructionLimit() !void {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try testing.expectEqual(limits.DEFAULT_INSTRUCTION_LIMIT, vm.instruction_limit);
}

fn segments() !void {
    try expectRescued("cylinder(r: 1, h: 1, segments: 2049)", "ValueError: 'segments' must be between 0 and 2048, got 2049");
}

fn patternCount() !void {
    try expectRescued("cube(1).repeat_linear(10001, [2, 0, 0])", "ValueError: repeat_linear 'count' must be a finite number <= 10000, got 10001");
}

fn rangeMaterialize() !void {
    try expectRescued("(1..10_000_001).to_a", "ValueError: Range#to_a would build an array of 10000001 values (limit 10000000); iterate with each instead");
}

fn newtonTrials() !void {
    try expectRescued("CAD.config(brep: { max_newton_trials: 1001 })", "ValueError: CAD.config: brep max_newton_trials must be 1 to 1000");
}

fn marchingSteps() !void {
    try expectRescued("CAD.config(brep: { max_marching_steps: 100001 })", "ValueError: CAD.config: brep max_marching_steps must be 1 to 100000");
}

fn sourceBytes() !void {
    const source = try testing.allocator.alloc(u8, limits.MAX_SOURCE_BYTES + 1);
    defer testing.allocator.free(source);
    @memset(source, ' ');
    try testing.expectError(error.SourceTooLarge, Document.parse(testing.allocator, source));
}

fn tokens() !void {
    // A token takes at least a byte, plus the end-of-file token, so a source the size
    // limit lets through can't run out of token indices.
    try testing.expect(limits.MAX_SOURCE_BYTES + 1 <= limits.MAX_TOKENS);
}

fn inlineCaches() !void {
    // The limit is the highest cache index, so one more call than it allows is two past it.
    // A local's calls inside a def, so only the method caches grow.
    const allowed = limits.MAX_INLINE_CACHES + 1;
    try expectCompileMessage(&.{ text("def f\n  a = [1]\n"), rep("  a.length\n", allowed + 1), text("end\n") }, std.fmt.comptimePrint("too many method calls in one script (at most {d})", .{allowed}));
    // The same index for each read or assignment of a top-level variable (GlobalCache).
    try expectCompileMessage(&.{ text("a = 1\n"), rep("a\n", allowed) }, std.fmt.comptimePrint("too many uses of top-level variables in one script (at most {d})", .{allowed}));
}

fn jumpTableCases() !void {
    // One literal repeated, so the case fits in the constants; past the jump table's
    // size it compiles to comparisons, which must still find the branch.
    try expectRunsTo(&.{ text("x = 2\nr = case x\nwhen 1"), rep(", 1", limits.MAX_JUMP_TABLE_CASES), text(" then 10\nwhen 2 then 20\nend\n") }, 20);
}

// --- Helpers ---

/// A piece of a generated script.
const Part = union(enum) {
    text: []const u8,
    /// `item` written `count` times, its `{d}` (if any) replaced by the index.
    repeat: struct { item: []const u8, count: usize },
};

fn text(s: []const u8) Part {
    return .{ .text = s };
}

fn rep(item: []const u8, count: usize) Part {
    return .{ .repeat = .{ .item = item, .count = count } };
}

fn build(parts: []const Part) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const w = &out.writer;
    for (parts) |part| switch (part) {
        .text => |s| try w.writeAll(s),
        .repeat => |r| {
            const at = std.mem.indexOf(u8, r.item, "{d}");
            for (0..r.count) |i| {
                if (at) |a| try w.print("{s}{d}{s}", .{ r.item[0..a], i, r.item[a + 3 ..] }) else try w.writeAll(r.item);
            }
        },
    };
    return out.toOwnedSlice();
}

/// Parses and compiles the script, expecting it to be refused with `message`, whether by
/// the parser or the compiler: what the author is shown either way.
fn expectCompileMessage(parts: []const Part, message: []const u8) !void {
    const source = try build(parts);
    defer testing.allocator.free(source);
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    if (doc.diagnostics.len > 0) return testing.expectEqualStrings(message, doc.diagnostics[0].message);

    var vm = try support.initVm();
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    if (comp.compile(doc.tree.root)) |_| return error.TestExpectedError else |_| {}
    const diagnostic = comp.errorDiagnostic() orelse return error.MissingDiagnostic;
    try testing.expectEqualStrings(message, diagnostic.message);
}

/// Runs the script, expecting it to leave the number `expected` in `r`.
fn expectRunsTo(parts: []const Part, expected: f64) !void {
    const source = try build(parts);
    defer testing.allocator.free(source);
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(InterpretResult.ok, try support.runOn(&vm, source));
    try support.expectValue(.{ .num = expected }, vm.globals.get("r") orelse return error.MissingGlobal);
}

/// Runs `src`, expecting it to raise "<Kind>: <message>" as `expected`.
fn expectRescued(comptime src: []const u8, expected: []const u8) !void {
    try support.expectScripts(&.{.{ .src = support.rescued(src), .expected = .{ .str = expected } }});
}
