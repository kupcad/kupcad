//! The executable's logging and console output: `std_options` sets the log level per build
//! mode, `printStderr`, `writeStderr` and `printStdout` print user-facing text, and
//! `Printer` prints a command's results to stdout or into a capture buffer under test.
//! Everything on stderr goes through here, so the CLI's progress line (cli/progress.zig)
//! can take itself off before each print (`StderrHook`).

const std = @import("std");
const builtin = @import("builtin");

/// What else draws on stderr: the CLI's progress line, told around every print while it
/// shows, under the stderr lock of its `io`, so it takes its line off before the print and
/// knows after it whether the cursor is at a line's start, where it may draw again. It
/// registers itself here (`setStderrHook`): this file is below cli/ and can't import it.
pub const StderrHook = struct {
    context: *anyopaque,
    /// The Io whose stderr lock the line draws under. A log message takes the same one while
    /// the line shows: std.log's own is the debug Io's, another lock, which the line's
    /// drawing wouldn't wait for.
    io: std.Io,
    /// Before a print, with the stderr writer: the line takes itself off.
    before: *const fn (context: *anyopaque, stderr: *std.Io.Writer) void,
    /// After it: whether what was printed ended its line.
    after: *const fn (context: *anyopaque, at_line_start: bool) void,
};

/// Read from any thread that prints, set by the thread that starts and stops the line.
var stderr_hook: std.atomic.Value(?*const StderrHook) = .init(null);

/// Registers `hook` (which must live until it is replaced), or with null takes it away.
pub fn setStderrHook(hook: ?*const StderrHook) void {
    stderr_hook.store(hook, .release);
}

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
    const hook = stderr_hook.load(.acquire) orelse return std.log.defaultLog(message_level, scope, format, args);
    var buf: [64]u8 = undefined;
    const locked = hook.io.lockStderr(&buf, null) catch return;
    defer hook.io.unlockStderr();
    const w = &locked.file_writer.interface;
    hook.before(hook.context, w);
    std.log.defaultLogFileTerminal(message_level, scope, format, args, locked.terminal()) catch {};
    w.flush() catch {};
    hook.after(hook.context, true);
}

/// Safely prints UI text, usage menus, and errors to stderr.
/// Automatically handles the std.Io mutex lock and flushes local buffers.
pub fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;

    if (io.lockStderr(&buf, null)) |ls| {
        defer io.unlockStderr();
        // The CLI's messages are whole lines
        printAround(&ls.file_writer.interface, stderr_hook.load(.acquire), true, fmt, args);
    } else |_| {}
}

/// Writes `bytes` to stderr as they are: what a script prints, which may end mid-line (a
/// `print` without a newline), where the progress line then waits for the line's end.
pub fn writeStderr(io: std.Io, bytes: []const u8) void {
    if (bytes.len == 0) return;
    var buf: [4096]u8 = undefined;

    if (io.lockStderr(&buf, null)) |ls| {
        defer io.unlockStderr();
        printAround(&ls.file_writer.interface, stderr_hook.load(.acquire), bytes[bytes.len - 1] == '\n', "{s}", .{bytes});
    } else |_| {}
}

/// Prints to `w` (stderr, locked), telling `hook` before and after; `ends_line` is whether
/// the text ends its line.
pub fn printAround(w: *std.Io.Writer, hook: ?*const StderrHook, ends_line: bool, comptime fmt: []const u8, args: anytype) void {
    if (hook) |h| h.before(h.context, w);
    defer if (hook) |h| h.after(h.context, ends_line);
    w.print(fmt, args) catch return;
    w.flush() catch return;
}

/// Safely prints raw data (like JSON or code) to stdout for piping.
pub fn printStdout(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    // On a terminal stdout and stderr share the screen: the progress line, drawn on stderr,
    // comes off first, or the text would be written after it on its line
    if (stderr_hook.load(.acquire)) |hook| {
        var err_buf: [64]u8 = undefined;
        const locked = hook.io.lockStderr(&err_buf, null) catch return writeStdout(io, fmt, args);
        defer hook.io.unlockStderr();
        hook.before(hook.context, &locked.file_writer.interface);
        defer hook.after(hook.context, true);
        return writeStdout(io, fmt, args);
    }
    writeStdout(io, fmt, args);
}

fn writeStdout(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;

    // A streaming writer, which writes where the stream is: a positional one starts each
    // call at offset 0, so with stdout on a file (`kupcad fmt dir > out.txt`) every print
    // overwrote the one before, and `>>` overwrote the file's start.
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &buf);
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
