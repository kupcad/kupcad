//! `kupcad test`: runs the test blocks (`test("name") do ... end`, compiled only here:
//! compiler/compiler.zig's compileTestBlock) of the files named and of every file under
//! the directories named that holds one, each as `kupcad run` runs a script, and reports
//! how each test went from the run's report (vm/run_report.zig), as text or as one JSON
//! document.

const std = @import("std");
const api = @import("../api.zig");
const build_cmd = @import("build_cmd.zig");
const walker = @import("walker.zig");
const memory_flag = @import("memory_flag.zig");
const time_flag = @import("time_flag.zig");
const ScriptSession = @import("../session/session.zig").ScriptSession;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const ScriptRoot = @import("script_root.zig").ScriptRoot;
const ScriptOptions = @import("script_options.zig").ScriptOptions;
const TestResult = @import("../vm/run_report.zig").TestResult;
const Args = @import("args.zig").Args;
pub const Outcome = @import("outcome.zig").Outcome;
const Reporter = @import("reporter.zig").Reporter;
const plural = @import("reporter.zig").plural;
const progress = @import("progress.zig");

pub const USAGE =
    \\Usage: kupcad test [<file|dir>...] [--filter <text>] [--format text|json]
    \\                   [--memory-limit <size>] [--timeout <time>]
    \\
    \\Runs the test blocks (test("name") do ... end) of the files named, and of every .kup
    \\file under the directories named (the current one without any) that holds one, except
    \\in hidden directories (.kupcad's installed packages). A test fails by an assertion
    \\(assert, assert_equal, assert_near) or any other error in its body. Fails when a test
    \\does, when a file doesn't run, or when no file holds a test.
    \\
    \\Options:
    \\  --filter <text>  Run only the tests whose name contains <text>; the rest are skipped
    \\  --format <kind>  text (the default), or json: one document on stdout with each file's
    \\                   tests, their status, and a failure's message, line and column
    \\
++ memory_flag.USAGE ++ time_flag.USAGE ++
    \\  -h, --help       Show this help
    \\
;

const FILTER_FLAG = "--filter";
const FORMAT_FLAG = "--format";

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    return run(allocator, args_iter, init.environ_map, .forProcess(init));
}

const Format = enum { text, json };

/// What the arguments ask: the paths (the current directory without any), the filter, the
/// format, and the limits (the flags, else the environment, else the project's own).
const Options = struct {
    paths: std.ArrayList([]const u8) = .empty,
    filter: ?[]const u8 = null,
    format: Format = .text,
    memory_limit: ?usize = null,
    timeout_ms: ?u64 = null,

    fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
    }

    /// Null when an argument is wrong, reported.
    fn parse(allocator: std.mem.Allocator, args: anytype, environ: *const std.process.Environ.Map, reporter: Reporter) !?Options {
        var options: Options = .{};
        errdefer options.deinit(allocator);
        while (args.next()) |arg| {
            switch (memory_flag.take(arg, args, &options.memory_limit, reporter)) {
                .taken => continue,
                .refused => return options.refuse(allocator),
                .other => {},
            }
            switch (time_flag.take(arg, args, &options.timeout_ms, reporter)) {
                .taken => continue,
                .refused => return options.refuse(allocator),
                .other => {},
            }
            if (std.mem.eql(u8, arg, FILTER_FLAG)) {
                options.filter = args.next() orelse return options.missingValue(allocator, reporter, FILTER_FLAG);
            } else if (std.mem.eql(u8, arg, FORMAT_FLAG)) {
                const name = args.next() orelse return options.missingValue(allocator, reporter, FORMAT_FLAG);
                options.format = std.meta.stringToEnum(Format, name) orelse {
                    reporter.err("Error: {s} is text or json, not '{s}'\n", .{ FORMAT_FLAG, name });
                    return options.refuse(allocator);
                };
            } else if (std.mem.startsWith(u8, arg, "-")) {
                reporter.err("Error: Unknown option '{s}'\n\n" ++ USAGE, .{arg});
                return options.refuse(allocator);
            } else {
                try options.paths.append(allocator, arg);
            }
        }
        if (options.paths.items.len == 0) try options.paths.append(allocator, ".");
        options.memory_limit = memory_flag.given(options.memory_limit, environ, reporter) catch return options.refuse(allocator);
        options.timeout_ms = time_flag.given(options.timeout_ms, environ, reporter) catch return options.refuse(allocator);
        return options;
    }

    fn missingValue(self: *Options, allocator: std.mem.Allocator, reporter: Reporter, flag: []const u8) ?Options {
        reporter.err("Error: Missing value after '{s}'\n\n" ++ USAGE, .{flag});
        return self.refuse(allocator);
    }

    fn refuse(self: *Options, allocator: std.mem.Allocator) ?Options {
        self.deinit(allocator);
        return null;
    }
};

/// Runs `kupcad test` with the remaining CLI arguments (`next() ?[]const u8`) in `environ`.
pub fn run(allocator: std.mem.Allocator, args: anytype, environ: *const std.process.Environ.Map, reporter: Reporter) !Outcome {
    var options = try Options.parse(allocator, args, environ, reporter) orelse return .failure;
    defer options.deinit(allocator);

    var found: Found = .{ .allocator = allocator };
    defer found.deinit();
    const unreadable = try walker.walkPaths(reporter, allocator, options.paths.items, &found, collectFile);

    var totals: Totals = .{ .files_failed = unreadable, .format = options.format, .reporter = reporter };
    defer totals.deinit();
    for (found.files.items) |file| {
        // A file named outright runs whether or not it holds a test, as its author asked
        if (!file.has_tests and !isAmong(file.path, options.paths.items)) continue;
        try runFile(allocator, file.path, &options, &totals);
    }
    try totals.report();
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

/// A test as the JSON document tells it.
const TestJson = struct {
    name: []const u8,
    status: []const u8,
    failure: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
};

/// A file as the JSON document tells it: whether its run went through, and its tests.
const FileJson = struct {
    path: []const u8,
    ran: bool,
    tests: []const TestJson,
};

const Totals = struct {
    format: Format,
    reporter: Reporter,
    /// Files that held a test, or were named.
    files: usize = 0,
    /// Files that couldn't be read, or whose run stopped (a syntax error, an error outside
    /// any test, a time or memory limit).
    files_failed: usize = 0,
    passed: usize = 0,
    tests_failed: usize = 0,
    skipped: usize = 0,
    /// For the json format: each file's results, copied (the session's go with the file).
    results: std.ArrayList(FileJson) = .empty,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

    fn deinit(self: *Totals) void {
        self.arena.deinit();
    }

    fn failed(self: Totals) bool {
        return self.files_failed > 0 or self.tests_failed > 0 or self.files == 0;
    }

    /// Counts and, for the json format, keeps the tests of the file at `path`.
    fn add(self: *Totals, path: []const u8, ran: bool, tests: []const TestResult) !void {
        self.files += 1;
        if (!ran) self.files_failed += 1;
        for (tests) |t| switch (t.status) {
            .passed => self.passed += 1,
            .failed => self.tests_failed += 1,
            .skipped => self.skipped += 1,
            .running => {},
        };
        if (self.format == .text) return self.printFile(path, ran, tests);
        const arena = self.arena.allocator();
        const copies = try arena.alloc(TestJson, tests.len);
        for (tests, copies) |t, *copy| copy.* = .{
            .name = try arena.dupe(u8, t.name),
            .status = if (t.status == .running) "stopped" else @tagName(t.status),
            .failure = if (t.failure) |f| try arena.dupe(u8, f) else null,
            .line = if (t.position) |p| p.line else null,
            .column = if (t.position) |p| p.column else null,
        };
        try self.results.append(arena, .{ .path = try arena.dupe(u8, path), .ran = ran, .tests = copies });
    }

    fn printFile(self: *Totals, path: []const u8, ran: bool, tests: []const TestResult) void {
        const reporter = self.reporter;
        reporter.out("{s}\n", .{path});
        for (tests) |t| switch (t.status) {
            .passed => reporter.out("  ok   {s}\n", .{t.name}),
            .skipped => {},
            .failed => {
                reporter.out("  FAIL {s}\n", .{t.name});
                var lines = std.mem.splitScalar(u8, t.failure.?, '\n');
                while (lines.next()) |line| reporter.out("       {s}\n", .{line});
            },
            // The run stopped inside it: the stop was reported, and the file counts as failed
            .running => reporter.out("  FAIL {s}: the run stopped inside it\n", .{t.name}),
        };
        if (!ran) reporter.out("  FAIL the file didn't run\n", .{});
    }

    fn report(self: *Totals) !void {
        const reporter = self.reporter;
        if (self.format == .json) {
            var buffer: std.Io.Writer.Allocating = .init(self.arena.allocator());
            try std.json.Stringify.value(.{
                .passed = self.passed,
                .failed = self.tests_failed,
                .skipped = self.skipped,
                .files = self.files,
                .files_failed = self.files_failed,
                .results = self.results.items,
            }, .{ .whitespace = .indent_2 }, &buffer.writer);
            reporter.out("{s}\n", .{buffer.written()});
            return;
        }
        if (self.files == 0 and self.files_failed == 0) {
            reporter.err("No tests found: no file holds a test(\"name\") do ... end block\n", .{});
            return;
        }
        reporter.out("{d} passed, {d} failed", .{ self.passed, self.tests_failed });
        if (self.skipped > 0) reporter.out(", {d} skipped", .{self.skipped});
        reporter.out(" in {d} {s}", .{ self.files, plural(self.files, "file", "files") });
        if (self.files_failed > 0) reporter.out(", {d} {s} didn't run", .{ self.files_failed, plural(self.files_failed, "file", "files") });
        reporter.out("\n", .{});
    }
};

/// Runs the tests of the file at `path` and reports each, counting in `totals`.
fn runFile(allocator: std.mem.Allocator, path: []const u8, options: *const Options, totals: *Totals) !void {
    const reporter = totals.reporter;
    var root = try ScriptRoot.open(reporter.io, allocator, path, reporter) orelse {
        return totals.add(path, false, &.{});
    };
    defer root.deinit(reporter.io, allocator);
    var disk = NativeVfs.init(reporter.io, root.dir);
    var session = try ScriptSession.init(allocator, reporter.io, disk.vfs());
    defer session.deinit();
    session.tests_in = root.path;
    session.vm.test_filter = options.filter;
    var script_options: ScriptOptions = .{ .input_path = path, .memory_limit = options.memory_limit, .timeout_ms = options.timeout_ms };
    defer script_options.deinit(allocator);

    progress.start(reporter, "Testing {s}", .{std.fs.path.basename(path)});
    defer progress.stop();
    session.vm.progress = progress.core();
    const ran = try build_cmd.runScript(allocator, &session, &root, &script_options, null, reporter);
    progress.stop();
    try totals.add(path, ran, session.vm.report.tests.items);
}
