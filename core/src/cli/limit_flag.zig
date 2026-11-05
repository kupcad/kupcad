//! A flag a command takes a limit by, and the environment variable read in its place: how
//! `--memory-limit` (memory_flag.zig) and `--timeout` (time_flag.zig) are read, each with its
//! own units (`parseWithUnits`). The flag wins over the variable, which a shell or a CI job
//! sets for every run; an empty variable counts as unset; a value that isn't one is reported
//! and refused, the flag's and the variable's alike.

const std = @import("std");
const Reporter = @import("reporter.zig").Reporter;
const Taken = @import("param_flags.zig").Taken;

/// A unit a limit may be written in: its suffix (any case), and how many of the limit's own
/// units (bytes, milliseconds) one is.
pub fn Unit(comptime T: type) type {
    return struct { suffix: []const u8, size: T };
}

/// The amount `text` says: a whole number greater than zero followed by one of `units` (the
/// first whose suffix it ends with, so `ms` goes before `s`), or a number alone, in
/// `default_unit`; null for anything else, or an amount past what a `T` counts. The memory
/// and the time limits each parsed theirs with a copy of this.
pub fn parseWithUnits(comptime T: type, units: []const Unit(T), default_unit: T, text: []const u8) ?T {
    var number = text;
    var unit = default_unit;
    for (units) |u| {
        if (text.len > u.suffix.len and std.ascii.endsWithIgnoreCase(text, u.suffix)) {
            number = text[0 .. text.len - u.suffix.len];
            unit = u.size;
            break;
        }
    }
    for (number) |c| if (!std.ascii.isDigit(c)) return null;
    const count = std.fmt.parseInt(T, number, 10) catch return null;
    if (count == 0) return null;
    return std.math.mul(T, count, unit) catch null;
}

/// The flag `flag` and the variable `env`, each a `T` as `parse` reads one: null for text that
/// isn't, which is refused saying the flag or the variable takes `expected`.
pub fn LimitFlag(comptime T: type, comptime flag: []const u8, comptime env: []const u8, comptime expected: []const u8, comptime parse: fn ([]const u8) ?T) type {
    return struct {
        pub const FLAG = flag;
        /// The variable read when the flag isn't given.
        pub const ENV = env;
        /// What a value is, as a refusal says it.
        pub const EXPECTED = expected;

        /// Takes `<flag> <value>` into `limit` when `arg` is the flag, reporting a value that
        /// isn't one.
        pub fn take(arg: []const u8, args: anytype, limit: *?T, reporter: Reporter) Taken {
            if (!std.mem.eql(u8, arg, FLAG)) return .other;
            const text = args.next() orelse "";
            limit.* = parse(text) orelse {
                reporter.err("Error: {s} takes {s}, got '{s}'\n", .{ FLAG, expected, text });
                return .refused;
            };
            return .taken;
        }

        /// The variable's value, null when it is unset or empty.
        pub fn fromEnv(environ: *const std.process.Environ.Map, reporter: Reporter) error{Refused}!?T {
            const text = environ.get(ENV) orelse return null;
            if (text.len == 0) return null;
            return parse(text) orelse {
                reporter.err("Error: {s} takes {s}, got '{s}'\n", .{ ENV, expected, text });
                return error.Refused;
            };
        }

        /// What a run is given: the flag's value, else the variable's.
        pub fn given(flag_value: ?T, environ: *const std.process.Environ.Map, reporter: Reporter) error{Refused}!?T {
            return flag_value orelse try fromEnv(environ, reporter);
        }
    };
}
