//! `--timeout <time>`, and `KUPCAD_TIMEOUT` in the environment: the most time a run may take
//! (VM.setTimeLimit), for a host that runs scripts someone else wrote, or a CI job a script
//! that never ends would hold until the runner's own limit. A run past it fails as a script
//! error, "Time limit: ...". The flag wins over the variable; without either a run has no time
//! limit. `kupcad watch` gives each build the whole of it (ScriptSession.evaluateWorkspace).

const limit_flag = @import("limit_flag.zig");
const LimitFlag = limit_flag.LimitFlag;

const Flag = LimitFlag(u64, "--timeout", "KUPCAD_TIMEOUT", "a time greater than zero, as 500ms, 30s or 2m", parseTime);
pub const FLAG = Flag.FLAG;
pub const ENV = Flag.ENV;
pub const take = Flag.take;
pub const fromEnv = Flag.fromEnv;
pub const given = Flag.given;

pub const USAGE =
    \\  --timeout <time>          Most time the run may take, as 500ms, 30s, 2m or 1h (a
    \\                            number alone is seconds), in place of KUPCAD_TIMEOUT
    \\
;

/// Milliseconds in each unit a time may be written in; `ms` before `s`, which it ends with.
const UNITS = [_]limit_flag.Unit(u64){
    .{ .suffix = "ms", .size = 1 },
    .{ .suffix = "s", .size = 1000 },
    .{ .suffix = "m", .size = 60 * 1000 },
    .{ .suffix = "h", .size = 60 * 60 * 1000 },
};

/// The milliseconds `text` says: a whole number greater than zero with a unit (ms, s, m or h,
/// in any case), or seconds alone; null for anything else, or a time past what a u64 counts.
pub fn parseTime(text: []const u8) ?u64 {
    return limit_flag.parseWithUnits(u64, &UNITS, 1000, text);
}
