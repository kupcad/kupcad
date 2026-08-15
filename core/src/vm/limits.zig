const std = @import("std");

// Bytecode & Operand Limits
pub const MAX_CONSTANTS: usize = std.math.maxInt(u8); // 255 (TODO: op_constant_wide)
pub const MAX_LOCALS: usize = std.math.maxInt(u8); // 255
pub const MAX_UPVALUES: usize = std.math.maxInt(u8); // 255
pub const MAX_ARGS: usize = std.math.maxInt(u8); // 255
pub const MAX_HASH_ENTRIES: usize = MAX_CONSTANTS / 2; // 127

// Compiler Flow Control Limits
pub const MAX_LOOPS: usize = 16;
pub const MAX_LOOP_EXITS: usize = 32;
pub const MAX_CASE_BRANCHES: usize = 64;
pub const MAX_RESCUE_CLAUSES: usize = 64;
pub const MAX_RESCUE_ERRORS: usize = 16;

// Runtime Execution Limits
pub const INITIAL_STACK_CAPACITY: usize = 1024;
pub const MAX_CALL_FRAMES: usize = 64;
pub const DEFAULT_INSTRUCTION_LIMIT: usize = 1_000_000;
