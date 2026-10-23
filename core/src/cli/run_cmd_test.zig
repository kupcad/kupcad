//! `kupcad run`: a script run with its parameters, as build runs it, writing no model.

const std = @import("std");
const testing = std.testing;
const run_cmd = @import("run_cmd.zig");
const Args = @import("args.zig").Args;

/// Runs `kupcad run` with `args`; the outcome, and what it reported in `output`.
fn runWith(args: []const []const u8, output: *std.Io.Writer.Allocating) !run_cmd.Outcome {
    var it: Args = .{ .items = args };
    return run_cmd.run(testing.allocator, &it, .{ .io = testing.io, .capture = &output.writer });
}

test "kupcad run: runs the script with its parameters and writes no model" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // It fails unless -p reached it
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "model.kup", .data = "raise \"n is #{param(:n, default: 1)}\" unless param(:n, default: 1) == 5\ncube(1)\n" });
    const input = try tmp.dir.realPathFileAlloc(testing.io, "model.kup", testing.allocator);
    defer testing.allocator.free(input);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectEqual(run_cmd.Outcome.success, try runWith(&.{ input, "-p", "n=5" }, &output));
    try testing.expectEqual(run_cmd.Outcome.failure, try runWith(&.{input}, &output));
    // model.kup alone: no model.glb beside it, as build would write
    var entries: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |_| entries += 1;
    try testing.expectEqual(@as(usize, 1), entries);
}

test "kupcad run: a script that doesn't compile fails as build reports it, and so do bad arguments" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.kup", .data = "x = )\n" });
    const broken = try tmp.dir.realPathFileAlloc(testing.io, "broken.kup", testing.allocator);
    defer testing.allocator.free(broken);
    const cases = [_]struct { args: []const []const u8, says: []const u8 }{
        .{ .args = &.{broken}, .says = "Build failed: 1 error in " },
        .{ .args = &.{}, .says = "Error: Missing input file path.\n\nUsage: kupcad run" },
        .{ .args = &.{ broken, "-o", "x.stl" }, .says = "Error: Unknown option '-o'" },
        .{ .args = &.{ "a.kup", "b.kup" }, .says = "Error: Expected one input file, got 'a.kup' and 'b.kup'" },
        .{ .args = &.{ broken, "-p", "width" }, .says = "Error: Invalid param format. Use --param key=value." },
    };
    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        errdefer std.debug.print("reported: {s}\n", .{output.written()});
        try testing.expectEqual(run_cmd.Outcome.failure, try runWith(case.args, &output));
        try testing.expect(std.mem.find(u8, output.written(), case.says) != null);
    }
}
