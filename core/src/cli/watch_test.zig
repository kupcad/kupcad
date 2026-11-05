//! `kupcad watch`'s options: the file, `-p`/`-P` and the export options as `kupcad build`
//! takes them (watching a script with parameters, or writing what it builds, used to be
//! impossible), and what each watcher event prints and writes.

const std = @import("std");
const testing = std.testing;
const watch = @import("watch.zig");
const ScriptRoot = @import("script_root.zig").ScriptRoot;
const ScriptOptions = @import("script_options.zig").ScriptOptions;
const Args = @import("args.zig").Args;

/// The options `args` give `kupcad watch`, or null; `output` receives what was reported.
fn parse(args: []const []const u8, output: *std.Io.Writer.Allocating) !?ScriptOptions {
    var it: Args = .{ .items = args };
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    return ScriptOptions.parse(testing.allocator, &it, &environ, .{ .io = testing.io, .capture = &output.writer }, .when_given, watch.USAGE);
}

test "kupcad watch: takes the file and parameter values, as build does, the later one winning" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bracket.json", .data = "{\"width\": 40, \"label\": \"A\"}" });
    const params_path = try tmp.dir.realPathFileAlloc(testing.io, "bracket.json", testing.allocator);
    defer testing.allocator.free(params_path);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var options = (try parse(&.{ "-P", params_path, "model.kup", "-p", "width=50" }, &output)) orelse return error.TestRefused;
    defer options.deinit(testing.allocator);
    try testing.expectEqualStrings("model.kup", options.input_path);
    try testing.expectEqualStrings("50", options.params.map.get("width").?.string);
    // The file's other values stay
    try testing.expectEqualStrings("A", options.params.map.get("label").?.string);
}

test "kupcad watch: takes the limits build does" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var options = (try parse(&.{ "model.kup", "--timeout", "2s", "--memory-limit", "1GB" }, &output)) orelse return error.TestRefused;
    defer options.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 2000), options.timeout_ms);
    try testing.expectEqual(@as(?usize, 1024 * 1024 * 1024), options.memory_limit);
}

test "kupcad watch: options it can't take are refused, saying why" {
    const cases = [_]struct { args: []const []const u8, says: []const u8 }{
        .{ .args = &.{}, .says = "Error: Missing input file path." },
        .{ .args = &.{ "model.kup", "--bogus" }, .says = "Error: Unknown option '--bogus'" },
        .{ .args = &.{ "model.kup", "-o", "x.wrl" }, .says = "Error: Cannot infer the format from output path 'x.wrl'" },
        .{ .args = &.{ "model.kup", "--split", "parts", "-o", "x.stl" }, .says = "Error: --split writes a file per part into its directory; leave out -o" },
        .{ .args = &.{ "a.kup", "b.kup" }, .says = "Error: Expected one input file, got 'a.kup' and 'b.kup'" },
        .{ .args = &.{ "model.kup", "-p", "width" }, .says = "Error: Invalid param format. Use --param key=value." },
        .{ .args = &.{ "model.kup", "-P", "missing.json" }, .says = "Error: Could not read parameter file 'missing.json'" },
        .{ .args = &.{ "model.kup", "-P" }, .says = "Error: Missing parameter file after -P" },
        .{ .args = &.{ "model.kup", "--timeout", "0" }, .says = "Error: --timeout takes a time greater than zero" },
    };
    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        errdefer std.debug.print("reported: {s}\n", .{output.written()});
        try testing.expect(try parse(case.args, &output) == null);
        try testing.expect(std.mem.startsWith(u8, output.written(), case.says));
    }
}

test "kupcad watch: each watcher event is reported as build reports it" {
    const ScriptSession = @import("../session/session.zig").ScriptSession;
    const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();
    var session = try ScriptSession.init(testing.allocator, testing.io, .none);
    defer session.deinit();
    session.vm.vfs = mem.vfs();
    // A module that doesn't compile, for the failed event's diagnostics
    const bad = "f = ->(x) { break x }\ncube(1)";
    try mem.vfs().writeFile("model.kup", bad);
    _ = try session.workspace.addModule("model.kup", bad);
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();
    try testing.expectError(error.ParseError, session.evaluateWorkspace());

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var root = try ScriptRoot.of(testing.io, testing.allocator, "model.kup");
    defer root.deinit(testing.io, testing.allocator);
    var printer = watch.EventPrinter{ .allocator = testing.allocator, .session = &session, .root = &root, .reporter = .{ .io = testing.io, .capture = &output.writer } };
    const listener = printer.listener();
    const cases = [_]struct { event: @import("../session/watcher.zig").Event, says: []const u8 }{
        .{ .event = .{ .changed = "lib.kup" }, .says = "Changed: lib.kup\n" },
        .{ .event = .built, .says = "Built model.kup\n" },
        .{ .event = .{ .failed = error.RuntimeError }, .says = "Build failed: error.RuntimeError\n" },
        .{ .event = .{ .reload_failed = .{ .path = "lib.kup", .err = error.FileNotFound } }, .says = "Could not reload 'lib.kup': FileNotFound\n" },
        .{ .event = .{ .failed = error.ParseError }, .says = "Build failed: 1 error in model.kup\n" },
    };
    for (cases) |case| {
        errdefer std.debug.print("said: {s}\n", .{output.written()});
        output.clearRetainingCapacity();
        listener.onEvent(listener.ptr, case.event);
        try testing.expect(std.mem.endsWith(u8, output.written(), case.says));
    }
    // The failure names where it is
    listener.onEvent(listener.ptr, .{ .failed = error.ParseError });
    try testing.expect(std.mem.find(u8, output.written(), "Cannot use 'break' outside of a loop") != null);
}

test "kupcad watch: with --errors json, a failed build ends with the line build ends with" {
    // A compile error was told as a syntax one, and a run's failure not at all
    const ScriptSession = @import("../session/session.zig").ScriptSession;
    const cases = [_]struct { source: []const u8, err: anyerror, kind: []const u8, message: []const u8 }{
        .{ .source = "cube = 5\n", .err = error.CompileError, .kind = "compile", .message = "'cube' is a built-in and can't be assigned" },
        .{ .source = "x = cube(\n", .err = error.ParseError, .kind = "syntax", .message = "Invalid expression" },
        .{ .source = "x = undefined_var + 1\n", .err = error.RuntimeError, .kind = "runtime", .message = "NameError: Undefined variable 'undefined_var'" },
    };
    for (cases) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.source});
        var session = try ScriptSession.init(testing.allocator, testing.io, .none);
        defer session.deinit();
        session.vm.mute_errors = true;
        _ = try session.workspace.addModule("model.kup", case.source);
        try session.workspace.linkDependencies();
        try session.buildReverseGraph();
        try testing.expectError(case.err, session.evaluateWorkspace());

        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        var root = try ScriptRoot.of(testing.io, testing.allocator, "model.kup");
        defer root.deinit(testing.io, testing.allocator);
        var printer = watch.EventPrinter{ .allocator = testing.allocator, .session = &session, .root = &root, .reporter = .{ .io = testing.io, .capture = &output.writer, .errors = .json } };
        const listener = printer.listener();
        listener.onEvent(listener.ptr, .{ .failed = case.err });
        const text = std.mem.trimEnd(u8, output.written(), "\n");
        const last = text[(std.mem.lastIndexOfScalar(u8, text, '\n') orelse 0)..];
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, std.mem.trim(u8, last, "\n"), .{});
        defer parsed.deinit();
        const failure = parsed.value.object.get("error").?.object;
        try testing.expectEqualStrings(case.kind, failure.get("kind").?.string);
        try testing.expect(std.mem.find(u8, failure.get("message").?.string, case.message) != null);
    }
}

test "kupcad watch: with export options, each build that succeeds writes them; without, nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const stl = try std.fs.path.join(testing.allocator, &.{ dir, "model.stl" });
    defer testing.allocator.free(stl);
    const glb = try std.fs.path.join(testing.allocator, &.{ dir, "model.glb" });
    defer testing.allocator.free(glb);

    var reported: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reported.deinit();
    var options = (try parse(&.{ "model.kup", "-o", stl, "-o", glb }, &reported)) orelse return error.TestRefused;
    defer options.deinit(testing.allocator);
    try testing.expect(options.writes);
    var plain = (try parse(&.{"model.kup"}, &reported)) orelse return error.TestRefused;
    defer plain.deinit(testing.allocator);
    try testing.expect(!plain.writes);

    const ScriptSession = @import("../session/session.zig").ScriptSession;
    const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();
    var session = try ScriptSession.init(testing.allocator, testing.io, mem.vfs());
    defer session.deinit();
    try mem.vfs().writeFile("model.kup", "cube(2)");
    _ = try session.workspace.addModule("model.kup", "cube(2)");
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();
    try session.evaluateWorkspace();

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var root = try ScriptRoot.of(testing.io, testing.allocator, "model.kup");
    defer root.deinit(testing.io, testing.allocator);
    var printer = watch.EventPrinter{ .allocator = testing.allocator, .session = &session, .root = &root, .reporter = .{ .io = testing.io, .capture = &output.writer }, .exports = &options.exports };
    const listener = printer.listener();
    listener.onEvent(listener.ptr, .built);
    try testing.expect(std.mem.startsWith(u8, output.written(), "Built model.kup\nSuccessfully built "));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.written(), "Successfully built "));
    for ([_][]const u8{ "model.stl", "model.glb" }) |name| try tmp.dir.access(testing.io, name, .{});
}
