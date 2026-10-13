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
