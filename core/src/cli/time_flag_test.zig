const std = @import("std");
const testing = std.testing;
const time_flag = @import("time_flag.zig");
const Reporter = @import("reporter.zig").Reporter;

test "time_flag: a time is a whole number with a unit, in any case, or seconds alone" {
    try testing.expectEqual(@as(?u64, 500), time_flag.parseTime("500ms"));
    try testing.expectEqual(@as(?u64, 500), time_flag.parseTime("500MS"));
    try testing.expectEqual(@as(?u64, 30_000), time_flag.parseTime("30s"));
    try testing.expectEqual(@as(?u64, 120_000), time_flag.parseTime("2m"));
    try testing.expectEqual(@as(?u64, 3_600_000), time_flag.parseTime("1H"));
    try testing.expectEqual(@as(?u64, 45_000), time_flag.parseTime("45"));
}

test "time_flag: zero, a fraction, a sign, another unit, a unit alone or an overflow is no time" {
    for ([_][]const u8{ "", "0", "0ms", "1.5s", "-1s", "+1s", "1 s", "1d", "1sec", "ms", "s", "99999999999999999999", "18446744073709551615h" }) |text| {
        errdefer std.debug.print("'{s}'\n", .{text});
        try testing.expectEqual(@as(?u64, null), time_flag.parseTime(text));
    }
}

test "time_flag: KUPCAD_TIMEOUT is read as the flag is, when the flag isn't given" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const reporter: Reporter = .{ .io = testing.io, .capture = &output.writer };
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expectEqual(@as(?u64, null), try time_flag.given(null, &environ, reporter));
    try environ.put(time_flag.ENV, "2m");
    try testing.expectEqual(@as(?u64, 120_000), try time_flag.given(null, &environ, reporter));
    try testing.expectEqual(@as(?u64, 5), try time_flag.given(5, &environ, reporter));
    try environ.put(time_flag.ENV, "");
    try testing.expectEqual(@as(?u64, null), try time_flag.given(null, &environ, reporter));
    try environ.put(time_flag.ENV, "soon");
    try testing.expectError(error.Refused, time_flag.given(null, &environ, reporter));
    try testing.expectEqualStrings("Error: KUPCAD_TIMEOUT takes a time greater than zero, as 500ms, 30s or 2m, got 'soon'\n", output.written());
    // The flag given, the variable isn't read at all
    try testing.expectEqual(@as(?u64, 5), try time_flag.given(5, &environ, reporter));
}
