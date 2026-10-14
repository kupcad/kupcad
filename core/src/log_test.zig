const std = @import("std");
const testing = std.testing;
const log = @import("log.zig");

test "Log: release builds show warnings but not per-run info lines" {
    // ReleaseSafe used to log at .info, so every `kupcad build` printed
    // "info(session_manager): Initialized new session ...".
    try testing.expectEqual(std.log.Level.debug, log.levelFor(.debug));
    for ([_]std.builtin.OptimizeMode{ .safe, .fast, .small }) |mode| {
        try testing.expectEqual(std.log.Level.warn, log.levelFor(mode));
    }
}
