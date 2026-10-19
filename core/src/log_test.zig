const std = @import("std");
const testing = std.testing;
const log = @import("log.zig");

test "Log: release builds show warnings but not per-run info lines" {
    // ReleaseSafe used to log at .info, so every `kupcad build` printed
    // "info(session_manager): Initialized new session ...".
    try testing.expectEqual(std.log.Level.debug, log.levelFor(.debug));
    for ([_]std.lang.Optimize{ .safe, .fast, .small }) |mode| {
        try testing.expectEqual(std.log.Level.warn, log.levelFor(mode));
    }
}

test "Log: a test can quiet the warnings it expects, but not errors, and only its own" {
    // The test runner prints every warning at its default level; expectWarnings lowers it
    // to errors until the test restores it. The runner's server mode, which `zig build test`
    // uses, doesn't reset it between tests, so the level a test finds is what the tests
    // before it left: the default only if each restored it.
    try testing.expectEqual(std.log.Level.warn, std.testing.log_level);
    const warnings = @import("test_support.zig").expectWarnings();
    try testing.expectEqual(std.log.Level.err, std.testing.log_level);
    warnings.restore();
    try testing.expectEqual(std.log.Level.warn, std.testing.log_level);
}
