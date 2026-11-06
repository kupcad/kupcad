const std = @import("std");
const parallel = @import("parallel.zig");

/// Indices of the range the tests run over, and some work per index.
const START = 100;
const END = 1124;
const WORK_PER_INDEX = 5_000;

/// Each index's runs.
const Tally = struct {
    runs: [END]std.atomic.Value(u32) = @splat(.init(0)),

    fn visit(i: usize, self: *Tally) void {
        var h: u64 = i;
        for (0..WORK_PER_INDEX) |_| h = std.hash.int(h);
        std.mem.doNotOptimizeAway(h);
        _ = self.runs[i].fetchAdd(1, .monotonic);
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
