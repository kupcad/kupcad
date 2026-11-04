//! A flag a command takes a limit by, and the environment variable read in its place: how
//! `--memory-limit` (memory_flag.zig) and `--timeout` (time_flag.zig) are read, each with its
//! own words for a value. The flag wins over the variable, which a shell or a CI job sets for
//! every run; an empty variable counts as unset; a value that isn't one is reported and
//! refused, the flag's and the variable's alike.

const std = @import("std");
const Reporter = @import("reporter.zig").Reporter;
const Taken = @import("param_flags.zig").Taken;

/// The flag `flag` and the variable `env`, each a `T` as `parse` reads one: null for text that
/// isn't, which is refused saying the flag or the variable takes `expected`.
pub fn LimitFlag(comptime T: type, comptime flag: []const u8, comptime env: []const u8, comptime expected: []const u8, comptime parse: fn ([]const u8) ?T) type {
    return struct {
        pub const FLAG = flag;
        /// The variable read when the flag isn't given.
        pub const ENV = env;

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
