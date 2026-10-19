//! The fixed limits of the language and its runtime: bytecode operand widths, AST depth,
//! instruction and memory budgets for interactive runs, and caps on user-supplied geometry
//! counts, source size, data files and B-Rep solver iterations.

const std = @import("std");
const builtin = @import("builtin");

// Bytecode & Operand Limits
pub const MAX_CONSTANTS: usize = std.math.maxInt(u16); // 65_535
pub const MAX_SHORT_CONSTANTS: usize = std.math.maxInt(u8); // 255
pub const MAX_LOCALS: usize = std.math.maxInt(u16); // 65_535
pub const MAX_UPVALUES: usize = std.math.maxInt(u8); // 255
pub const MAX_ARGS: usize = std.math.maxInt(u8); // 255
pub const MAX_HASH_ENTRIES: usize = MAX_CONSTANTS / 2; // 32_767
pub const MAX_AST_DEPTH: usize = 1500;

// Runtime Execution Limits
/// Most instructions one run may take where a person waits on it: the browser's worker and
/// the editor's language server, which answers nothing else while a script runs. A script
/// that loops forever stops with an error there instead of hanging them.
pub const INTERACTIVE_INSTRUCTION_LIMIT: usize = 100_000_000;
/// Most script heap (strings, arrays, maps, instances: what the GC tracks, not the kernel's
/// meshes) one run may hold where a server runs scripts for others (the language server,
/// `kupcad watch`): a loop that fills an array forever stops with an error instead of
/// taking the machine down. A project sets its own with `vm_memory_limit` in .kupcad.json.
pub const INTERACTIVE_MEMORY_LIMIT: usize = 1024 * 1024 * 1024;
// Compile-Time Platform Detection:
// WASM -> the interactive cap, to protect Web Worker UI threads
// Native Desktop -> 0 (Unlimited gas for heavy local batch modeling)
pub const DEFAULT_INSTRUCTION_LIMIT: usize = if (builtin.target.cpu.arch == .wasm32)
    INTERACTIVE_INSTRUCTION_LIMIT
else
    0;

// Geometry input limits
// Upper bound for any user-supplied tessellation count (segments, sides, slices,
// CAD.config resolution segments). Chosen so that MAX_SEGMENTS^2 (~4.2M) stays under the default
// 5M `max_vertices` budget in engine_config.zig: two-parameter surfaces such as a
// sphere or torus scale quadratically, and that budget is only enforced *after*
// the kernel has already allocated the mesh.
pub const MAX_SEGMENTS: i32 = 2048;
// Upper bound for repeat_linear / repeat_polar copy counts. Each copy adds a
// translate node plus a union node to the DAG, so this caps DAG growth per call.
pub const MAX_PATTERN_COUNT: usize = 10_000;
// Largest array a range may materialize (Range#to_a, and the array Range#map returns).
// Block-driven iteration (each, times, upto, downto) is NOT capped: every block call runs
// through the dispatch loop, which checks cancellation and the instruction budget, just
// like a `while` loop. Building an array is bounded by memory instead: 10M values is
// ~130 MB, and the native build has no memory limit by default.
pub const MAX_RANGE_MATERIALIZE: usize = 10_000_000;
// Upper bounds for the B-Rep solver iteration budgets set via CAD.config(brep: ...).
// Both are per-call loops, so an unbounded user value turns one projection or
// intersection into an effective hang. The caps sit 20x/200x above the defaults
// in engine_config.zig (50 and 500); Newton converges quadratically, so a root
// not found within 1000 trials is diverging, not slow.
pub const MAX_NEWTON_TRIALS: u32 = 1_000;
pub const MAX_MARCHING_STEPS: u32 = 100_000;

// Frontend & compiler limits
// Largest source accepted by Document.parse. Matches the CLI's file cap so the
// LSP and WASM entry points (which bypass the CLI) get the same protection; it
// also keeps the token count far below MAX_TOKENS (at most one token per byte).
pub const MAX_SOURCE_BYTES: usize = 10 * 1024 * 1024; // 10 MiB
// Largest JSON file `import_json` reads: its values take several times its size.
pub const MAX_JSON_BYTES: usize = 64 * 1024 * 1024; // 64 MiB
// Deepest nesting of objects and arrays `import_json` reads, and JsonObject#to_h copies:
// both recurse, one native call level per level.
pub const MAX_JSON_DEPTH: usize = 256;
// The parser stores token indices as u24. Keep one index of headroom so the
// one-token lookahead (`tok_idx + 1`) can never overflow.
pub const MAX_TOKENS: usize = std.math.maxInt(u24) - 1;
// Inline-cache indices are encoded as a 16-bit operand after property/invoke ops.
pub const MAX_INLINE_CACHES: usize = std.math.maxInt(u16); // highest valid index
// op_switch_wide encodes its case count as a 16-bit operand. Larger literal
// `case` statements fall back to linear comparisons instead of a jump table.
pub const MAX_JUMP_TABLE_CASES: usize = std.math.maxInt(u16);
