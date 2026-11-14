//! Locus's benchmark gate in CI (docs/architecture.md §12; Leo, 2026-11-14): the
//! benchmark (src/locus/test/bench/main.zig) built at the commit before a push and at the
//! pushed one, run on one runner, alternately, `RUNS` times each; a case whose median time
//! a repetition is more than `MARGIN` times its median before fails. The budgets in the
//! benchmark are a laptop's, which say nothing of a shared runner's speed: the commit
//! before is the budget on the runner's own hardware, and alternating the two puts the
//! runner's moods on both. A case the commit before lacks is reported, not judged.
//!
//! The benchmark reports each case as a line, `<name> <ms> ms  budget <ms> ms`, and exits
//! 1 when a case is past its laptop budget, which is no failure here; a run that crashed,
//! or printed no case, is.
//!
//! Arguments: the benchmark before, the benchmark after, and the run count. Run it as
//! `zig run core/scripts/bench_compare.zig -- BEFORE AFTER RUNS`.

const std = @import("std");

/// How much slower than before a case may run (§12: a regression of more than 20% fails).
const MARGIN: f64 = 1.2;
/// What follows a case's time on its line.
const AFTER_TIME = " ms  budget ";
/// Bytes read from a run at a time.
const CHUNK = 64 * 1024;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        try std.Io.File.stderr().writeStreamingAll(io, "usage: bench_compare BEFORE AFTER RUNS\n");
        std.process.exit(2);
    }
    const runs = try std.fmt.parseInt(usize, args[3], 10);
    var before: Samples = .{};
    var after: Samples = .{};
    for (0..runs) |_| {
        try before.add(arena, try runBench(io, arena, args[1]));
        try after.add(arena, try runBench(io, arena, args[2]));
    }
    const rows = try compare(arena, &before, &after);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s:<48} {s:>10} {s:>10} {s:>7}  (medians of {d} runs each, ms a repetition)\n", .{ "case", "before", "after", "ratio", runs });
    var regressed = false;
    for (rows) |row| {
        if (row.before) |b| {
            try out.print(arena, "{s:<48} {d:>10.2} {d:>10.2} {d:>7.2}{s}\n", .{ row.name, b, row.after, row.after / b, if (row.regressed) "  REGRESSION" else "" });
        } else {
            try out.print(arena, "{s:<48} {s:>10} {d:>10.2}     new\n", .{ row.name, "-", row.after });
        }
        regressed = regressed or row.regressed;
    }
    try std.Io.File.stdout().writeStreamingAll(io, out.items);
    if (regressed) {
        try std.Io.File.stderr().writeStreamingAll(io, "bench_compare: a case runs more than 20% slower than at the commit before\n");
        std.process.exit(1);
    }
}

/// Each case's times, by name, in the order the benchmark first printed them.
const Samples = struct {
    by_name: std.StringArrayHashMapUnmanaged(std.ArrayList(f64)) = .empty,

    fn add(self: *Samples, allocator: std.mem.Allocator, report: []const u8) !void {
        var cases: usize = 0;
        var lines = std.mem.splitScalar(u8, report, '\n');
        while (lines.next()) |line| {
            const case = parseLine(line) orelse continue;
            const entry = try self.by_name.getOrPut(allocator, case.name);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(allocator, case.ms);
            cases += 1;
        }
        if (cases == 0) return error.NoCases;
    }
};

const Case = struct { name: []const u8, ms: f64 };

/// A case's line of the benchmark's report, or null for any other line.
fn parseLine(line: []const u8) ?Case {
    const at = std.mem.indexOf(u8, line, AFTER_TIME) orelse return null;
    const head = std.mem.trimEnd(u8, line[0..at], " ");
    const space = std.mem.lastIndexOfScalar(u8, head, ' ') orelse return null;
    const ms = std.fmt.parseFloat(f64, head[space + 1 ..]) catch return null;
    const name = std.mem.trimEnd(u8, head[0..space], " ");
    if (name.len == 0) return null;
    return .{ .name = name, .ms = ms };
}

/// The median of `samples`, which it sorts.
fn median(samples: []f64) f64 {
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    const mid = samples.len / 2;
    return if (samples.len % 2 == 1) samples[mid] else (samples[mid - 1] + samples[mid]) / 2;
}

const Row = struct { name: []const u8, before: ?f64, after: f64, regressed: bool };

/// Each case after, its median against its median before (null for a case new since).
fn compare(allocator: std.mem.Allocator, before: *Samples, after: *Samples) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    var it = after.by_name.iterator();
    while (it.next()) |entry| {
        const now = median(entry.value_ptr.items);
        const was: ?f64 = if (before.by_name.getPtr(entry.key_ptr.*)) |list| median(list.items) else null;
        try rows.append(allocator, .{ .name = entry.key_ptr.*, .before = was, .after = now, .regressed = if (was) |w| now > w * MARGIN else false });
    }
    return rows.toOwnedSlice(allocator);
}

/// The benchmark at `path` run once: what it reported. Its exit 1 for a case past its
/// laptop budget is no failure here; a crash is.
fn runBench(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var child = try std.process.spawn(io, .{ .argv = &.{path}, .stdout = .ignore, .stderr = .pipe });
    var report: std.ArrayList(u8) = .empty;
    const chunk = try allocator.alloc(u8, CHUNK);
    while (true) {
        const n = child.stderr.?.readStreaming(io, &.{chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try report.appendSlice(allocator, chunk[0..n]);
    }
    switch (try child.wait(io)) {
        .exited => |code| if (code > 1) return error.BenchmarkFailed,
        else => {
            try std.Io.File.stderr().writeStreamingAll(io, report.items);
            return error.BenchmarkCrashed;
        },
    }
    return report.toOwnedSlice(allocator);
}

test "bench_compare: a case's line is its name and its time a repetition, other lines are none" {
    const case = parseLine("BVH: 10,000 boxes built and 10,000 queries            3.38 ms  budget     5.0 ms").?;
    try std.testing.expectEqualStrings("BVH: 10,000 boxes built and 10,000 queries", case.name);
    try std.testing.expectEqual(@as(f64, 3.38), case.ms);
    const flagged = parseLine("union of two 1000-sided prisms                      870.10 ms  budget   400.0 ms  REGRESSION").?;
    try std.testing.expectEqual(@as(f64, 870.1), flagged.ms);
    try std.testing.expectEqual(@as(?Case, null), parseLine("error: BenchmarkRegression"));
    try std.testing.expectEqual(@as(?Case, null), parseLine(""));
}

test "bench_compare: a case more than 20% slower than before is a regression, a new case is not judged" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var before: Samples = .{};
    var after: Samples = .{};
    // Medians: the prisms 370 before, 870 after; the box 35 and 38 (within the margin)
    for ([_][]const u8{ "union of two 1000-sided prisms   370.0 ms  budget 400.0 ms\nbox ×1000   35.0 ms  budget 40.0 ms\n", "union of two 1000-sided prisms   380.0 ms  budget 400.0 ms\nbox ×1000   36.0 ms  budget 40.0 ms\n", "union of two 1000-sided prisms   360.0 ms  budget 400.0 ms\nbox ×1000   34.0 ms  budget 40.0 ms\n" }) |report| try before.add(a, report);
    for ([_][]const u8{ "union of two 1000-sided prisms   870.0 ms  budget 400.0 ms\nbox ×1000   38.0 ms  budget 40.0 ms\nnew case   1.0 ms  budget 2.0 ms\n", "union of two 1000-sided prisms   860.0 ms  budget 400.0 ms\nbox ×1000   39.0 ms  budget 40.0 ms\nnew case   1.0 ms  budget 2.0 ms\n", "union of two 1000-sided prisms   880.0 ms  budget 400.0 ms\nbox ×1000   37.0 ms  budget 40.0 ms\nnew case   1.0 ms  budget 2.0 ms\n" }) |report| try after.add(a, report);
    const rows = try compare(a, &before, &after);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("union of two 1000-sided prisms", rows[0].name);
    try std.testing.expect(rows[0].regressed);
    try std.testing.expectEqual(@as(?f64, 370), rows[0].before);
    try std.testing.expect(!rows[1].regressed);
    try std.testing.expectEqual(@as(?f64, null), rows[2].before);
    try std.testing.expect(!rows[2].regressed);
    try std.testing.expectError(error.NoCases, before.add(a, "error: BenchmarkRegression\n"));
}

test "bench_compare: the median of an odd count is its middle, of an even count the mean of the two" {
    var odd = [_]f64{ 3, 1, 2 };
    try std.testing.expectEqual(@as(f64, 2), median(&odd));
    var even = [_]f64{ 4, 1, 3, 2 };
    try std.testing.expectEqual(@as(f64, 2.5), median(&even));
}
