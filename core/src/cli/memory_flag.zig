//! `--memory-limit <size>`, and `KUPCAD_MEMORY_LIMIT` in the environment: the most script heap
//! a run may hold (what `vm_memory_limit` in .kupcad.json limits), for a host that runs scripts
//! someone else wrote (the desktop app, the VS Code extension, from their settings; a shell or
//! a CI job, from the variable). The flag wins over the variable, and either over the
//! project's file, as `-p` does over a parameter's default: with one the project's
//! `vm_memory_limit` doesn't apply, so a cloned project can't lift the host's limit and a
//! setting raised always takes. Without any a command keeps its own default: none for `build`
//! and `run`, the interactive one for `watch` and `lsp`.

const std = @import("std");
const Reporter = @import("reporter.zig").Reporter;
const Taken = @import("param_flags.zig").Taken;

pub const FLAG = "--memory-limit";
/// The variable read when the flag isn't given; empty counts as unset.
pub const ENV = "KUPCAD_MEMORY_LIMIT";

pub const USAGE =
    \\  --memory-limit <size>     Most memory the script may hold, as 512MB or 8GB, in
    \\                            place of KUPCAD_MEMORY_LIMIT and the project's
    \\                            vm_memory_limit
    \\
;

/// Bytes in each unit a size may be written in, 1024-based as memory is counted.
const UNITS = [_]struct { suffix: []const u8, bytes: usize }{
    .{ .suffix = "GB", .bytes = 1024 * 1024 * 1024 },
    .{ .suffix = "MB", .bytes = 1024 * 1024 },
    .{ .suffix = "KB", .bytes = 1024 },
    .{ .suffix = "B", .bytes = 1 },
};

/// The bytes `text` says: a whole number greater than zero with a unit (GB, MB, KB or B, in
/// any case), or bytes alone; null for anything else, or a size past what memory counts.
pub fn parseSize(text: []const u8) ?usize {
    var number = text;
    var unit: usize = 1;
    for (UNITS) |u| {
        if (text.len > u.suffix.len and std.ascii.endsWithIgnoreCase(text, u.suffix)) {
            number = text[0 .. text.len - u.suffix.len];
            unit = u.bytes;
            break;
        }
    }
    for (number) |c| if (!std.ascii.isDigit(c)) return null;
    const count = std.fmt.parseInt(usize, number, 10) catch return null;
    if (count == 0) return null;
    return std.math.mul(usize, count, unit) catch null;
}

/// Takes `--memory-limit <size>` into `limit` when `arg` is the flag, reporting a size that
/// isn't one.
pub fn take(arg: []const u8, args: anytype, limit: *?usize, reporter: Reporter) Taken {
    if (!std.mem.eql(u8, arg, FLAG)) return .other;
    const text = args.next() orelse "";
    limit.* = parseSize(text) orelse {
        reporter.err("Error: {s} takes a size greater than zero, as 512MB or 8GB, got '{s}'\n", .{ FLAG, text });
        return .refused;
    };
    return .taken;
}

/// `KUPCAD_MEMORY_LIMIT`'s size (as the flag reads one), null when it is unset or empty; a
/// value that isn't a size is reported and refused, as the flag's would be.
pub fn fromEnv(environ: *const std.process.Environ.Map, reporter: Reporter) error{Refused}!?usize {
    const text = environ.get(ENV) orelse return null;
    if (text.len == 0) return null;
    return parseSize(text) orelse {
        reporter.err("Error: {s} takes a size greater than zero, as 512MB or 8GB, got '{s}'\n", .{ ENV, text });
        return error.Refused;
    };
}

/// What a run is given from outside its project: the flag's size, else the variable's.
pub fn given(flag: ?usize, environ: *const std.process.Environ.Map, reporter: Reporter) error{Refused}!?usize {
    return flag orelse try fromEnv(environ, reporter);
}

/// The limit a run gets: the one `given` (the flag's, else the variable's), as the command line
/// and the environment win over the project's file; else the project's; else the command's
/// `default` (null: none).
pub fn limitFor(project: ?usize, given_limit: ?usize, default: ?usize) ?usize {
    return given_limit orelse project orelse default;
}
