//! The progress line a command shows on stderr while it works: a spinner with the stage and
//! the time so far when how long is unknown (`⠹ Building part.kup · evaluating geometry
//! 1.8s`), a bar when the work is measured (`[=========>          ] 46% Checking 23/49
//! files`). Only on an interactive terminal (`detect`): never in a pipe or a file, in CI,
//! on a dumb terminal, for a host reading `--errors json`, or with KUPCAD_NO_PROGRESS set.
//!
//! One line at a time, as there is one terminal: `start` shows it, `stage` and `amount`
//! say what the command is at, `core` hands the work below the CLI (the evaluator, the
//! session, the package manager) a core `Progress` to tell its own steps through, and
//! `stop` takes it off. It shows nothing for the first INITIAL_DELAY, so a fast command
//! stays silent, then a task of its own draws it every REDRAW_INTERVAL. Every other print
//! on stderr or stdout takes it off first (log.zig's StderrHook), and it is drawn again on
//! the next frame. The text of a frame is `render`'s, a pure function the tests read.

const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");
const core_progress = @import("../core/progress.zig");
const Amount = core_progress.Progress.Amount;
const Reporter = @import("reporter.zig").Reporter;

/// How long the work runs before the line shows: a command that ends sooner prints nothing.
pub const INITIAL_DELAY: std.Io.Duration = .fromMilliseconds(200);
/// How often the line is drawn again, the spinner's frame rate.
pub const REDRAW_INTERVAL: std.Io.Duration = .fromMilliseconds(80);
/// A frame's time, a turn of the spinner.
const FRAME_NS: u64 = @intCast(REDRAW_INTERVAL.nanoseconds);
/// Turns the line off, set and non-empty (as NO_COLOR turns colours off), for a person who
/// doesn't want it on their terminal.
pub const NO_PROGRESS_ENV = "KUPCAD_NO_PROGRESS";
/// Takes the line off: back to its start, and the line erased.
pub const CLEAR = "\r\x1b[2K";
/// The spinner's frames, a turn of braille dots, and the ASCII ones where the terminal
/// can't show braille.
const UNICODE_FRAMES = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const ASCII_FRAMES = [_][]const u8{ "|", "/", "-", "\\" };
/// Between the title and the stage.
const UNICODE_SEPARATOR = " · ";
const ASCII_SEPARATOR = " - ";
/// The bar's cells between its brackets.
const BAR_CELLS = 20;
/// The most bytes of a title, stage or step kept, cut between characters.
const MAX_TEXT_BYTES = 160;
/// Room for a frame before it is cut to the terminal's width.
const MAX_FRAME_BYTES = 512;
/// The width assumed when the terminal doesn't say.
const FALLBACK_COLUMNS = 80;
/// Windows' code page for UTF-8.
const UTF8_CODE_PAGE = 65001;

// The process's one line: a terminal has one place for it. Started and stopped by the
// command's thread; `animation` is set while it shows.
var line: Line = undefined;
var animation: ?std.Io.Future(std.Io.Cancelable!void) = null;

/// What the terminal can show: braille and `·`, or ASCII alone.
pub const Charset = enum { unicode, ascii };

/// Whether the line may show, from what `detect` reads: off unless stderr is a terminal that
/// takes ANSI escape codes, and off in CI (`CI` set and non-empty, as GitHub Actions and the
/// other services set it), on a dumb terminal (`TERM=dumb`) and with KUPCAD_NO_PROGRESS set.
pub fn wanted(environ: *const std.process.Environ.Map, ansi_terminal: bool) bool {
    if (!ansi_terminal) return false;
    if (isSet(environ, "CI") or isSet(environ, NO_PROGRESS_ENV)) return false;
    const term = environ.get("TERM") orelse "";
    return !std.mem.eql(u8, term, "dumb");
}

/// The charset of a terminal whose code page is `code_page`: Windows' console writes the
/// bytes as its output code page says, so braille shows only under UTF-8's; other systems
/// (null) leave it to the terminal emulator, which takes UTF-8 (the locale isn't the
/// terminal's: LANG=C over ssh still has one that shows it).
pub fn charsetFor(code_page: ?u32) Charset {
    const page = code_page orelse return .unicode;
    return if (page == UTF8_CODE_PAGE) .unicode else .ascii;
}

/// The charset the line is drawn in on `file` (stderr), or null when it isn't to show
/// (`wanted`). A terminal takes ANSI escape codes when Terminal.Mode.detect says so with
/// neither NO_COLOR nor CLICOLOR_FORCE given, which the colours are about, not the line.
pub fn detect(io: std.Io, file: std.Io.File, environ: *const std.process.Environ.Map) ?Charset {
    const mode = std.Io.Terminal.Mode.detect(io, file, false, false) catch return null;
    if (!wanted(environ, mode == .escape_codes)) return null;
    return charsetFor(codePageOf(io, file));
}

/// The output code page of the Windows console on `file` (0, so ASCII, when it doesn't
/// say), or null elsewhere.
fn codePageOf(io: std.Io, file: std.Io.File) ?u32 {
    if (builtin.os.tag != .windows) return null;
    var get_code_page = std.os.windows.CONSOLE.USER_IO.GET_CP(.Output);
    const status = get_code_page.operate(io, file) catch return 0;
    return if (status == .SUCCESS) get_code_page.Data.CodePage else 0;
}

fn isSet(environ: *const std.process.Environ.Map, name: []const u8) bool {
    const v = environ.get(name) orelse return false;
    return v.len > 0;
}

/// What one frame shows.
pub const Frame = struct {
    /// What the command does: "Building part.kup", "Checking".
    title: []const u8 = "",
    /// Where it is: the step the work below told, else the command's stage.
    stage: []const u8 = "",
    /// How much of it is done; a bar when the total is known.
    amount: ?Amount = null,
    /// Since the line started, for the spinner's frame and the time shown.
    elapsed_ns: u64 = 0,
    charset: Charset = .unicode,
};

/// `frame` as one line of at most `columns` columns (one short of them, as a line that
/// fills the last column wraps on some terminals), written into `buf`: the spinner, the
/// title and stage, the amount and the time, or with a total a bar first and no time.
/// Cut between characters, counting each as a column.
pub fn render(buf: *[MAX_FRAME_BYTES]u8, frame: Frame, columns: u16) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeFrame(&w, frame) catch {}; // a frame past the buffer is cut, as one past the width
    return fitColumns(w.buffered(), columns -| 1);
}

fn writeFrame(w: *std.Io.Writer, frame: Frame) std.Io.Writer.Error!void {
    const measured = if (frame.amount) |a| a.total != null else false;
    if (measured) {
        const a = frame.amount.?;
        const total = a.total.?;
        const done = @min(a.done, total);
        // Nothing to do is all of it done
        const percent: u64 = if (total == 0) 100 else done * 100 / total;
        const filled: usize = if (total == 0) BAR_CELLS else @intCast(done * BAR_CELLS / total);
        try w.writeByte('[');
        try w.splatByteAll('=', filled);
        if (filled < BAR_CELLS) {
            try w.writeByte('>');
            try w.splatByteAll(' ', BAR_CELLS - filled - 1);
        }
        try w.print("] {d}%", .{percent});
    } else {
        const frames: []const []const u8 = switch (frame.charset) {
            .unicode => &UNICODE_FRAMES,
            .ascii => &ASCII_FRAMES,
        };
        const turn = frame.elapsed_ns / FRAME_NS;
        try w.writeAll(frames[@intCast(turn % frames.len)]);
    }
    if (frame.title.len > 0) try w.print(" {s}", .{frame.title});
    if (frame.stage.len > 0) {
        if (frame.title.len > 0) try w.writeAll(switch (frame.charset) {
            .unicode => UNICODE_SEPARATOR,
            .ascii => ASCII_SEPARATOR,
        }) else try w.writeByte(' ');
        try w.writeAll(frame.stage);
    }
    if (frame.amount) |a| {
        try w.writeByte(' ');
        try writeAmount(w, a);
    }
    if (!measured) {
        try w.writeByte(' ');
        try writeElapsed(w, frame.elapsed_ns);
    }
}

/// `23/49 files`, `23 files`, `1.2/5.6 MB`, `1.2 MB`: sizes in the unit the larger reads
/// best in, decimal (a kB is 1000 bytes), as file managers show them.
fn writeAmount(w: *std.Io.Writer, a: Amount) std.Io.Writer.Error!void {
    switch (a.unit) {
        .files => {
            if (a.total) |total| try w.print("{d}/{d}", .{ a.done, total }) else try w.print("{d}", .{a.done});
            try w.writeAll(if ((a.total orelse a.done) == 1) " file" else " files");
        },
        .bytes => {
            const unit = SizeUnit.of(@max(a.done, a.total orelse 0));
            try unit.write(w, a.done);
            if (a.total) |total| {
                try w.writeByte('/');
                try unit.write(w, total);
            }
            try w.print(" {s}", .{unit.name});
        },
    }
}

const SizeUnit = struct {
    name: []const u8,
    bytes: u64,

    const UNITS = [_]SizeUnit{
        .{ .name = "B", .bytes = 1 },
        .{ .name = "kB", .bytes = 1000 },
        .{ .name = "MB", .bytes = 1000 * 1000 },
        .{ .name = "GB", .bytes = 1000 * 1000 * 1000 },
    };

    fn of(size: u64) SizeUnit {
        var unit = UNITS[0];
        for (UNITS) |u| {
            if (size >= u.bytes) unit = u;
        }
        return unit;
    }

    /// `size` in this unit: bytes whole, the others to a tenth.
    fn write(self: SizeUnit, w: *std.Io.Writer, size: u64) std.Io.Writer.Error!void {
        if (self.bytes == 1) return w.print("{d}", .{size});
        const tenths = size * 10 / self.bytes;
        try w.print("{d}.{d}", .{ tenths / 10, tenths % 10 });
    }
};

/// `1.8s`, then from a minute on `2m05s`.
fn writeElapsed(w: *std.Io.Writer, ns: u64) std.Io.Writer.Error!void {
    const tenths = ns / (std.time.ns_per_s / 10);
    if (tenths < 600) return w.print("{d}.{d}s", .{ tenths / 10, tenths % 10 });
    const seconds = tenths / 10;
    try w.print("{d}m{d:0>2}s", .{ seconds / 60, seconds % 60 });
}

/// The start of `text` that takes at most `columns` columns, a character each, cut before a
/// character's first byte.
pub fn fitColumns(text: []const u8, columns: usize) []const u8 {
    var count: usize = 0;
    for (text, 0..) |byte, i| {
        if (isContinuation(byte)) continue;
        if (count == columns) return text[0..i];
        count += 1;
    }
    return text;
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

/// A title, stage or step as the line keeps it: its first MAX_TEXT_BYTES, cut between
/// characters, with control characters (a newline in a file's name) shown as `?`, which
/// would break the line.
const Text = struct {
    bytes: [MAX_TEXT_BYTES]u8 = undefined,
    len: usize = 0,

    fn set(self: *Text, text: []const u8) void {
        var n = @min(text.len, MAX_TEXT_BYTES);
        if (n < text.len) {
            while (n > 0 and isContinuation(text[n])) n -= 1;
        }
        for (text[0..n], self.bytes[0..n]) |from, *to| to.* = if (from < 0x20 or from == 0x7f) '?' else from;
        self.len = n;
    }

    fn print(self: *Text, comptime fmt: []const u8, args: anytype) void {
        var buf: [MAX_TEXT_BYTES]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print(fmt, args) catch {}; // past the room it is cut, as `set` cuts
        self.set(w.buffered());
    }

    fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }

    fn eql(self: *const Text, text: []const u8) bool {
        return std.mem.eql(u8, self.slice(), text);
    }
};

/// The line's state. What the command and the work tell it is guarded by `mutex`, so any
/// thread can tell it; what is on the terminal is guarded by the stderr lock, which drawing
/// and every print hold (log.zig).
pub const Line = struct {
    io: std.Io,
    charset: Charset,
    /// When the line started, on the awake clock.
    started_ns: i96,
    hook: log.StderrHook,

    mutex: std.Io.Mutex = .init,
    // --- Guarded by `mutex` ---
    title: Text = .{},
    stage: Text = .{},
    stage_amount: ?Amount = null,
    /// What the work below told (core Progress.step), shown in place of the stage.
    step: Text = .{},
    step_amount: ?Amount = null,

    // --- Guarded by the stderr lock ---
    /// The line is on the terminal, to be taken off before anything else is printed.
    drawn: bool = false,
    /// The last print ended its line: one that didn't (a script's `print "..."`) is
    /// continued by the next, and the line waits rather than draw over it.
    at_line_start: bool = true,
    /// The debugger has the terminal.
    paused: bool = false,

    /// A line in place at `self` (its hook points into it), started `started_ns`.
    pub fn init(self: *Line, io: std.Io, charset: Charset, started_ns: i96) void {
        self.* = .{
            .io = io,
            .charset = charset,
            .started_ns = started_ns,
            .hook = .{ .context = self, .io = io, .before = hookBefore, .after = hookAfter },
        };
    }

    pub fn setTitle(self: *Line, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.title.print(fmt, args);
    }

    pub fn setStage(self: *Line, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stage.print(fmt, args);
        self.stage_amount = null;
    }

    pub fn setAmount(self: *Line, measured: ?Amount) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stage_amount = measured;
    }

    fn setStep(self: *Line, name: []const u8, measured: ?Amount) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.step.eql(name)) self.step.set(name);
        self.step_amount = measured;
    }

    fn endStep(self: *Line, name: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.step.eql(name)) return;
        self.step.len = 0;
        self.step_amount = null;
    }

    /// The core Progress the work below the CLI tells its steps through.
    pub fn progress(self: *Line) core_progress.Progress {
        return .{ .context = self, .vtable = &VTABLE };
    }

    const VTABLE: core_progress.Progress.VTable = .{ .step = stepImpl, .done = doneImpl };

    fn stepImpl(context: ?*anyopaque, name: []const u8, measured: ?Amount) void {
        const self: *Line = @ptrCast(@alignCast(context.?));
        self.setStep(name, measured);
    }

    fn doneImpl(context: ?*anyopaque, name: []const u8) void {
        const self: *Line = @ptrCast(@alignCast(context.?));
        self.endStep(name);
    }

    /// Draws the frame of `now_ns` on `w` (stderr, its lock held), `columns` wide, over the
    /// last: unless the debugger has the terminal or the cursor is mid-line.
    pub fn draw(self: *Line, w: *std.Io.Writer, columns: u16, now_ns: i96) void {
        if (self.paused or !self.at_line_start) return;
        var title_buf: [MAX_TEXT_BYTES]u8 = undefined;
        var stage_buf: [MAX_TEXT_BYTES]u8 = undefined;
        var frame: Frame = .{ .charset = self.charset, .elapsed_ns = @intCast(@max(0, now_ns - self.started_ns)) };
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            frame.title = copy(&title_buf, self.title.slice());
            const shown = if (self.step.len > 0) &self.step else &self.stage;
            frame.stage = copy(&stage_buf, shown.slice());
            frame.amount = if (self.step.len > 0) self.step_amount else self.stage_amount;
        }
        var buf: [MAX_FRAME_BYTES]u8 = undefined;
        const text = render(&buf, frame, columns);
        // Drawn, whole or in part, from the first byte: whatever got there comes off
        self.drawn = true;
        w.writeAll(CLEAR) catch return;
        w.writeAll(text) catch return;
        w.flush() catch return;
    }

    fn copy(buf: *[MAX_TEXT_BYTES]u8, text: []const u8) []const u8 {
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }

    /// Takes the line off `w` (stderr, its lock held) if it is drawn.
    pub fn takeOff(self: *Line, w: *std.Io.Writer) void {
        if (!self.drawn) return;
        w.writeAll(CLEAR) catch return;
        w.flush() catch return;
        self.drawn = false;
    }

    fn hookBefore(context: *anyopaque, w: *std.Io.Writer) void {
        const self: *Line = @ptrCast(@alignCast(context));
        self.takeOff(w);
    }

    fn hookAfter(context: *anyopaque, at_line_start: bool) void {
        const self: *Line = @ptrCast(@alignCast(context));
        self.at_line_start = at_line_start;
    }
};

/// Shows the line, titled as `fmt` says, if `reporter` may (`Reporter.progress`, which
/// `detect` set; never for a host reading `--errors json`, nor a test's capture). Nothing
/// if a line shows already. Taken off by `stop`.
pub fn start(reporter: Reporter, comptime fmt: []const u8, args: anytype) void {
    if (animation != null) return;
    const charset = reporter.progress orelse return;
    if (reporter.errors == .json or reporter.capture != null) return;
    const io = reporter.io;
    line.init(io, charset, std.Io.Clock.awake.now(io).nanoseconds);
    line.setTitle(fmt, args);
    log.setStderrHook(&line.hook);
    // An Io that can't run the drawing beside the work shows no line
    animation = io.concurrent(animate, .{&line}) catch {
        log.setStderrHook(null);
        return;
    };
}

/// Takes the line off the terminal, for good: the work is done or failed.
pub fn stop() void {
    var running = animation orelse return;
    animation = null;
    const io = line.io;
    running.cancel(io) catch {};
    var buf: [64]u8 = undefined;
    if (io.lockStderr(&buf, null)) |locked| {
        defer io.unlockStderr();
        line.takeOff(&locked.file_writer.interface);
    } else |_| {}
    log.setStderrHook(null);
}

/// The command is at the stage `fmt` says (with no amount).
pub fn stage(comptime fmt: []const u8, args: anytype) void {
    if (animation == null) return;
    line.setStage(fmt, args);
}

/// How much of the command's stage is done.
pub fn amount(done: u64, total: ?u64, unit: core_progress.Progress.Unit) void {
    if (animation == null) return;
    line.setAmount(.{ .done = done, .total = total, .unit = unit });
}

/// The core Progress the work below the CLI tells its steps through: to the line while it
/// shows, else to no one.
pub fn core() core_progress.Progress {
    if (animation == null) return .none;
    return line.progress();
}

/// Takes the line off and holds it off while the debugger has the terminal; `unpause` gives
/// it back.
pub fn pause() void {
    setPaused(true);
}

pub fn unpause() void {
    setPaused(false);
}

fn setPaused(paused: bool) void {
    if (animation == null) return;
    const io = line.io;
    var buf: [64]u8 = undefined;
    const locked = io.lockStderr(&buf, null) catch return;
    defer io.unlockStderr();
    line.takeOff(&locked.file_writer.interface);
    line.paused = paused;
}

fn animate(shown: *Line) std.Io.Cancelable!void {
    const io = shown.io;
    try io.sleep(INITIAL_DELAY, .awake);
    while (true) {
        const columns = columnsOf(io, std.Io.File.stderr());
        {
            var buf: [MAX_FRAME_BYTES]u8 = undefined;
            const locked = try io.lockStderr(&buf, null);
            defer io.unlockStderr();
            // `stop` cancels between frames, not within one: a frame cut short would be left
            // on the shared stderr writer
            const previous = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(previous);
            shown.draw(&locked.file_writer.interface, columns, std.Io.Clock.awake.now(io).nanoseconds);
        }
        try io.sleep(REDRAW_INTERVAL, .awake);
    }
}

/// How many columns the terminal on `file` has, asked each frame (a resize shows on the
/// next); FALLBACK_COLUMNS when it doesn't say.
fn columnsOf(io: std.Io, file: std.Io.File) u16 {
    if (builtin.os.tag == .windows) {
        var info = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
        const status = info.operate(io, file) catch return FALLBACK_COLUMNS;
        if (status != .SUCCESS or info.Data.dwWindowSize.X <= 0) return FALLBACK_COLUMNS;
        return @intCast(info.Data.dwWindowSize.X);
    }
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = io.operate(.{ .device_io_control = .{ .file = file, .code = std.posix.T.IOCGWINSZ, .arg = &size } }) catch return FALLBACK_COLUMNS;
    if (result.device_io_control < 0 or size.col == 0) return FALLBACK_COLUMNS;
    return size.col;
}
