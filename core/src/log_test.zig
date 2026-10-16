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

test "Log: a test can quiet the warnings it expects, but not errors" {
    // The test runner prints every warning at its default level; expectWarnings lowers it
    // to errors for the rest of this test only (the runner resets it before each test).
    try testing.expectEqual(std.log.Level.warn, std.testing.log_level);
    @import("test_support.zig").expectWarnings();
    try testing.expectEqual(std.log.Level.err, std.testing.log_level);
}
