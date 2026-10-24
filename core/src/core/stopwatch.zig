//! Elapsed time on the monotonic clock, lap by lap: the benchmark's phases
//! (tools/bench.zig) and a preview's run and render (preview/build.zig).

const std = @import("std");

const NS_PER_MS = 1_000_000.0;

pub const Stopwatch = struct {
    io: std.Io,
    last: std.Io.Timestamp,

    pub fn start(io: std.Io) Stopwatch {
        return .{ .io = io, .last = std.Io.Clock.now(.awake, io) };
    }

    /// Nanoseconds since the start or the previous lap.
    pub fn lap(self: *Stopwatch) u64 {
        const now = std.Io.Clock.now(.awake, self.io);
        defer self.last = now;
        return @intCast(@max(self.last.durationTo(now).toNanoseconds(), 0));
    }
};

pub fn milliseconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / NS_PER_MS;
}
