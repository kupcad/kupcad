//! The executable's logging and console output: `std_options` sets the log level per build
//! mode, `printStderr` and `printStdout` print user-facing text, and `Printer` prints a
//! command's results to stdout or into a capture buffer under test.

const std = @import("std");
const builtin = @import("builtin");

pub const std_options = std.Options{
    .log_level = levelFor(builtin.mode),
    .logFn = logFn,
};

/// Debug builds log everything. Release builds show warnings and errors (e.g. an
/// unsupported lockfile, a skipped package entry) but not the per-run `info` chatter
/// such as "Initialized new session", which would otherwise print on every build.
pub fn levelFor(mode: std.lang.Optimize) std.log.Level {
    return switch (mode) {
        .debug => .debug,
        .safe, .fast, .small => .warn,
    };
}

/// The executable's log output. Test binaries never use it: their root is Zig's test
/// runner, which logs by `std.testing.log_level` (see test_support.expectWarnings).
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(message_level, scope, format, args);
}

/// Safely prints UI text, usage menus, and errors to stderr.
/// Automatically handles the std.Io mutex lock and flushes local buffers.
pub fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;

    if (io.lockStderr(&buf, null)) |ls| {
        defer io.unlockStderr();

        ls.file_writer.interface.print(fmt, args) catch return;
        ls.file_writer.interface.flush() catch return;
    } else |_| {}
}

/// Safely prints raw data (like JSON or code) to stdout for piping.
pub fn printStdout(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;

    // Initialize standard out writer using the required local buffer
    var stdout_w = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_w.interface;

    stdout.print(fmt, args) catch return;
    stdout.flush() catch return;
}

/// Prints a command's results to stdout, or into `capture` under test. Results printed
/// with `log.info` disappeared from release builds, which hide info logging: the shipped
/// `kupcad pkg doctor` printed nothing on success.
pub const Printer = struct {
    io: std.Io,
    capture: ?*std.Io.Writer = null,

    pub fn print(self: Printer, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |w| w.print(fmt, args) catch {} else printStdout(self.io, fmt, args);
    }
};
