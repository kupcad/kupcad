const std = @import("std");
const testing = std.testing;
const bench = @import("bench.zig");

test "bench: medians over repeated runs, with the geometry evaluated as a phase" {
    var report = try bench.run(testing.allocator, testing.io, "x = 0\n50.times { |i| x += i }\ncube(2)\n", .{ .repeat = 3, .profile = false });
    defer report.deinit();
    try testing.expectEqual(@as(usize, 3), report.repeat);
    try testing.expect(report.evaluated);
    try testing.expect(report.median_ns.get(.run) > 0);
    try testing.expect(report.median_ns.get(.evaluate) > 0);
    try testing.expect(report.profile == null);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try report.writeJson(&out.writer);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("repeat").?.integer);
    try testing.expect(parsed.value.object.get("median_ns").?.object.get("evaluate").?.integer > 0);
}

test "bench: a script without geometry has no evaluate phase, and the profile is optional" {
    var report = try bench.run(testing.allocator, testing.io, "x = 1 + 2\n", .{ .repeat = 1, .profile = true });
    defer report.deinit();
    try testing.expect(!report.evaluated);
    try testing.expectEqual(@as(u64, 0), report.median_ns.get(.evaluate));
    try testing.expect(report.profile != null);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try report.writeText(&out.writer, "x.kup");
    try testing.expect(std.mem.indexOf(u8, out.written(), "no geometry to evaluate") != null);
}

test "bench: an empty script is timed without anything to run or evaluate" {
    var report = try bench.run(testing.allocator, testing.io, "", .{ .repeat = 1, .profile = true });
    defer report.deinit();
    try testing.expect(!report.evaluated);
}

test "bench: a script that doesn't parse, compile or run is an error" {
    try testing.expectError(error.ParseError, bench.run(testing.allocator, testing.io, "x = )", .{ .repeat = 1, .profile = false }));
    try testing.expectError(error.CompileError, bench.run(testing.allocator, testing.io, "cube = 5", .{ .repeat = 1, .profile = false }));
    try testing.expectError(error.RuntimeError, bench.run(testing.allocator, testing.io, "undefined_thing(1)", .{ .repeat = 1, .profile = false }));
}
