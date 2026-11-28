//! `kupcad test`: runs the test blocks (`test "name" do ... end`, compiled only here:
//! compiler/compiler.zig's compileTestBlock) of the files named and of every file under
//! the directories named that holds one, each as `kupcad run` runs a script, and reports
//! how each test went from the run's report (vm/run_report.zig).

const std = @import("std");
const api = @import("../api.zig");
const build_cmd = @import("build_cmd.zig");
const walker = @import("walker.zig");
const ScriptSession = @import("../session/session.zig").ScriptSession;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const ScriptRoot = @import("script_root.zig").ScriptRoot;
const ScriptOptions = @import("script_options.zig").ScriptOptions;
const Args = @import("args.zig").Args;
pub const Outcome = @import("outcome.zig").Outcome;
const Reporter = @import("reporter.zig").Reporter;
const plural = @import("reporter.zig").plural;
const progress = @import("progress.zig");

pub const USAGE =
    \\Usage: kupcad test [<file|dir>...] [--filter <text>]
    \\
    \\Runs the test blocks (test "name" do ... end) of the files named, and of every .kup
    \\file under the directories named (the current one without any) that holds one, except
    \\in hidden directories (.kupcad's installed packages). A test fails by an assertion
    \\(assert, assert_equal, assert_near) or any other error in its body. Fails when a test
    \\does, when a file doesn't run, or when no file holds a test.
    \\
    \\Options:
    \\  --filter <text>  Run only the tests whose name contains <text>
    \\  -h, --help       Show this help
    \\
;

const FILTER_FLAG = "--filter";

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    return run(allocator, args_iter, .forProcess(init));
}

/// What the arguments ask: the paths (the current directory without any) and the filter.
const Options = struct {
    paths: std.ArrayList([]const u8) = .empty,
    filter: ?[]const u8 = null,

    fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
    }

    /// Null when an argument is wrong, reported.
    fn parse(allocator: std.mem.Allocator, args: anytype, reporter: Reporter) !?Options {
        var options: Options = .{};
        errdefer options.deinit(allocator);
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, FILTER_FLAG)) {
                options.filter = args.next() orelse {
                    reporter.err("Error: Missing value after '{s}'\n\n" ++ USAGE, .{FILTER_FLAG});
                    options.deinit(allocator);
                    return null;
                };
            } else if (std.mem.startsWith(u8, arg, "-")) {
                reporter.err("Error: Unknown option '{s}'\n\n" ++ USAGE, .{arg});
                options.deinit(allocator);
                return null;
            } else {
                try options.paths.append(allocator, arg);
            }
        }
        if (options.paths.items.len == 0) try options.paths.append(allocator, ".");
        return options;
    }
};

/// Runs `kupcad test` with the remaining CLI arguments (`next() ?[]const u8`).
pub fn run(allocator: std.mem.Allocator, args: anytype, reporter: Reporter) !Outcome {
    var options = try Options.parse(allocator, args, reporter) orelse return .failure;
    defer options.deinit(allocator);

    var found: Found = .{ .allocator = allocator };
    defer found.deinit();
    const unreadable = try walker.walkPaths(reporter, allocator, options.paths.items, &found, collectFile);

    var totals: Totals = .{ .files_failed = unreadable };
    for (found.files.items) |file| {
        // A file named outright runs whether or not it holds a test, as its author asked
        if (!file.has_tests and !isAmong(file.path, options.paths.items)) continue;
        try runFile(allocator, file.path, options.filter, reporter, &totals);
    }
    totals.report(reporter);
    return if (totals.failed()) .failure else .success;
}

/// A .kup file the walk found, and whether its top level holds a test block.
const File = struct { path: []u8, has_tests: bool };

const Found = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(File) = .empty,

    fn deinit(self: *Found) void {
        for (self.files.items) |file| self.allocator.free(file.path);
        self.files.deinit(self.allocator);
    }
};

/// walker's callback: notes the file and whether it holds a test block. A file that doesn't
/// parse counts as holding one: its run reports the syntax error, as a test file's must.
fn collectFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void {
    _ = io;
    const found: *Found = @ptrCast(@alignCast(context.?));
    const has_tests = if (api.Document.parse(allocator, source)) |parsed| blk: {
        var doc = parsed;
        defer doc.deinit();
        break :blk doc.diagnostics.len > 0 or api.hasTestBlocks(&doc.tree);
    } else |_| true;
    const path = try found.allocator.dupe(u8, file_path);
    errdefer found.allocator.free(path);
    try found.files.append(found.allocator, .{ .path = path, .has_tests = has_tests });
}

fn isAmong(path: []const u8, paths: []const []const u8) bool {
    for (paths) |given| if (std.mem.eql(u8, path, given)) return true;
    return false;
}

const Totals = struct {
    /// Files that held a test, or were named.
    files: usize = 0,
    /// Files that couldn't be read, or whose run stopped (a syntax error, an error outside
    /// any test, a time or memory limit).
    files_failed: usize = 0,
    passed: usize = 0,
    tests_failed: usize = 0,

    fn failed(self: Totals) bool {
        return self.files_failed > 0 or self.tests_failed > 0 or self.files == 0;
    }

    fn report(self: Totals, reporter: Reporter) void {
        if (self.files == 0 and self.files_failed == 0) {
            reporter.err("No tests found: no file holds a test \"name\" do ... end block\n", .{});
            return;
        }
        reporter.out("{d} passed, {d} failed in {d} {s}", .{ self.passed, self.tests_failed, self.files, plural(self.files, "file", "files") });
        if (self.files_failed > 0) reporter.out(", {d} {s} didn't run", .{ self.files_failed, plural(self.files_failed, "file", "files") });
        reporter.out("\n", .{});
    }
};

/// Runs the tests of the file at `path` and reports each, counting in `totals`.
fn runFile(allocator: std.mem.Allocator, path: []const u8, filter: ?[]const u8, reporter: Reporter, totals: *Totals) !void {
    totals.files += 1;
    var root = try ScriptRoot.open(reporter.io, allocator, path, reporter) orelse {
        totals.files_failed += 1;
        return;
    };
    defer root.deinit(reporter.io, allocator);
    var disk = NativeVfs.init(reporter.io, root.dir);
    var session = try ScriptSession.init(allocator, reporter.io, disk.vfs());
    defer session.deinit();
    session.tests_in = root.path;
    session.vm.test_filter = filter;
    var options: ScriptOptions = .{ .input_path = path };
    defer options.deinit(allocator);

    progress.start(reporter, "Testing {s}", .{std.fs.path.basename(path)});
    defer progress.stop();
    session.vm.progress = progress.core();
    const ran = try build_cmd.runScript(allocator, &session, &root, &options, null, reporter);
    progress.stop();

    reporter.out("{s}\n", .{path});
    for (session.vm.report.tests.items) |t| {
        switch (t.status) {
            .passed => {
                totals.passed += 1;
                reporter.out("  ok   {s}\n", .{t.name});
            },
            .failed => {
                totals.tests_failed += 1;
                reporter.out("  FAIL {s}\n", .{t.name});
                var lines = std.mem.splitScalar(u8, t.failure.?, '\n');
                while (lines.next()) |line| reporter.out("       {s}\n", .{line});
            },
            // The run stopped inside it: the stop was reported, and the file counts as failed
            .running => reporter.out("  FAIL {s}: the run stopped inside it\n", .{t.name}),
        }
    }
    if (!ran) {
        totals.files_failed += 1;
        reporter.out("  FAIL the file didn't run\n", .{});
    }
}
