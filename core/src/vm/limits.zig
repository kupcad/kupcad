const std = @import("std");
const builtin = @import("builtin");

// Bytecode & Operand Limits
pub const MAX_CONSTANTS: usize = std.math.maxInt(u16); // 65_535
pub const MAX_SHORT_CONSTANTS: usize = std.math.maxInt(u8); // 255
pub const MAX_LOCALS: usize = std.math.maxInt(u16); // 65_535
pub const MAX_UPVALUES: usize = std.math.maxInt(u8); // 255
pub const MAX_ARGS: usize = std.math.maxInt(u8); // 255
pub const MAX_HASH_ENTRIES: usize = MAX_CONSTANTS / 2; // 32_767

// Runtime Execution Limits
pub const INITIAL_STACK_CAPACITY: usize = 1024;
pub const MAX_CALL_FRAMES: usize = 4096; // Safely expanded for deep recursive modeling!
// Compile-Time Platform Detection:
// WASM -> 100M Gas Cap to protect Web Worker UI threads
// Native Desktop -> 0 (Unlimited gas for heavy local batch modeling)
pub const DEFAULT_INSTRUCTION_LIMIT: usize = if (builtin.cpu.arch.isWasm())
    100_000_000
else
    0;
