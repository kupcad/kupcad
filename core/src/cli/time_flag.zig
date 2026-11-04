//! `--timeout <time>`, and `KUPCAD_TIMEOUT` in the environment: the most time a run may take
//! (VM.setTimeLimit), for a host that runs scripts someone else wrote, or a CI job a script
//! that never ends would hold until the runner's own limit. A run past it fails as a script
//! error, "Time limit: ...". The flag wins over the variable; without either a run has no time
//! limit. `kupcad watch` gives each build the whole of it (ScriptSession.evaluateWorkspace).

const std = @import("std");
const LimitFlag = @import("limit_flag.zig").LimitFlag;

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
const UNITS = [_]struct { suffix: []const u8, ms: u64 }{
    .{ .suffix = "ms", .ms = 1 },
    .{ .suffix = "s", .ms = 1000 },
    .{ .suffix = "m", .ms = 60 * 1000 },
    .{ .suffix = "h", .ms = 60 * 60 * 1000 },
};

/// The milliseconds `text` says: a whole number greater than zero with a unit (ms, s, m or h,
/// in any case), or seconds alone; null for anything else, or a time past what a u64 counts.
pub fn parseTime(text: []const u8) ?u64 {
    var number = text;
    var unit: u64 = 1000;
    for (UNITS) |u| {
        if (text.len > u.suffix.len and std.ascii.endsWithIgnoreCase(text, u.suffix)) {
            number = text[0 .. text.len - u.suffix.len];
            unit = u.ms;
            break;
        }
    }
    for (number) |c| if (!std.ascii.isDigit(c)) return null;
    const count = std.fmt.parseInt(u64, number, 10) catch return null;
    if (count == 0) return null;
    return std.math.mul(u64, count, unit) catch null;
}
