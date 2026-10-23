//! Every wide opcode, emitted and run: past 255 constants, locals or entries an
//! instruction's operand takes two bytes, a path ordinary scripts never reach. Each case
//! follows an array of hundreds of constants (and has it again where it writes `{PAD}`:
//! each function has its own constants, a method's keywords are read before its body),
//! so whatever it names
//! lands past index 255, and must compile to the wide form and give the right answer. An
//! opcode added without a case fails the guard below.

const std = @import("std");
const testing = std.testing;
const chunk = @import("../vm/chunk.zig");
const disassembler = @import("../tools/dev/disassembler.zig");
const Document = @import("../frontend/document.zig").Document;
const Compiler = @import("compiler.zig").Compiler;
const support = @import("../test_support.zig");

/// How many distinct constants the padding array holds.
const PADDING_CONSTANTS = 300;
const PAD_MARK = "{PAD}";
/// More locals than a one-byte slot reaches.
const WIDE_LOCALS = 300;

const Case = struct {
    ops: []const chunk.OpCode,
    src: []const u8,
    expected: f64,
};

const CASES = [_]Case{
    .{ .ops = &.{ .op_constant_wide, .op_define_global_wide, .op_get_global_wide }, .src = "g = 7.25\nr = g + 1", .expected = 8.25 },
    .{ .ops = &.{.op_closure_wide}, .src = "add = ->(x) { x + 1 }\nr = add.call(1)", .expected = 2 },
    .{ .ops = &.{ .op_class_wide, .op_method_wide, .op_get_ivar_wide, .op_invoke_wide }, .src = "class P\n  def initialize(w)\n    @w = w\n  end\n  def twice(k)\n    _pad = {PAD}\n    @w * k\n  end\nend\nr = P.new(5).twice(2)", .expected = 10 },
    .{ .ops = &.{ .op_get_property_wide, .op_set_property_wide }, .src = "class Q\n  attr_accessor :zz\nend\nq = Q.new\nq.zz = 4\nq.zz += 2\nr = q.zz", .expected = 6 },
    .{ .ops = &.{ .op_get_class_var_wide, .op_set_class_var_wide, .op_class_method_wide }, .src = "class C\n  _pad = {PAD}\n  @@n = 2\n  def self.bump\n    _pad = {PAD}\n    @@n = @@n + 1\n  end\nend\nr = C.bump", .expected = 3 },
    .{ .ops = &.{ .op_module_wide, .op_set_member_wide }, .src = "module M\n  _pad = {PAD}\n  X = 6\nend\nr = M::X", .expected = 6 },
    .{ .ops = &.{.op_defined_wide}, .src = "zq = 1\nr = defined?(zq) ? 1 : 0", .expected = 1 },
    .{ .ops = &.{.op_extract_kwarg_wide}, .src = "def k(p: {PAD}, a: 1, b: 2)\n  a + b\nend\nr = k(b: 5)", .expected = 6 },
};

/// What a case can't be written to reach, and why.
const UNCOVERED = [_]struct { op: chunk.OpCode, reason: []const u8 }{
    .{ .op = .op_import_wide, .reason = "an import needs a file; import_test.zig runs them" },
};

/// The cases a generated script reaches without PADDING, by their opcodes alone (the
/// sources are built at run time).
const GENERATED_OPS = [_]struct { ops: []const chunk.OpCode }{
    .{ .ops = &.{ .op_get_local_wide, .op_set_local_wide } },
    .{ .ops = &.{.op_build_array_wide} },
    .{ .ops = &.{.op_build_map_wide} },
    .{ .ops = &.{.op_switch_wide} },
};

comptime {
    @setEvalBranchQuota(100_000);
    for (@typeInfo(chunk.OpCode).@"enum".field_names) |name| {
        if (!std.mem.endsWith(u8, name, "_wide")) continue;
        const op = @field(chunk.OpCode, name);
        const covered = for (CASES) |case| {
            if (std.mem.findScalar(chunk.OpCode, case.ops, op) != null) break true;
        } else for (GENERATED_OPS) |case| {
            if (std.mem.findScalar(chunk.OpCode, case.ops, op) != null) break true;
        } else for (UNCOVERED) |u| {
            if (u.op == op) break true;
        } else false;
        if (!covered) @compileError("chunk." ++ name ++ " has no case in wide_operands_test.zig");
    }
}

test "wide operands: each wide opcode compiles where its operand needs it, and runs right" {
    const padding = try paddingSource();
    defer testing.allocator.free(padding);
    for (CASES) |case| {
        const body = try std.mem.replaceOwned(u8, testing.allocator, case.src, PAD_MARK, padding);
        defer testing.allocator.free(body);
        const source = try std.mem.concat(testing.allocator, u8, &.{ "_pad = ", padding, "\n", body });
        defer testing.allocator.free(source);
        errdefer std.debug.print("case:\n{s}\n", .{case.src});
        try expectWideRun(source, case.ops, case.expected);
    }
}

test "wide operands: many locals, elements, entries and case values" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const w = &out.writer;

    // Locals past slot 255: written and read.
    try w.writeAll("def f\n");
    for (0..WIDE_LOCALS) |i| try w.print("  a{d} = {d}\n", .{ i, i });
    try w.print("  a{d} = a{d} + 1\n  a{d}\nend\nr = f()", .{ WIDE_LOCALS - 1, WIDE_LOCALS - 1, WIDE_LOCALS - 1 });
    try expectWideRun(out.written(), &.{ .op_get_local_wide, .op_set_local_wide }, WIDE_LOCALS);

    out.clearRetainingCapacity();
    try w.writeAll("r = [");
    for (0..WIDE_LOCALS) |_| try w.writeAll("1, ");
    try w.writeAll("].length");
    try expectWideRun(out.written(), &.{.op_build_array_wide}, WIDE_LOCALS);

    out.clearRetainingCapacity();
    try w.writeAll("m = {");
    for (0..WIDE_LOCALS) |i| try w.print("k{d}: {d}, ", .{ i, i });
    try w.print("}}\nr = m.keys.length + m[:k{d}]", .{WIDE_LOCALS - 1});
    try expectWideRun(out.written(), &.{.op_build_map_wide}, WIDE_LOCALS * 2 - 1);

    out.clearRetainingCapacity();
    try w.print("x = {d}\nr = case x\n", .{WIDE_LOCALS - 1});
    for (0..WIDE_LOCALS) |i| try w.print("when {d} then {d}\n", .{ i, i * 2 });
    try w.writeAll("end");
    try expectWideRun(out.written(), &.{.op_switch_wide}, (WIDE_LOCALS - 1) * 2);
}

/// An array of PADDING_CONSTANTS distinct numbers.
fn paddingSource() ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try out.writer.writeAll("[");
    for (0..PADDING_CONSTANTS) |i| try out.writer.print("{d}.5, ", .{i});
    try out.writer.writeAll("]");
    return out.toOwnedSlice();
}

/// Compiles `source`, requires each of `ops` somewhere in its bytecode (functions'
/// included), runs it and requires `r` to be `expected`.
fn expectWideRun(source: []const u8, ops: []const chunk.OpCode, expected: f64) !void {
    var vm = try support.initVm();
    defer vm.deinit();
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    for (ops) |op| {
        errdefer std.debug.print("no {t} in the bytecode\n", .{op});
        try testing.expect(try contains(&out_chunk, op));
    }
    try testing.expectEqual(.ok, vm.interpret(&out_chunk));
    try support.expectValue(.{ .num = expected }, vm.globals.get("r") orelse return error.MissingGlobal);
}

/// Whether `op` starts an instruction in `c` or in a function it holds as a constant.
fn contains(c: *const chunk.Chunk, op: chunk.OpCode) !bool {
    var offset: usize = 0;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    while (offset < c.code.items.len) {
        if (c.code.items[offset] == @backingInt(op)) return true;
        offset = try disassembler.disassembleInstruction(c, offset, &sink.writer);
    }
    for (c.constants.items) |constant| {
        if (!constant.isFunction()) continue;
        const function_chunk: *const chunk.Chunk = @ptrCast(@alignCast(constant.asFunction().chunk orelse continue));
        if (try contains(function_chunk, op)) return true;
    }
    return false;
}
