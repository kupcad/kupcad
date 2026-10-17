//! Opt-in crash reports. With `KUPCAD_CRASH_DIR` naming a directory, a panic or a fatal
//! signal (an abort in the C++ kernel among them, which no Zig code sees) writes
//! `kupcad-crash-<seconds>-<pid>.txt` there before the process ends as it would anyway: the
//! version, the platform and build mode, the subcommand, what happened, and for a panic
//! the stack. Nothing of the script goes in: not its text, its path or its other
//! arguments. Without the variable nothing is written. POSIX only.
//!
//! The process may be crashing for want of memory, so a report is written with fixed
//! buffers and libc's open/write, which a signal handler may call.

const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");

pub const DIR_ENV = "KUPCAD_CRASH_DIR";
/// Longest directory kept (the report's path is built in a fixed buffer).
const MAX_DIR_BYTES = 768;
/// Room for a report's path: the directory and the file name.
const MAX_PATH_BYTES = MAX_DIR_BYTES + 64;
/// Longest subcommand kept.
const MAX_COMMAND_BYTES = 32;
/// Room for a report's header lines.
const MAX_HEADER_BYTES = 2048;
const STDERR: std.c.fd_t = 2;
const FATAL_SIGNALS = [_]std.posix.SIG{ .SEGV, .BUS, .ILL, .FPE, .ABRT };
pub const supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

var dir_storage: [MAX_DIR_BYTES]u8 = undefined;
var dir: []const u8 = "";
var command_storage: [MAX_COMMAND_BYTES]u8 = undefined;
var command: []const u8 = "";
var previous: [FATAL_SIGNALS.len]std.posix.Sigaction = undefined;
/// One report per process: a crash while writing one doesn't start another.
var reporting = std.atomic.Value(bool).init(false);

/// What ended the process.
pub const Cause = union(enum) {
    panic: []const u8,
    /// The faulting address is null for a signal that has none (an abort).
    signal: struct { name: []const u8, address: ?usize },
};

/// Turns reports on when DIR_ENV names a directory. `command_name` is the subcommand,
/// the one part of the command line a report keeps.
pub fn enable(environ: *const std.process.Environ.Map, command_name: []const u8) void {
    if (!supported) return;
    const path = environ.get(DIR_ENV) orelse return;
    if (path.len == 0 or path.len > dir_storage.len) return;
    @memcpy(dir_storage[0..path.len], path);
    dir = dir_storage[0..path.len];
    const len = @min(command_name.len, command_storage.len);
    @memcpy(command_storage[0..len], command_name[0..len]);
    command = command_storage[0..len];
    for (FATAL_SIGNALS, &previous) |sig, *old| {
        const act: std.posix.Sigaction = .{
            .handler = .{ .sigaction = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK,
        };
        std.posix.sigaction(sig, &act, old);
    }
}

/// The executable's panic handler (main.zig): the report, then Zig's own handler.
pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (supported and dir.len > 0 and !reporting.swap(true, .acq_rel)) {
        if (openReport()) |fd| {
            defer _ = std.c.close(fd);
            writeHeader(fd, .{ .panic = msg });
            writeStack(fd, first_trace_addr orelse @returnAddress());
        }
    }
    std.debug.defaultPanic(msg, first_trace_addr orelse @returnAddress());
}

fn handleSignal(sig: std.posix.SIG, info: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    if (!reporting.swap(true, .acq_rel)) {
        if (openReport()) |fd| {
            writeHeader(fd, .{ .signal = .{ .name = @tagName(sig), .address = if (sig == .ABRT) null else faultAddress(info) } });
            _ = std.c.close(fd);
        }
    }
    // Hand the signal on: put back what was there (Zig's segfault handler, which prints the
    // stack, or the default) and return. A fault happens again at once and an abort raises
    // again, so the process ends as it would have without the report.
    for (FATAL_SIGNALS, previous) |s, old| {
        if (s == sig) std.posix.sigaction(sig, &old, null);
    }
}

fn faultAddress(info: *const std.posix.siginfo_t) usize {
    return switch (builtin.os.tag) {
        .macos, .freebsd, .dragonfly => @intFromPtr(info.addr),
        .linux => @intFromPtr(info.fields.sigfault.addr),
        else => 0,
    };
}

/// A new report file in the crash directory, or null if it can't be made.
fn openReport() ?std.c.fd_t {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) ts.sec = 0;
    var path_buf: [MAX_PATH_BYTES:0]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/kupcad-crash-{d}-{d}.txt", .{ dir, ts.sec, std.c.getpid() }, 0) catch return null;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
    if (fd < 0) return null;
    // Said first, so it shows even if writing the report fails partway.
    var note_buf: [MAX_PATH_BYTES + 64]u8 = undefined;
    writeAll(STDERR, std.fmt.bufPrint(&note_buf, "kupcad: writing a crash report to {s}\n", .{path}) catch "kupcad: writing a crash report\n");
    return fd;
}

fn writeHeader(fd: std.c.fd_t, cause: Cause) void {
    var buf: [MAX_HEADER_BYTES]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    formatHeader(&w, cause, command) catch {};
    writeAll(fd, w.buffered());
}

/// The report's opening lines, for `command` (a subcommand) ended by `cause`.
pub fn formatHeader(w: *std.Io.Writer, cause: Cause, command_name: []const u8) std.Io.Writer.Error!void {
    try w.print("KupCAD crash report\nversion: {s}\nplatform: {t}-{t}, {t} build\ncommand: {s}\n", .{
        build_info.version, builtin.os.tag, builtin.cpu.arch, builtin.mode, if (command_name.len > 0) command_name else "(none)",
    });
    switch (cause) {
        .panic => |msg| try w.print("panic: {s}\n", .{msg}),
        .signal => |s| if (s.address) |address|
            try w.print("signal: SIG{s} at address 0x{x}\n", .{ s.name, address })
        else
            try w.print("signal: SIG{s}\n", .{s.name}),
    }
}

fn writeStack(fd: std.c.fd_t, first_address: usize) void {
    writeAll(fd, "stack:\n");
    const io = std.Options.debug_io;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var buf: [1024]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    std.debug.writeCurrentStackTrace(.{ .first_address = first_address }, .{ .writer = &fw.interface, .mode = .no_color }) catch {};
    fw.interface.flush() catch {};
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}
