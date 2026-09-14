const std = @import("std");
const builtin = @import("builtin");

pub const std_options = std.Options{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .info,
        .ReleaseFast, .ReleaseSmall => .err,
    },
    .logFn = logFn,
};

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Silence ALL log output (including .err) during unit test runs
    if (builtin.is_test) return;

    std.log.defaultLog(message_level, scope, format, args);
}
