const std = @import("std");
const testing = std.testing;
const profiler = @import("profiler.zig");

// A simple busy loop to waste time without depending on removed OS sleep APIs
fn wasteTime(iterations: u64) void {
    var x: u64 = 0;
    while (x < iterations) : (x += 1) {
        std.mem.doNotOptimizeAway(x);
    }
}

test "Profiler: Accurately subtracts child time from parent self_time" {
    // Pass testing.io
    var p = profiler.Profiler.init(testing.allocator, testing.io);
    defer p.deinit();

    // 1. Enter Parent
    try p.enterFrame("parent_function");

    // Simulate some work in the parent...
    wasteTime(500_000);

    // 2. Enter Child
    try p.enterFrame("child_function");

    // Simulate heavy child work...
    wasteTime(1_500_000);

    // 3. Exit Child
    try p.exitFrame();

    // Simulate minor wrap-up work in parent...
    wasteTime(200_000);

    // 4. Exit Parent
    try p.exitFrame();

    // Verify stats
    const parent_stats = p.stats.get("parent_function").?;
    const child_stats = p.stats.get("child_function").?;

    // The child should have exactly the time it took for itself.
    // The parent's total time should be parent + child.
    // The parent's self time should be only the parent's work, which is strictly less than its total time.
    try testing.expect(parent_stats.total_time_ns > parent_stats.self_time_ns);
    try testing.expect(child_stats.total_time_ns == child_stats.self_time_ns);
    try testing.expect(parent_stats.self_time_ns > 0);
    try testing.expect(child_stats.self_time_ns > 0);
}
