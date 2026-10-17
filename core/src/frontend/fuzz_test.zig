//! Fuzzing the front end: any bytes go through the lexer, the parser, the linter and the
//! compiler (with its bytecode verifier) without crashing, the compiler never reports an
//! internal error, and a script that parses formats to the same program, stably (formatting
//! the output again changes nothing). A plain test run replays the corpus below; on Linux,
//! `zig build test --fuzz` searches from it (the nightly CI job).

const std = @import("std");
const testing = std.testing;
const api = @import("../api.zig");
const Document = @import("../core/document.zig").Document;
const examples = @import("examples");

/// The longest input the fuzzer makes: room for every corpus entry.
const MAX_INPUT_BYTES = 16 * 1024;
/// What describeError calls an error that is the compiler's fault, not the script's.
const INTERNAL_COMPILER_ERROR = "internal compiler error";

/// Snippets that reach each part of the grammar, then the lint snapshot cases and the examples.
const CORPUS = [_][]const u8{
    "",
    "x = 1 + 2 * (3 - 4) / 5 % 6 ** 2\ny = -x\nz = !true && false || nil",
    "s = \"a #{1 + 2} b\\n\\t\"\nt = 'raw #{x}'\nu = :sym\nv = :\"with space\"",
    "h = <<~EOS\n  line #{1}\n  two\nEOS\nputs(h)",
    "a = [1, *[2, 3], 4]\nm = { k: 1, \"s\" => 2, **{ j: 3 } }\nr = (1..5).to_a + (1...5).to_a",
    "def f(a, b = 2, *rest, k: 3, **opts, &blk)\n  yield(a) if block_given?\n  return a + b\nend\nf(1) { |x| x * 2 }",
    "class P < Object\n  attr_accessor :x\n  @@count = 0\n  def initialize(x)\n    @x = x\n  end\n  def self.make = P.new(1)\nend\nmodule M\n  X = 1\nend\nM::X",
    "g = ->(x, y = 1) { x + y }\nh = ->(n) do\n  n * 2\nend\ng.call(1).then { |v| h.call(v) }",
    "case x\nwhen 1, 2 then :a\nwhen String then :b\nelse :c\nend\nwhile i < 3\n  i += 1\n  next if i == 2\n  break if i > 5\nend\nfor v in [1, 2]\n  puts(v)\nend",
    "r = begin\n  raise ArgumentError, \"no\"\nrescue ArgumentError => e\n  e.message\nensure\n  puts(1)\nend\nunless false\n  a ||= 1\n  b &&= 2\nend",
    "import { thing as other } from \"./lib.kup\"\nexport { part }\n# @param width The width\nwidth = param(:width, 10, min: 1)\npart = cube(width).translate(x: 1)&.rotate(z: 45)",
    "CAD.with_config(engine: :brep) do\n  cube(1)\nend\nx = cond ? 1 : 2\nobj&.call\n[1, 2].each_with_index { |v, i| v }",
    @embedFile("../tools/lint/snapshots/brep_unsupported.kup"),
    @embedFile("../tools/lint/snapshots/clean_model.kup"),
    @embedFile("../tools/lint/snapshots/compile_error.kup"),
    @embedFile("../tools/lint/snapshots/fixes.kup"),
    @embedFile("../tools/lint/snapshots/nonpositive_size.kup"),
    @embedFile("../tools/lint/snapshots/param_order.kup"),
    @embedFile("../tools/lint/snapshots/segments_as_sides.kup"),
    @embedFile("../tools/lint/snapshots/self_subtraction.kup"),
    @embedFile("../tools/lint/snapshots/suppressed_error.kup"),
    @embedFile("../tools/lint/snapshots/suppressions.kup"),
    @embedFile("../tools/lint/snapshots/syntax_error.kup"),
    @embedFile("../tools/lint/snapshots/unknown_keyword.kup"),
    @embedFile("../tools/lint/snapshots/unreachable_code.kup"),
    @embedFile("../tools/lint/snapshots/unused_param_dynamic.kup"),
    @embedFile("../tools/lint/snapshots/unused_param.kup"),
    @embedFile("../tools/lint/snapshots/unused_variable.kup"),
} ++ blk: {
    var sources: [examples.names.len][]const u8 = undefined;
    for (examples.names, &sources) |name, *source| source.* = @embedFile("example/" ++ name);
    break :blk sources;
};

comptime {
    for (CORPUS) |entry| {
        if (entry.len > MAX_INPUT_BYTES) @compileError("a corpus entry is longer than MAX_INPUT_BYTES");
    }
}

test "fuzz: the front end takes any input" {
    const buf = try testing.allocator.create([MAX_INPUT_BYTES]u8);
    defer testing.allocator.destroy(buf);
    try testing.fuzz(buf, frontEnd, .{ .corpus = &CORPUS });
}

fn frontEnd(buf: *[MAX_INPUT_BYTES]u8, smith: *testing.Smith) anyerror!void {
    const source = buf[0..smith.slice(buf)];
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    const diagnostics = try api.checkDocument(testing.allocator, testing.io, &doc, .{});
    defer api.freeDiagnostics(testing.allocator, diagnostics);
    for (diagnostics) |d| {
        errdefer std.debug.print("source:\n{s}\n", .{source});
        try testing.expect(!std.mem.eql(u8, d.message, INTERNAL_COMPILER_ERROR));
    }

    if (doc.diagnostics.len > 0 or doc.tree.root == .none) return;
    errdefer std.debug.print("source:\n{s}\n", .{source});
    const formatted = try api.formatDocument(testing.allocator, &doc, .{});
    defer testing.allocator.free(formatted);
    var again = try Document.parse(testing.allocator, formatted);
    defer again.deinit();
    const twice = try api.formatDocument(testing.allocator, &again, .{});
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(formatted, twice);
}
