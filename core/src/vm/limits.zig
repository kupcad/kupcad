const std = @import("std");

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
pub const DEFAULT_INSTRUCTION_LIMIT: usize = 1_000_000;
