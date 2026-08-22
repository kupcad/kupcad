const std = @import("std");

pub const ProfileStats = struct {
    name: []const u8,
    call_count: usize,
    total_time_ns: u64,
    self_time_ns: u64,
};

pub const FrameTimer = struct {
    name: []const u8,
    start_time: std.Io.Timestamp, // monotonic timestamp
    child_time: u64,
};

pub const Profiler = struct {
    allocator: std.mem.Allocator,
    io: std.Io, // Required for Clock reading
    stats: std.StringHashMapUnmanaged(ProfileStats),
    timer_stack: std.ArrayListUnmanaged(FrameTimer),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Profiler {
        return .{
            .allocator = allocator,
            .io = io,
            .stats = .empty,
            .timer_stack = .empty,
        };
    }

    pub fn deinit(self: *Profiler) void {
        self.stats.deinit(self.allocator);
        self.timer_stack.deinit(self.allocator);
    }

    /// Called instantly before a function executes
    pub fn enterFrame(self: *Profiler, name: []const u8) !void {
        // Use the new I/O monotonic awake clock
        const start = std.Io.Clock.now(.awake, self.io);
        try self.timer_stack.append(self.allocator, .{
            .name = name,
            .start_time = start,
            .child_time = 0,
        });
    }

    /// Called instantly after a function returns
    pub fn exitFrame(self: *Profiler) !void {
        const end = std.Io.Clock.now(.awake, self.io);

        if (self.timer_stack.items.len == 0) return;

        // Fail-proof manual pop that works across all Zig versions
        const last_idx = self.timer_stack.items.len - 1;
        const frame = self.timer_stack.items[last_idx];
        self.timer_stack.shrinkRetainingCapacity(last_idx);

        // Calculate raw elapsed time safely in u64
        const duration = frame.start_time.durationTo(end);
        const elapsed = @as(u64, @intCast(duration.toNanoseconds()));

        // Self time is the total time MINUS any time spent waiting for children
        const self_time = elapsed - frame.child_time;

        // If this frame had a parent, add our elapsed time to its child_time tally
        if (self.timer_stack.items.len > 0) {
            self.timer_stack.items[self.timer_stack.items.len - 1].child_time += elapsed;
        }

        // Upsert the stats into the hash map
        const gop = try self.stats.getOrPut(self.allocator, frame.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .name = frame.name,
                .call_count = 0,
                .total_time_ns = 0,
                .self_time_ns = 0,
            };
        }
        gop.value_ptr.call_count += 1;
        gop.value_ptr.total_time_ns += elapsed;
        gop.value_ptr.self_time_ns += self_time;
    }

    /// Dumps the aggregated profile sorted by Self Time (Descending)
    pub fn dumpProfile(self: *Profiler, writer: anytype) !void {
        var entries = std.ArrayList(ProfileStats).init(self.allocator);
        defer entries.deinit();

        var it = self.stats.iterator();
        while (it.next()) |entry| {
            try entries.append(entry.value_ptr.*);
        }

        // Sort dynamically
        const sortFn = struct {
            fn lessThan(_: void, a: ProfileStats, b: ProfileStats) bool {
                return a.self_time_ns > b.self_time_ns;
            }
        }.lessThan;

        std.sort.block(ProfileStats, entries.items, {}, sortFn);

        // Format CLI Table
        try writer.writeAll("\n=== Tracing Profile ===\n");
        try writer.print("{[name]-30} | {[calls]-10} | {[total]-15} | {[self]-15}\n", .{
            .name = "Function",
            .calls = "Calls",
            .total = "Total (ms)",
            .self = "Self (ms)",
        });
        try writer.writeAll("-" ** 79 ++ "\n");

        for (entries.items) |stat| {
            const total_ms = @as(f64, @floatFromInt(stat.total_time_ns)) / 1_000_000.0;
            const self_ms = @as(f64, @floatFromInt(stat.self_time_ns)) / 1_000_000.0;

            try writer.print("{[name]-30} | {[calls]-10} | {[total]-15.3} | {[self]-15.3}\n", .{
                .name = stat.name,
                .calls = stat.call_count,
                .total = total_ms,
                .self = self_ms,
            });
        }
        try writer.writeAll("=======================\n");
    }
};
