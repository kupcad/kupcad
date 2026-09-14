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

/// Safely prints UI text, usage menus, and errors to stderr.
/// Automatically handles the std.Io mutex lock and flushes local buffers.
pub fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;

    if (io.lockStderr(&buf, null)) |ls| {
        defer io.unlockStderr();

        ls.file_writer.interface.print(fmt, args) catch {};
        ls.file_writer.interface.flush() catch {};
    } else |_| {}
}

/// Safely prints raw data (like JSON or code) to stdout for piping.
pub fn printStdout(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;

    // Initialize standard out writer using the required local buffer
    var stdout_w = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_w.interface;

    stdout.print(fmt, args) catch {};
    stdout.flush() catch {};
}
