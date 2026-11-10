const std = @import("std");
const testing = std.testing;
const progress = @import("progress.zig");
const log = @import("../log.zig");
const Frame = progress.Frame;

/// A frame's time: so many frames of the spinner in.
fn frames(n: u64) u64 {
    return n * @as(u64, @intCast(progress.REDRAW_INTERVAL.nanoseconds));
}

fn rendered(buf: *[512]u8, frame: Frame, columns: u16) []const u8 {
    return progress.render(buf, frame, columns);
}

test "Progress: shows only on a terminal that takes ANSI, outside CI, unless turned off" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expect(progress.wanted(&env, true));
    // A pipe or a file: a host or a log reads it
    try testing.expect(!progress.wanted(&env, false));

    const cases = [_]struct { name: []const u8, value: []const u8, shows: bool }{
        .{ .name = "CI", .value = "true", .shows = false },
        .{ .name = "CI", .value = "", .shows = true },
        .{ .name = "TERM", .value = "dumb", .shows = false },
        .{ .name = "TERM", .value = "xterm-256color", .shows = true },
        .{ .name = progress.NO_PROGRESS_ENV, .value = "1", .shows = false },
        .{ .name = progress.NO_PROGRESS_ENV, .value = "", .shows = true },
    };
    for (cases) |case| {
        errdefer std.debug.print("{s}={s}\n", .{ case.name, case.value });
        var one: std.process.Environ.Map = .init(testing.allocator);
        defer one.deinit();
        try one.put(case.name, case.value);
        try testing.expectEqual(case.shows, progress.wanted(&one, true));
    }
}

test "Progress: braille where the terminal takes UTF-8, ASCII on a Windows console that doesn't" {
    try testing.expectEqual(progress.Charset.unicode, progress.charsetFor(null));
    try testing.expectEqual(progress.Charset.unicode, progress.charsetFor(65001));
    try testing.expectEqual(progress.Charset.ascii, progress.charsetFor(437));
    try testing.expectEqual(progress.Charset.ascii, progress.charsetFor(0));

    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("/ Building part.kup - running the script 0.0s", rendered(&buf, .{ .title = "Building part.kup", .stage = "running the script", .charset = .ascii, .elapsed_ns = frames(1) }, 80));
}

test "Progress: a spinner frame shows the title, the stage and the time so far" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("⠹ Building part.kup · evaluating geometry 1.8s", rendered(&buf, .{ .title = "Building part.kup", .stage = "evaluating geometry", .elapsed_ns = 1800 * std.time.ns_per_ms + 1 }, 80));
    // The frame turns with the time
    try testing.expectEqualStrings("⠹ Running part.kup 0.1s", rendered(&buf, .{ .title = "Running part.kup", .elapsed_ns = frames(2) }, 80));
    try testing.expectEqualStrings("⠋ Running part.kup 0.8s", rendered(&buf, .{ .title = "Running part.kup", .elapsed_ns = frames(10) }, 80));
    // No title: the stage alone
    try testing.expectEqualStrings("⠋ Installing packages 0.0s", rendered(&buf, .{ .stage = "Installing packages" }, 80));
    // Past a minute, in minutes
    try testing.expectEqualStrings("⠹ Building a.kup 2m05s", rendered(&buf, .{ .title = "Building a.kup", .elapsed_ns = 125 * std.time.ns_per_s }, 80));
}

test "Progress: a measured amount shows as a bar, clamped to whole, with the count" {
    var buf: [512]u8 = undefined;
    const cases = [_]struct { done: u64, total: u64, line: []const u8 }{
        .{ .done = 0, .total = 49, .line = "[>                   ] 0% Checking 0/49 files" },
        .{ .done = 23, .total = 49, .line = "[=========>          ] 46% Checking 23/49 files" },
        .{ .done = 49, .total = 49, .line = "[====================] 100% Checking 49/49 files" },
        // More done than the total said (a file added on the way) is all of it
        .{ .done = 60, .total = 49, .line = "[====================] 100% Checking 60/49 files" },
        .{ .done = 0, .total = 0, .line = "[====================] 100% Checking 0/0 files" },
        .{ .done = 0, .total = 1, .line = "[>                   ] 0% Checking 0/1 file" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case.line, rendered(&buf, .{ .title = "Checking", .amount = .{ .done = case.done, .total = case.total, .unit = .files } }, 80));
    }
}

test "Progress: bytes in the unit the larger reads best in, and a spinner without a total" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("[====>               ] 21% Downloading screws 1.2/5.6 MB", rendered(&buf, .{ .stage = "Downloading screws", .amount = .{ .done = 1_200_000, .total = 5_600_000, .unit = .bytes } }, 80));
    try testing.expectEqualStrings("⠋ Downloading screws 1.2 MB 0.0s", rendered(&buf, .{ .stage = "Downloading screws", .amount = .{ .done = 1_234_567, .unit = .bytes } }, 80));
    try testing.expectEqualStrings("⠋ Downloading screws 512 B 0.0s", rendered(&buf, .{ .stage = "Downloading screws", .amount = .{ .done = 512, .unit = .bytes } }, 80));
    try testing.expectEqualStrings("[==========>         ] 50% Downloading x 0.5/1.0 kB", rendered(&buf, .{ .stage = "Downloading x", .amount = .{ .done = 500, .total = 1000, .unit = .bytes } }, 80));
    try testing.expectEqualStrings("[====================] 100% Downloading x 2.0/2.0 GB", rendered(&buf, .{ .stage = "Downloading x", .amount = .{ .done = 2_000_000_000, .total = 2_000_000_000, .unit = .bytes } }, 80));
}

test "Progress: a frame is cut to the terminal's width between characters, and never wraps" {
    var buf: [512]u8 = undefined;
    const frame: Frame = .{ .title = "Building ünïcödé.kup", .stage = "evaluating geometry", .elapsed_ns = 0 };
    // One column short of the width: a line filling the last column wraps on some terminals
    try testing.expectEqualStrings("⠋ Building", rendered(&buf, frame, 11));
    try testing.expectEqualStrings("⠋ Building ü", rendered(&buf, frame, 13));
    try testing.expectEqualStrings("⠋ Building ün", rendered(&buf, frame, 14));
    try testing.expectEqualStrings("", rendered(&buf, frame, 0));
    // A frame longer than its room is cut, not lost
    const long: [600]u8 = @splat('x');
    try testing.expectEqual(@as(usize, 199), try std.unicode.utf8CountCodepoints(rendered(&buf, .{ .title = &long }, 200)));
}

/// A line drawing on `out` as on a terminal, as if stderr were one: the seam the process
/// tests can't reach, since their stderr is a pipe.
const Terminal = struct {
    out: std.Io.Writer.Allocating,
    line: progress.Line = undefined,

    fn init(self: *Terminal) void {
        self.out = .init(testing.allocator);
        self.line.init(testing.io, .unicode, 0);
    }

    fn deinit(self: *Terminal) void {
        self.out.deinit();
    }

    fn draw(self: *Terminal, now_ns: u64) void {
        self.line.draw(&self.out.writer, 80, @intCast(now_ns));
    }

    /// A print through log.zig's path, the line told around it.
    fn print(self: *Terminal, text: []const u8, ends_line: bool) void {
        log.printAround(&self.out.writer, &self.line.hook, ends_line, "{s}", .{text});
    }
};

test "Progress: a print takes the line off first, and the next frame draws it again below" {
    var t: Terminal = undefined;
    t.init();
    defer t.deinit();
    t.line.setTitle("Building {s}", .{"part.kup"});
    t.line.setStage("running the script", .{});
    t.draw(frames(3));
    t.print("hello from puts\n", true);
    t.draw(frames(4));
    const expected = progress.CLEAR ++ "⠸ Building part.kup · running the script 0.2s" ++
        progress.CLEAR ++ "hello from puts\n" ++
        progress.CLEAR ++ "⠼ Building part.kup · running the script 0.3s";
    try testing.expectEqualStrings(expected, t.out.written());

    // Off for good: a print after it is printed alone
    t.out.clearRetainingCapacity();
    t.line.takeOff(&t.out.writer);
    t.print("done\n", true);
    try testing.expectEqualStrings(progress.CLEAR ++ "done\n", t.out.written());
}

test "Progress: a print that leaves its line open isn't drawn over until the line ends" {
    // A script's `print "Working..."` would be erased by the next frame's clear
    var t: Terminal = undefined;
    t.init();
    defer t.deinit();
    t.line.setTitle("Running {s}", .{"part.kup"});
    t.print("Working...", false);
    t.draw(frames(1));
    try testing.expectEqualStrings("Working...", t.out.written());
    t.print(" done\n", true);
    t.draw(frames(2));
    try testing.expectEqualStrings("Working... done\n" ++ progress.CLEAR ++ "⠹ Running part.kup 0.1s", t.out.written());
}

test "Progress: the work's step shows in place of the stage until it is done" {
    var t: Terminal = undefined;
    t.init();
    defer t.deinit();
    t.line.setTitle("Building {s}", .{"part.kup"});
    t.line.setStage("writing part.stl", .{});
    const told = t.line.progress();
    told.step("evaluating geometry", null);
    t.draw(0);
    try testing.expect(std.mem.endsWith(u8, t.out.written(), "⠋ Building part.kup · evaluating geometry 0.0s"));
    // Another thread's step stays until its own ends
    told.step("Downloading screws", .{ .done = 1, .total = 4, .unit = .bytes });
    told.done("evaluating geometry");
    t.draw(0);
    try testing.expect(std.mem.endsWith(u8, t.out.written(), "[=====>              ] 25% Building part.kup · Downloading screws 1/4 B"));
    told.done("Downloading screws");
    t.draw(0);
    try testing.expect(std.mem.endsWith(u8, t.out.written(), "⠋ Building part.kup · writing part.stl 0.0s"));
}

test "Progress: paused for the debugger, the line stays off" {
    var t: Terminal = undefined;
    t.init();
    defer t.deinit();
    t.line.setTitle("Building {s}", .{"part.kup"});
    t.line.paused = true;
    t.draw(0);
    try testing.expectEqualStrings("", t.out.written());
}

test "Progress: a title's control characters can't break the line, and a long one is cut whole" {
    var t: Terminal = undefined;
    t.init();
    defer t.deinit();
    t.line.setTitle("Building {s}", .{"a\nb\x1b.kup"});
    t.draw(0);
    try testing.expect(std.mem.endsWith(u8, t.out.written(), "⠋ Building a?b?.kup 0.0s"));
    var accents: [400]u8 = undefined;
    for (0..200) |i| @memcpy(accents[i * 2 ..][0..2], "é");
    t.line.setTitle("{s}", .{&accents});
    t.out.clearRetainingCapacity();
    t.line.draw(&t.out.writer, 1000, 0);
    try testing.expect(std.unicode.utf8ValidateSlice(t.out.written()));
}

test "Progress: without a line started, the command's calls and the core's do nothing" {
    // A test's reporter has no terminal: progress.start shows nothing
    progress.start(.{ .io = testing.io }, "Building {s}", .{"part.kup"});
    defer progress.stop();
    progress.stage("running the script", .{});
    progress.amount(1, 2, .files);
    const told = progress.core();
    told.step("evaluating geometry", null);
    told.done("evaluating geometry");
    try testing.expectEqual(@as(?*anyopaque, null), told.context);
}
