//! Helpers shared by tests across the codebase.

const std = @import("std");

/// Call first in a test that drives a failure path whose warning is the expected outcome
/// (a rejected lockfile, a refused connection). The test runner prints every warning a
/// test logs, so these expected ones buried real problems and made `zig build test` print
/// a "failed command" line though every test passed. The runner restores the level before
/// each test; errors are still counted and still fail the test.
pub fn expectWarnings() void {
    std.testing.log_level = .err;
}
