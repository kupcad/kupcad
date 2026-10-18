//! The fuzzers' corpus: grammar snippets, the programs in fuzz_corpus/ (`canonical/` already
//! in the formatter's style, `raw/` in layouts and literals it rewrites; `pnpm
//! check:examples` keeps both lint-clean and the first formatted), the lint snapshot cases
//! and the examples. The front end's fuzz test (fuzz_test.zig) and the runtime's
//! (vm/fuzz_test.zig) start from it.

const examples = @import("examples");

/// The longest input the fuzzer makes: room for every corpus entry.
pub const MAX_INPUT_BYTES = 16 * 1024;

pub const CORPUS_DIR = "src/frontend/fuzz_corpus";
/// fuzz_corpus/canonical/<name>.kup: programs already in the formatter's style.
pub const CANONICAL = [_][]const u8{
    "cad_model",    "classes_modules", "collections", "control_flow", "methods_blocks",  "mixins_visibility",
    "numbers_math", "operators",       "parts_lib",   "shapes",       "strings_objects", "uses_lib",
};
/// fuzz_corpus/raw/<name>.kup: programs in layouts and literals the formatter rewrites.
pub const RAW = [_][]const u8{ "layout", "literals" };

/// Snippets that reach each part of the grammar, then the corpus files, the lint snapshot
/// cases and the examples.
pub const CORPUS = [_][]const u8{
    "",
    "x = 1 + 2 * (3 - 4) / 5 % 6 ** 2\ny = -x\nz = !true && false || nil",
    "s = \"a #{1 + 2} b\\n\\t\"\nt = 'raw #{x}'\nu = :sym\nv = :\"with space\"",
    "h = <<~EOS\n  line #{1}\n  two\nEOS\nputs(h)",
    "puts(<<~A.upcase, <<-B) # two bodies\n    a\\t\n      b\n  A\n  c\n  B\nx = <<C + \"!\"\nC\n",
    "a = [1, *[2, 3], 4]\nm = { k: 1, \"s\" => 2, **{ j: 3 } }\nr = (1..5).to_a + (1...5).to_a",
    "def f(a, b = 2, *rest, k: 3, **opts, &blk)\n  yield(a) if block_given?\n  return a + b\nend\nf(1) { |x| x * 2 }",
    "class P < Object\n  attr_accessor :x\n  @@count = 0\n  def initialize(x)\n    @x = x\n  end\n  def self.make = P.new(1)\nend\nmodule M\n  X = 1\nend\nM::X",
    "g = ->(x, y = 1) { x + y }\nh = ->(n) do\n  n * 2\nend\ng.call(1).then { |v| h.call(v) }",
    "case x\nwhen 1, 2 then :a\nwhen String then :b\nelse :c\nend\nwhile i < 3\n  i += 1\n  next if i == 2\n  break if i > 5\nend\nfor v in [1, 2]\n  puts(v)\nend",
    "r = begin\n  raise ArgumentError, \"no\"\nrescue ArgumentError => e\n  e.message\nensure\n  puts(1)\nend\nunless false\n  a ||= 1\n  b &&= 2\nend",
    "import { thing as other } from \"./lib.kup\"\nexport { part }\n# @param width The width\nwidth = param(:width, 10, min: 1)\npart = cube(width).translate(x: 1)&.rotate(z: 45)",
    "CAD.with_config(engine: :brep) do\n  cube(1)\nend\nx = cond ? 1 : 2\nobj&.call\n[1, 2].each_with_index { |v, i| v }",
    // Recursions through built-ins, which stop at the VM's nested-run limit (they crashed it)
    "def f(n) = n == 0 ? 0 : [1].map { |x| f(n - 1) + x }[0]\nf(5000)",
    "class Loop < RuntimeError\n  def initialize\n    raise Loop\n  end\nend\nraise Loop",
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
} ++ corpusFiles("canonical", &CANONICAL) ++ corpusFiles("raw", &RAW) ++ blk: {
    var sources: [examples.names.len][]const u8 = undefined;
    for (examples.names, &sources) |name, *source| source.* = @embedFile("example/" ++ name);
    break :blk sources;
};

fn corpusFiles(comptime sub_dir: []const u8, comptime names: []const []const u8) [names.len][]const u8 {
    var sources: [names.len][]const u8 = undefined;
    for (names, &sources) |name, *source| source.* = @embedFile("fuzz_corpus/" ++ sub_dir ++ "/" ++ name ++ ".kup");
    return sources;
}

comptime {
    for (CORPUS) |entry| {
        if (entry.len > MAX_INPUT_BYTES) @compileError("a corpus entry is longer than MAX_INPUT_BYTES");
    }
}
