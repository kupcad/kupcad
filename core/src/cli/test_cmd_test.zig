//! `kupcad test`: the test blocks of the files found run, each reported, and the outcome.

const std = @import("std");
const testing = std.testing;
const test_cmd = @import("test_cmd.zig");
const Args = @import("args.zig").Args;

/// Runs `kupcad test` with `args`; the outcome, and what it reported in `output`.
fn runWith(args: []const []const u8, output: *std.Io.Writer.Allocating) !test_cmd.Outcome {
    var it: Args = .{ .items = args };
    return test_cmd.run(testing.allocator, &it, .{ .io = testing.io, .capture = &output.writer });
}

fn expectSays(output: []const u8, says: []const u8) !void {
    errdefer std.debug.print("reported:\n{s}\n", .{output});
    try testing.expect(std.mem.find(u8, output, says) != null);
}

fn expectSilentOn(output: []const u8, about: []const u8) !void {
    errdefer std.debug.print("reported:\n{s}\n", .{output});
    try testing.expect(std.mem.find(u8, output, about) == null);
}

const Tree = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,

    fn init() !Tree {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "tests");
        try tmp.dir.createDirPath(testing.io, ".kupcad/pkg/dep");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "tests/bolt_test.kup", .data =
            \\def bolt(len)
            \\  cylinder(r: 3, h: len)
            \\end
            \\test("one") do
            \\  assert_near(bolt(10).bbox.size[2], 10)
            \\end
            \\test("two") do
            \\  assert_equal(1, 2)
            \\end
            \\
        });
        // No test block: not run from a directory (it would fail: the raise is its model)
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain.kup", .data = "raise \"a plain file ran\"\n" });
        // Hidden: an installed package's tests aren't the project's
        try tmp.dir.writeFile(testing.io, .{ .sub_path = ".kupcad/pkg/dep/dep_test.kup", .data = "test(\"hidden\") do\n  raise \"a package's test ran\"\nend\n" });
        const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .dir = dir };
    }

    fn deinit(self: *Tree) void {
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn path(self: *const Tree, name: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ self.dir, name });
    }
};

test "kupcad test: runs the test blocks of the files under a directory and reports each" {
    var tree = try Tree.init();
    defer tree.deinit();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectEqual(test_cmd.Outcome.failure, try runWith(&.{tree.dir}, &output));
    try expectSays(output.written(), "bolt_test.kup\n  ok   one\n  FAIL two\n       AssertionError: expected 2, got 1\n           from script:8:3:in 'script'\n");
    try expectSays(output.written(), "1 passed, 1 failed in 1 file\n");
    try expectSilentOn(output.written(), "plain");
    try expectSilentOn(output.written(), "hidden");

    // Only the tests the filter names, and passing is success
    output.clearRetainingCapacity();
    try testing.expectEqual(test_cmd.Outcome.success, try runWith(&.{ tree.dir, "--filter", "on" }, &output));
    try expectSays(output.written(), "  ok   one\n");
    try expectSilentOn(output.written(), "two");
    try expectSays(output.written(), "1 passed, 0 failed in 1 file\n");
}

test "kupcad test: a file named outright runs as it is, and an import's test blocks don't run" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.kup", .data = "def f\n  1\nend\nexport { f }\ntest(\"lib\") do\n  raise \"an import's test ran\"\nend\n" });
    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "main_test.kup", .data = "import { f } from \"./lib.kup\"\ntest(\"f\") do\n  assert_equal(f, 1)\nend\n" });
    const main = try tree.path("main_test.kup");
    defer testing.allocator.free(main);
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectEqual(test_cmd.Outcome.success, try runWith(&.{main}, &output));
    try expectSays(output.written(), "  ok   f\n1 passed, 0 failed in 1 file\n");
    try expectSilentOn(output.written(), "lib");

    // Named, a file without tests runs too: its author asked for it, and it may not compile
    const plain = try tree.path("plain.kup");
    defer testing.allocator.free(plain);
    output.clearRetainingCapacity();
    try testing.expectEqual(test_cmd.Outcome.failure, try runWith(&.{plain}, &output));
    // Its raise is the run's error, which the VM reports as it happens; the command tells the rest
    try expectSays(output.written(), "Build failed: error.RuntimeError\n");
    try expectSays(output.written(), "plain.kup\n  FAIL the file didn't run\n0 passed, 0 failed in 1 file, 1 file didn't run\n");
}

test "kupcad test: a file that doesn't run, a run stopped inside a test, no tests at all, and bad arguments" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "tests/broken_test.kup", .data = "test(\"a\") do\n  x = )\nend\n" });
    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "tests/deep_test.kup", .data = "def down\n  down\nend\ntest(\"deep\") do\n  down\nend\n" });
    try tree.tmp.dir.createDirPath(testing.io, "empty");
    const broken = try tree.path("tests/broken_test.kup");
    defer testing.allocator.free(broken);
    const deep = try tree.path("tests/deep_test.kup");
    defer testing.allocator.free(deep);
    const empty = try tree.path("empty");
    defer testing.allocator.free(empty);
    const cases = [_]struct { args: []const []const u8, says: []const u8 }{
        .{ .args = &.{broken}, .says = "  FAIL the file didn't run\n0 passed, 0 failed in 1 file, 1 file didn't run\n" },
        // A fatal error (the stack overflowed) ends the file inside the test
        .{ .args = &.{deep}, .says = "  FAIL deep: the run stopped inside it\n  FAIL the file didn't run\n" },
        .{ .args = &.{empty}, .says = "No tests found: no file holds a test(\"name\") do ... end block\n" },
        .{ .args = &.{ tree.dir, "--bogus" }, .says = "Error: Unknown option '--bogus'\n\nUsage: kupcad test" },
        .{ .args = &.{ tree.dir, "--filter" }, .says = "Error: Missing value after '--filter'\n\nUsage: kupcad test" },
    };
    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        try testing.expectEqual(test_cmd.Outcome.failure, try runWith(case.args, &output));
        try expectSays(output.written(), case.says);
    }
}
