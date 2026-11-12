//! `zig build fuzz-run`: a fuzzing session whose exit status says whether it found a
//! failure. Zig 0.17's `zig build fuzz --fuzz=N` reports a failing input and saves it as
//! `f/crash` in the cache, but exits 0: its build runner counts only the steps it made
//! before fuzzing, not what the fuzzer found after. This runs that session as a child
//! process, echoes its output and keeps it in `f/fuzz-output.txt` beside the crash (with
//! the `replay:` line a Locus target prints, which `zig build test -Dfuzz-replay=FILE` in
//! src/locus plays back), and exits 1 when the session saved a crash, reported a test that
//! failed or crashed, or failed itself.
//!
//! Arguments: the zig executable, the cache directory, the run count (`--fuzz=`'s), and the
//! fuzz target (`-Dfuzz-target=`'s), or none for every target.

const std = @import("std");

/// What the build runner prints of a fuzz test that failed: an error it returned (a failed
/// check) or a crash (a panic, a signal).
const FAILURE_MARKERS = [_][]const u8{ "exited with code", "terminated with signal", "input saved to" };
/// Bytes read from the session at a time.
const CHUNK = 64 * 1024;

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
    // A crash file the cache kept is an earlier session's
    cwd.deleteFile(io, crash) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try cwd.createDirPath(io, fuzz_dir);

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
        var message: std.ArrayList(u8) = .empty;
        try message.print(arena, "fuzz-run: the session found a failure", .{});
        if (saved) try message.print(arena, "; its input is in {s}", .{crash});
        try message.print(arena, "; its output, with any replay: line, in {s}\n", .{output_path});
        try std.Io.File.stderr().writeStreamingAll(io, message.items);
        std.process.exit(1);
    }
}
