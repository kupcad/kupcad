const std = @import("std");
const parallel = @import("parallel.zig");

/// Indices of the range the tests run over, and some work per index.
const START = 100;
const END = 1124;
const WORK_PER_INDEX = 5_000;
/// How many times an index waits (yielding) for another thread to run one: long past
/// any scheduler's delay, and bounded, so a loop on one thread fails rather than hangs.
const MAX_WAITS = 10_000_000;

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

test "parallelFor: with oneTBB the work spreads over several threads" {
    // The flag that turned oneTBB on was one only Manifold's sources were compiled with, so
    // the loop ran on the calling thread alone; the test skipped when it did, the very fault
    // it guards. A build with oneTBB must spread.
    try std.testing.expectEqual(@import("build_info").tbb, parallel.spreadsOverThreads());
    if (!parallel.spreadsOverThreads() or (std.Thread.getCpuCount() catch 1) < 2) return error.SkipZigTest;
    // Each index waits until a second thread has run one: on oneTBB's threads the waiting one
    // holds its worker, and another takes the rest of the range, however busy the machine
    const Meeting = struct {
        first: std.atomic.Value(std.Thread.Id) = .init(0),
        met: std.atomic.Value(bool) = .init(false),

        fn visit(_: usize, self: *@This()) void {
            const id = std.Thread.getCurrentId();
            if (self.first.cmpxchgStrong(0, id, .acq_rel, .acquire)) |first| {
                if (first != id) self.met.store(true, .release);
            }
            var waits: usize = 0;
            while (!self.met.load(.acquire) and waits < MAX_WAITS) : (waits += 1) std.Thread.yield() catch {};
        }
    };
    var meeting: Meeting = .{};
    parallel.parallelFor(START, END, Meeting, &meeting, Meeting.visit);
    try std.testing.expect(meeting.met.load(.acquire));
}
