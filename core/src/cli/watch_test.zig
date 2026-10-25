//! `kupcad watch`'s options: the file, `-p`/`-P` and the export options as `kupcad build`
//! takes them (watching a script with parameters, or writing what it builds, used to be
//! impossible), and what each watcher event prints and writes.

const std = @import("std");
const testing = std.testing;
const watch = @import("watch.zig");
const ScriptRoot = @import("script_root.zig").ScriptRoot;
const Args = @import("args.zig").Args;

/// The options `args` give, or null; `output` receives what was reported.
fn parse(args: []const []const u8, output: *std.Io.Writer.Allocating) !?watch.Options {
    var it: Args = .{ .items = args };
    return watch.parseOptions(testing.allocator, &it, .{ .io = testing.io, .capture = &output.writer });
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
    try testing.expectEqualStrings("model.kup", options.file_path);
    try testing.expectEqualStrings("50", options.params.map.get("width").?.text);
    // The file's other values stay
    try testing.expectEqualStrings("A", options.params.map.get("label").?.text);
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
        .{ .event = .{ .run_failed = error.RuntimeError }, .says = "Build failed: RuntimeError\n" },
        .{ .event = .{ .reload_failed = .{ .path = "lib.kup", .err = error.FileNotFound } }, .says = "Could not reload 'lib.kup': FileNotFound\n" },
        .{ .event = .{ .failed = &session.failure.? }, .says = "Build failed: 1 error in model.kup\n" },
    };
    for (cases) |case| {
        errdefer std.debug.print("said: {s}\n", .{output.written()});
        output.clearRetainingCapacity();
        listener.onEvent(listener.ptr, case.event);
        try testing.expect(std.mem.endsWith(u8, output.written(), case.says));
    }
    // The failure names where it is
    listener.onEvent(listener.ptr, .{ .failed = &session.failure.? });
    try testing.expect(std.mem.find(u8, output.written(), "Cannot use 'break' outside of a loop") != null);
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
