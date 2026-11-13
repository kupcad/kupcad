//! `zig build fuzz-run`: a fuzzing session whose exit status says whether it found a
//! failure. Zig 0.17's `zig build fuzz --fuzz=N` reports a failing input and saves it as
//! `f/crash` in the cache, but exits 0: its build runner counts only the steps it made
//! before fuzzing, not what the fuzzer found after. This runs that session as a child
//! process, echoes its output and keeps it in `f/fuzz-output.txt` beside the crash (with
//! the `replay:` line a Locus target prints, which `zig build test -Dfuzz-replay=FILE` in
//! src/locus plays back), and exits 1 when the session saved a crash, reported a test that
//! failed or crashed, or failed itself.
//!
//! A run that panics ends its worker before it can print its `replay:` line, so Locus's
//! fuzz targets write each run's line into `f/draws-<kind>.txt` as the run draws, and clear
//! it when the run ends: a file left with a line is the run a crash interrupted, and its
//! line is printed (and kept in the output) with the failure.
//!
//! Arguments: the zig executable, the cache directory, the run count (`--fuzz=`'s), and the
//! fuzz target (`-Dfuzz-target=`'s), or none for every target.

const std = @import("std");

/// What the build runner prints of a fuzz test that failed: an error it returned (a failed
/// check) or a crash (a panic, a signal).
const FAILURE_MARKERS = [_][]const u8{ "exited with code", "terminated with signal", "input saved to" };
/// Bytes read from the session at a time.
const CHUNK = 64 * 1024;
/// A draws file's name around its kind (src/locus/src/fuzz_test.zig's `DrawLog`).
const DRAWS_PREFIX = "draws-";
const DRAWS_SUFFIX = ".txt";
/// The longest draws file read: a run's line is a few kilobytes.
const MAX_DRAWS_BYTES = 1 << 20;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4 or args.len > 5) {
        try std.Io.File.stderr().writeStreamingAll(io, "usage: fuzz_run ZIG CACHE_DIR RUNS [TARGET]\n");
        std.process.exit(2);
    }
    const zig = args[1];
    const cache = args[2];
    const runs = args[3];
    const fuzz_dir = try std.fs.path.join(arena, &.{ cache, "f" });
    const crash = try std.fs.path.join(arena, &.{ fuzz_dir, "crash" });
    const output_path = try std.fs.path.join(arena, &.{ fuzz_dir, "fuzz-output.txt" });
    const cwd = std.Io.Dir.cwd();
    // A crash file the cache kept is an earlier session's, and so are its draws files
    cwd.deleteFile(io, crash) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try cwd.createDirPath(io, fuzz_dir);
    {
        var dir = try cwd.openDir(io, fuzz_dir, .{ .iterate = true });
        defer dir.close(io);
        try deleteDraws(io, arena, dir);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ zig, "build", "fuzz", try std.fmt.allocPrint(arena, "--fuzz={s}", .{runs}) });
    if (args.len == 5) try argv.append(arena, try std.fmt.allocPrint(arena, "-Dfuzz-target={s}", .{args[4]}));
    var child = try std.process.spawn(io, .{ .argv = argv.items, .stdout = .inherit, .stderr = .pipe });

    // The session's output, echoed as it comes and kept
    const output_file = try cwd.createFile(io, output_path, .{});
    defer output_file.close(io);
    var output: std.ArrayList(u8) = .empty;
    const chunk = try arena.alloc(u8, CHUNK);
    while (true) {
        const n = child.stderr.?.readStreaming(io, &.{chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) continue;
        try std.Io.File.stderr().writeStreamingAll(io, chunk[0..n]);
        try output_file.writeStreamingAll(io, chunk[0..n]);
        try output.appendSlice(arena, chunk[0..n]);
    }
    const term = try child.wait(io);

    var failed = false;
    switch (term) {
        .exited => |code| if (code != 0) {
            failed = true;
        },
        else => failed = true,
    }
    for (FAILURE_MARKERS) |marker| failed = failed or std.mem.indexOf(u8, output.items, marker) != null;
    const saved = if (cwd.access(io, crash, .{})) true else |_| false;
    if (saved or failed) {
        // The line of a run a crash interrupted, kept with the output
        var dir = try cwd.openDir(io, fuzz_dir, .{ .iterate = true });
        defer dir.close(io);
        const interrupted = try interruptedRuns(io, arena, dir);
        if (interrupted.len > 0) {
            const note = try std.fmt.allocPrint(arena, "fuzz-run: the run a crash interrupted, from its draws:\n{s}", .{interrupted});
            try std.Io.File.stderr().writeStreamingAll(io, note);
            try output_file.writeStreamingAll(io, note);
        }
        var message: std.ArrayList(u8) = .empty;
        try message.print(arena, "fuzz-run: the session found a failure", .{});
        if (saved) try message.print(arena, "; its input is in {s}", .{crash});
        try message.print(arena, "; its output, with any replay: line, in {s}\n", .{output_path});
        try std.Io.File.stderr().writeStreamingAll(io, message.items);
        std.process.exit(1);
    }
}

/// The lines the draws files in `dir` hold, each ending in a line break: the runs that
/// never ended (a run that does clears its file). Empty when there are none.
fn interruptedRuns(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !isDraws(entry.name)) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    // In the order of their names, whatever the directory's
    std.mem.sort([]const u8, names.items, {}, lessName);
    var out: std.ArrayList(u8) = .empty;
    for (names.items) |name| {
        const text = std.mem.trim(u8, try dir.readFileAlloc(io, name, arena, .limited(MAX_DRAWS_BYTES)), " \r\n");
        if (text.len == 0) continue;
        try out.print(arena, "{s}\n", .{text});
    }
    return out.items;
}

/// Deletes the draws files in `dir`.
fn deleteDraws(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir) !void {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and isDraws(entry.name)) try names.append(arena, try arena.dupe(u8, entry.name));
    }
    for (names.items) |name| try dir.deleteFile(io, name);
}

fn isDraws(name: []const u8) bool {
    return std.mem.startsWith(u8, name, DRAWS_PREFIX) and std.mem.endsWith(u8, name, DRAWS_SUFFIX);
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "fuzz_run: the draws files left with a line are the runs a crash interrupted" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A run that ended (cleared), one a panic interrupted, and a file of something else
    try tmp.dir.writeFile(io, .{ .sub_path = "draws-overlay.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "draws-solids.txt", .data = "replay: solids 0 3 4 1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "crash", .data = "replay: not a draws file" });
    try std.testing.expectEqualStrings("replay: solids 0 3 4 1\n", try interruptedRuns(io, arena, tmp.dir));
    // A new session starts with none
    try deleteDraws(io, arena, tmp.dir);
    try std.testing.expectEqualStrings("", try interruptedRuns(io, arena, tmp.dir));
    try tmp.dir.access(io, "crash", .{});
}
