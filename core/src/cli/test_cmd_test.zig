//! `kupcad test`: the test blocks of the files found run, each reported, and the outcome.

const std = @import("std");
const testing = std.testing;
const test_cmd = @import("test_cmd.zig");
const Args = @import("args.zig").Args;
const test_support = @import("../test_support.zig");

/// Runs `kupcad test` with `args`; the outcome, and what it reported in `output`.
fn runWith(args: []const []const u8, output: *std.Io.Writer.Allocating) !test_cmd.Outcome {
    var it: Args = .{ .items = args };
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    return test_cmd.run(testing.allocator, &it, &environ, .{ .io = testing.io, .capture = &output.writer });
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

    // Only the tests the filter names (a substring), the rest counted as skipped, and
    // passing is success
    output.clearRetainingCapacity();
    try testing.expectEqual(test_cmd.Outcome.success, try runWith(&.{ tree.dir, "--filter", "on" }, &output));
    try expectSays(output.written(), "  ok   one\n");
    try expectSilentOn(output.written(), "two");
    try expectSays(output.written(), "1 passed, 0 failed, 1 skipped in 1 file\n");
}

test "kupcad test: --format json tells each file's tests, with a failure's place" {
    var tree = try Tree.init();
    defer tree.deinit();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectEqual(test_cmd.Outcome.failure, try runWith(&.{ tree.dir, "--format", "json", "--filter", "o" }, &output));
    const Report = struct {
        passed: usize,
        failed: usize,
        skipped: usize,
        files: usize,
        files_failed: usize,
        results: []const struct {
            path: []const u8,
            ran: bool,
            tests: []const struct { name: []const u8, status: []const u8, failure: ?[]const u8, line: ?u32, column: ?u32 },
        },
    };
    const parsed = try std.json.parseFromSlice(Report, testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const report = parsed.value;
    try testing.expectEqual(@as(usize, 1), report.passed);
    try testing.expectEqual(@as(usize, 1), report.failed);
    try testing.expectEqual(@as(usize, 0), report.skipped);
    try testing.expectEqual(@as(usize, 1), report.files);
    try testing.expectEqual(@as(usize, 0), report.files_failed);
    try testing.expectEqual(@as(usize, 1), report.results.len);
    try testing.expect(std.mem.endsWith(u8, report.results[0].path, "bolt_test.kup"));
    try testing.expect(report.results[0].ran);
    const tests = report.results[0].tests;
    try testing.expectEqual(@as(usize, 2), tests.len);
    try testing.expectEqualStrings("one", tests[0].name);
    try testing.expectEqualStrings("passed", tests[0].status);
    try testing.expectEqual(@as(?[]const u8, null), tests[0].failure);
    try testing.expectEqualStrings("two", tests[1].name);
    try testing.expectEqualStrings("failed", tests[1].status);
    try testing.expect(std.mem.startsWith(u8, tests[1].failure.?, "AssertionError: expected 2, got 1\n"));
    try testing.expectEqual(@as(?u32, 8), tests[1].line);
    try testing.expectEqual(@as(?u32, 3), tests[1].column);
    // Nothing but the document on stdout
    try testing.expect(std.mem.startsWith(u8, output.written(), "{\n"));
}

test "kupcad test: --timeout ends a file that runs past it, as run's does" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "forever_test.kup", .data = "test(\"forever\") do\n" ++ test_support.PAST_ANY_TIME_LIMIT ++ "\nend\n" });
    const forever = try tree.path("forever_test.kup");
    defer testing.allocator.free(forever);
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectEqual(test_cmd.Outcome.failure, try runWith(&.{ forever, "--timeout", "100ms" }, &output));
    try expectSays(output.written(), "  FAIL forever: the run stopped inside it\n  FAIL the file didn't run\n");
    try testing.expectEqual(test_cmd.Outcome.failure, try runWith(&.{ forever, "--timeout", "soon" }, &output));
    try testing.expectEqual(test_cmd.Outcome.failure, try runWith(&.{ forever, "--format", "yaml" }, &output));
    try expectSays(output.written(), "Error: --format is text or json, not 'yaml'\n");
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
