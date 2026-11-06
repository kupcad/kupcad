const std = @import("std");
const Parallel = @import("parallel.zig").Parallel;

/// Indices of the range the tests run over.
const START = 100;
const END = 1124;

/// Each index's runs, and the order they came in.
const Tally = struct {
    runs: [END]u32 = @splat(0),
    order: std.ArrayList(usize) = .empty,
    allocator: std.mem.Allocator,

    fn visit(i: usize, self: *Tally) void {
        self.runs[i] += 1;
        self.order.append(self.allocator, i) catch @panic("out of memory");
    }
};

test "Parallel.serial: every index of the range runs exactly once, in order, on one thread" {
    var tally: Tally = .{ .allocator = std.testing.allocator };
    defer tally.order.deinit(std.testing.allocator);
    Parallel.serial.forRange(START, END, Tally, &tally, Tally.visit);
    for (tally.runs, 0..) |runs, i| {
        errdefer std.debug.print("index {d}\n", .{i});
        try std.testing.expectEqual(@as(u32, if (i >= START) 1 else 0), runs);
    }
    for (tally.order.items, START..) |ran, expected| try std.testing.expectEqual(expected, ran);
    try std.testing.expectEqual(@as(usize, 1), Parallel.serial.threads());
}

test "Parallel: an empty or backwards range runs nothing, before the implementation is asked" {
    const Refusing = struct {
        fn forRange(_: ?*anyopaque, _: usize, _: usize, _: *anyopaque, _: Parallel.Body) void {
            @panic("asked to run an empty range");
        }
        fn threads(_: ?*anyopaque) usize {
            return 7;
        }
        const vtable: Parallel.VTable = .{ .forRange = forRange, .threads = threads };
    };
    const refusing: Parallel = .{ .context = null, .vtable = &Refusing.vtable };
    var tally: Tally = .{ .allocator = std.testing.allocator };
    defer tally.order.deinit(std.testing.allocator);
    refusing.forRange(START, START, Tally, &tally, Tally.visit);
    refusing.forRange(END - 1, START, Tally, &tally, Tally.visit);
    try std.testing.expectEqual(@as(usize, 0), tally.order.items.len);
    try std.testing.expectEqual(@as(usize, 7), refusing.threads());
}
