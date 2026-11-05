//! `--memory-limit <size>`, and `KUPCAD_MEMORY_LIMIT` in the environment: the most script heap
//! a run may hold (what `vm_memory_limit` in .kupcad.json limits), for a host that runs scripts
//! someone else wrote (the desktop app, the VS Code extension, from their settings; a shell or
//! a CI job, from the variable). The flag wins over the variable, and either over the
//! project's file, as `-p` does over a parameter's default: with one the project's
//! `vm_memory_limit` doesn't apply, so a cloned project can't lift the host's limit and a
//! setting raised always takes. Without any a command keeps its own default: none for `build`
//! and `run`, the interactive one for `watch` and `lsp`.

const limit_flag = @import("limit_flag.zig");
const LimitFlag = limit_flag.LimitFlag;

const Flag = LimitFlag(usize, "--memory-limit", "KUPCAD_MEMORY_LIMIT", "a size greater than zero, as 512MB or 8GB", parseSize);
pub const FLAG = Flag.FLAG;
pub const ENV = Flag.ENV;
pub const take = Flag.take;
pub const fromEnv = Flag.fromEnv;
pub const given = Flag.given;

pub const USAGE =
    \\  --memory-limit <size>     Most memory the script may hold, as 512MB or 8GB, in
    \\                            place of KUPCAD_MEMORY_LIMIT and the project's
    \\                            vm_memory_limit
    \\
;

/// Bytes in each unit a size may be written in, 1024-based as memory is counted.
const UNITS = [_]limit_flag.Unit(usize){
    .{ .suffix = "GB", .size = 1024 * 1024 * 1024 },
    .{ .suffix = "MB", .size = 1024 * 1024 },
    .{ .suffix = "KB", .size = 1024 },
    .{ .suffix = "B", .size = 1 },
};

/// The bytes `text` says: a whole number greater than zero with a unit (GB, MB, KB or B, in
/// any case), or bytes alone; null for anything else, or a size past what memory counts.
pub fn parseSize(text: []const u8) ?usize {
    return limit_flag.parseWithUnits(usize, &UNITS, 1, text);
}

/// The limit a run gets: the one `given` (the flag's, else the variable's), as the command line
/// and the environment win over the project's file; else the project's; else the command's
/// `default` (null: none).
pub fn limitFor(project: ?usize, given_limit: ?usize, default: ?usize) ?usize {
    return given_limit orelse project orelse default;
}
