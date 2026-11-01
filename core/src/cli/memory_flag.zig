//! `--memory-limit <size>`: the most script heap a run may hold (what `vm_memory_limit` in
//! .kupcad.json limits), for a host that runs scripts someone else wrote (the desktop app, the
//! VS Code extension, from their settings). The command line wins over the project's file, as
//! `-p` does over a parameter's default: with the flag the project's `vm_memory_limit` doesn't
//! apply, so a cloned project can't lift the host's limit and a setting raised always takes.
//! Without either a command keeps its own default: none for `build` and `run`, the interactive
//! one for `watch` and `lsp`.

const std = @import("std");
const Reporter = @import("reporter.zig").Reporter;
const Taken = @import("param_flags.zig").Taken;

pub const FLAG = "--memory-limit";

pub const USAGE =
    \\  --memory-limit <size>     Most memory the script may hold, as 512MB or 8GB, in
    \\                            place of the project's vm_memory_limit
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

/// The limit a run gets: the flag's, as the command line wins over the project's file; else
/// the project's; else the command's `default` (null: none).
pub fn limitFor(project: ?usize, flag: ?usize, default: ?usize) ?usize {
    return flag orelse project orelse default;
}
