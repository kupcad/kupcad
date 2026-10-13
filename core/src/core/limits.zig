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
pub const INITIAL_STACK_CAPACITY: usize = 1024;
// Compile-Time Platform Detection:
// WASM -> 100M Gas Cap to protect Web Worker UI threads
// Native Desktop -> 0 (Unlimited gas for heavy local batch modeling)
pub const DEFAULT_INSTRUCTION_LIMIT: usize = if (builtin.target.cpu.arch == .wasm32)
    100_000_000
else
    0;

// Geometry input limits
// Upper bound for any user-supplied tessellation count (segments, sides, slices,
// fixed_segments). Chosen so that MAX_SEGMENTS^2 (~4.2M) stays under the default
// 5M `max_vertices` budget in engine_config.zig: two-parameter surfaces such as a
// sphere or torus scale quadratically, and that budget is only enforced *after*
// the kernel has already allocated the mesh.
pub const MAX_SEGMENTS: i32 = 2048;
// Upper bound for repeat_linear / repeat_polar copy counts. Each copy adds a
// translate node plus a union node to the DAG, so this caps DAG growth per call.
pub const MAX_PATTERN_COUNT: usize = 10_000;
// Upper bound for one native iteration (Range#each/map/to_a, Number#times/upto/downto).
// These loops run inside a native call, so an accidental `(0..1e18).each` would never
// return to the dispatch loop's instruction budget; a `while` loop stays interruptible.
pub const MAX_RANGE_ITERATIONS: usize = 10_000_000;
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
// The parser stores token indices as u24. Keep one index of headroom so the
// one-token lookahead (`tok_idx + 1`) can never overflow.
pub const MAX_TOKENS: usize = std.math.maxInt(u24) - 1;
// Inline-cache indices are encoded as a 16-bit operand after property/invoke ops.
pub const MAX_INLINE_CACHES: usize = std.math.maxInt(u16); // highest valid index
// op_switch_wide encodes its case count as a 16-bit operand. Larger literal
// `case` statements fall back to linear comparisons instead of a jump table.
pub const MAX_JUMP_TABLE_CASES: usize = std.math.maxInt(u16);
