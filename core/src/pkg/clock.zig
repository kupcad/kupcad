//! Time as the package store records it: whole seconds since the Unix epoch, rounded down
//! (the store and the pruner used to round one way each, and a time just before the epoch
//! second came out differently in each).

const std = @import("std");

/// `ts` in whole seconds since the epoch.
pub fn unixSeconds(ts: std.Io.Timestamp) i64 {
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
}

/// The real-time clock now, in whole seconds since the epoch.
pub fn nowSeconds(io: std.Io) i64 {
    return unixSeconds(std.Io.Clock.real.now(io));
}
