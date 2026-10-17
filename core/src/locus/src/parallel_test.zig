const std = @import("std");
const parallel = @import("parallel.zig");

/// Indices of the range the tests run over, and work enough per index for oneTBB to hand
/// parts of the range to other threads.
const START = 100;
const END = 1124;
const WORK_PER_INDEX = 5_000;

/// Each index's runs, and the thread that ran it.
const Tally = struct {
    runs: [END]std.atomic.Value(u32) = @splat(.init(0)),
    ran_on: [END]std.atomic.Value(std.Thread.Id) = @splat(.init(0)),

    fn visit(i: usize, self: *Tally) void {
        var h: u64 = i;
        for (0..WORK_PER_INDEX) |_| h = std.hash.int(h);
        std.mem.doNotOptimizeAway(h);
        _ = self.runs[i].fetchAdd(1, .monotonic);
        self.ran_on[i].store(std.Thread.getCurrentId(), .monotonic);
    }

    /// Whether more than one thread ran the indices from START.
    fn severalThreads(self: *const Tally) bool {
        const first = self.ran_on[START].load(.monotonic);
        for (self.ran_on[START..]) |id| {
            if (id.load(.monotonic) != first) return true;
        }
        return false;
    }
};

test "parallelFor: every index of the range runs exactly once, and none outside it" {
    var tally: Tally = .{};
    parallel.parallelFor(START, END, Tally, &tally, Tally.visit);
    for (tally.runs, 0..) |runs, i| {
        errdefer std.debug.print("index {d}\n", .{i});
        try std.testing.expectEqual(@as(u32, if (i >= START) 1 else 0), runs.load(.monotonic));
    }
}

test "parallelFor: an empty or backwards range runs nothing" {
    var tally: Tally = .{};
    parallel.parallelFor(START, START, Tally, &tally, Tally.visit);
    parallel.parallelFor(END - 1, START, Tally, &tally, Tally.visit);
    for (tally.runs) |runs| try std.testing.expectEqual(@as(u32, 0), runs.load(.monotonic));
}

test "parallelFor: with oneTBB the work spreads over several threads" {
    // The flag that turned oneTBB on was one only Manifold's sources were compiled with, so
    // the loop ran on the calling thread alone.
    if (!parallel.spreadsOverThreads() or (std.Thread.getCpuCount() catch 1) < 2) return error.SkipZigTest;
    var tally: Tally = .{};
    parallel.parallelFor(START, END, Tally, &tally, Tally.visit);
    try std.testing.expect(tally.severalThreads());
}
