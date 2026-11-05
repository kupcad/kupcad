//! The language server's preview in this process: the frame it gives of the document the
//! viewport shows, as the viewport reads it.

const std = @import("std");
const testing = std.testing;
const lsp_preview = @import("lsp_preview.zig");
const SessionPreview = lsp_preview.SessionPreview;
const Target = lsp_preview.Target;
const ParamValues = @import("../core/param_values.zig").ParamValues;
const limits = @import("../core/limits.zig");
const test_support = @import("../test_support.zig");

const Read = struct { header: test_support.FrameHeader, bytes: []const u8, body: []const u8 };

/// The document at `module_path`, as an editor opens it from the folder /work.
fn target(comptime module_path: []const u8) Target {
    return .{ .module_path = module_path, .uri = "file:///work/" ++ module_path };
}

/// The frame `preview` gives of the document at `module_path`, owned and read by `arena`.
fn frameOf(arena: std.mem.Allocator, preview: *SessionPreview, comptime module_path: []const u8) !Read {
    return frameFor(arena, preview, target(module_path));
}

fn frameFor(arena: std.mem.Allocator, preview: *SessionPreview, of: Target) !Read {
    const bytes = switch (preview.evaluate(arena, of, .any)) {
        .frame => |b| b,
        else => return error.TestExpectedFrame,
    };
    const read = try test_support.readFrame(arena, bytes);
    return .{ .header = read.header, .bytes = bytes, .body = read.body };
}

test "LSP preview: a document's frame, made by its run and kept while nothing it reads changes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    try preview.update("part.kup", "w = param(:width, default: 2)\ncube(w)\n");

    const first = try frameOf(arena.allocator(), &preview, "part.kup");
    try testing.expectEqualStrings("file:///work/part.kup", first.header.document.?);
    try testing.expectEqualStrings("3d", first.header.kind);
    try testing.expectEqualStrings("glTF", first.body[0..4]);
    try testing.expectEqual(@as(i64, 2), first.header.params.values.object.get("width").?.integer);
    // Not run again: the same frame, its timings and all
    const again = try frameOf(arena.allocator(), &preview, "part.kup");
    try testing.expectEqualSlices(u8, first.bytes, again.bytes);
    // Under another name, the frame is that name's
    const renamed = try frameFor(arena.allocator(), &preview, .{ .module_path = "part.kup", .uri = "untitled:Untitled-1" });
    try testing.expectEqualStrings("untitled:Untitled-1", renamed.header.document.?);

    // A Sketch is shown as SVG
    try preview.update("part.kup", "square(4)\n");
    const flat = try frameOf(arena.allocator(), &preview, "part.kup");
    try testing.expectEqualStrings("2d", flat.header.kind);
    try testing.expect(std.mem.find(u8, flat.body, "<svg") != null);
}

test "LSP preview: a frame given isn't given again for viewers that have it, unless asked for" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    try preview.update("part.kup", "cube(2)\n");
    const first = preview.evaluate(a, target("part.kup"), .new).frame;
    try testing.expectEqual(.unchanged, std.meta.activeTag(preview.evaluate(a, target("part.kup"), .new)));
    // A viewer asked for it
    try testing.expectEqualSlices(u8, first, preview.evaluate(a, target("part.kup"), .any).frame);
    try preview.update("part.kup", "cube(3)\n");
    try testing.expectEqual(.frame, std.meta.activeTag(preview.evaluate(a, target("part.kup"), .new)));
}

test "LSP preview: no frame while no viewer watches, and the next one wanted runs the document again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    try preview.update("part.kup", "cube(2)\n");
    try testing.expectEqual(.nothing, std.meta.activeTag(preview.evaluate(arena.allocator(), target("part.kup"), .none)));
    try testing.expectEqualStrings("3d", (try frameOf(arena.allocator(), &preview, "part.kup")).header.kind);
    // A document closed, that nothing imports, has none
    try preview.remove("part.kup");
    try testing.expectEqual(.nothing, std.meta.activeTag(preview.evaluate(arena.allocator(), target("part.kup"), .any)));
}

test "LSP preview: a closed document isn't evaluated, and its values (none now) change nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    try preview.update("part.kup", "w = param(:w, default: 1)\ncube(w)\n");
    try setParams(&preview, "part.kup", "{\"w\": 3}");
    _ = try frameOf(arena.allocator(), &preview, "part.kup");
    try preview.remove("part.kup");
    const revision = preview.session.global_revision;
    try testing.expectEqual(.nothing, std.meta.activeTag(preview.evaluate(arena.allocator(), target("part.kup"), .any)));
    // Its values given to the session first made every module run again
    try testing.expectEqual(revision, preview.session.global_revision);
}

test "LSP preview: a document that doesn't parse, compile or run says why, and where, in its frame" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    preview.session.vm.mute_errors = true; // the run's error would print to the test log

    try preview.update("part.kup", "x = 1\ncube(\n");
    const syntax = (try frameOf(arena.allocator(), &preview, "part.kup")).header;
    try testing.expectEqualStrings("none", syntax.kind);
    try testing.expect(syntax.@"error".?.line.? >= 2);

    try preview.update("part.kup", "x = 1\ncube = 5\n");
    const compile = (try frameOf(arena.allocator(), &preview, "part.kup")).header;
    try testing.expectEqual(@as(?u32, 2), compile.@"error".?.line);

    try preview.update("part.kup", "w = param(:width, default: 20, validate: { min: 10 })\nraise \"too thin\" if w < 30\ncube(w)\n");
    const raised = (try frameOf(arena.allocator(), &preview, "part.kup")).header;
    try testing.expectEqualStrings("none", raised.kind);
    try testing.expectEqual(@as(?u32, 2), raised.@"error".?.line);
    try testing.expect(std.mem.find(u8, raised.@"error".?.message, "too thin") != null);
    try testing.expect(raised.@"error".?.param == null);

    // The run ends, and showing its model raises in the VM; the session goes on from there
    try preview.update("part.kup", "[cube(1), 5]\n");
    const refused = (try frameOf(arena.allocator(), &preview, "part.kup")).header;
    try testing.expect(std.mem.startsWith(u8, refused.@"error".?.message, "TypeError"));
    try preview.update("part.kup", "cube(1)\n");
    try testing.expectEqualStrings("3d", (try frameOf(arena.allocator(), &preview, "part.kup")).header.kind);
}

test "LSP preview: a module the document imports that fails is named in its frame" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    preview.session.vm.mute_errors = true; // the import's error would print to the test log

    try preview.update("lib.kup", "x = 1\nside = (\n");
    try preview.update("main.kup", "import { side } from \"./lib.kup\"\ncube(side)\n");
    const syntax = (try frameOf(arena.allocator(), &preview, "main.kup")).header;
    try testing.expectEqualStrings("file:///work/main.kup", syntax.document.?);
    try testing.expectEqualStrings("none", syntax.kind);
    try testing.expect(std.mem.startsWith(u8, syntax.@"error".?.message, "lib.kup:"));
    // Its line would be the document's: the message says where in the import
    try testing.expect(syntax.@"error".?.line == null);

    try preview.update("lib.kup", "x = 1\nraise \"no side\"\nside = 2\nexport side\n");
    const raised = (try frameOf(arena.allocator(), &preview, "main.kup")).header;
    try testing.expect(std.mem.startsWith(u8, raised.@"error".?.message, "lib.kup:2:"));
    try testing.expect(std.mem.find(u8, raised.@"error".?.message, "no side") != null);

    // It runs, and its model, built after the run, fails: the engines don't mix
    try preview.update("lib.kup", "part = cube(10).decompose[0]\nCAD.config(engine: :brep)\nside = 2\nexport side\npart + cube(1)\n");
    const unbuilt = (try frameOf(arena.allocator(), &preview, "main.kup")).header;
    try testing.expect(std.mem.startsWith(u8, unbuilt.@"error".?.message, "lib.kup"));
    try testing.expect(std.mem.find(u8, unbuilt.@"error".?.message, "can't combine manifold and brep") != null);

    // Fixed, the document runs with it, and with the default engine: the import's
    // CAD.config was its last run's
    try preview.update("lib.kup", "side = 2\nexport side\n");
    try testing.expectEqualStrings("3d", (try frameOf(arena.allocator(), &preview, "main.kup")).header.kind);
}

test "LSP preview: a document broken, then put back as it was, is given its frame again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    preview.session.vm.mute_errors = true; // the runs' errors would print to the test log

    // The viewers have each frame given: put back, the document's isn't the frame they have
    const good = "cube(2)\n";
    try preview.update("part.kup", good);
    _ = preview.evaluate(a, target("part.kup"), .new).frame;
    for ([_][]const u8{ "cube(\n", "cube(2).ds\n" }) |broken| {
        try preview.update("part.kup", broken);
        const failed = try test_support.readFrame(a, preview.evaluate(a, target("part.kup"), .new).frame);
        try testing.expectEqualStrings("none", failed.header.kind);
        try preview.update("part.kup", good);
        const fixed = try test_support.readFrame(a, preview.evaluate(a, target("part.kup"), .new).frame);
        try testing.expectEqualStrings("3d", fixed.header.kind);
    }

    // So with a module it imports: the document doesn't run again, its output the same
    const lib = "side = 2\nexport side\n";
    try preview.update("lib.kup", lib);
    try preview.update("main.kup", "import { side } from \"./lib.kup\"\ncube(side)\n");
    _ = preview.evaluate(a, target("main.kup"), .new).frame;
    for ([_][]const u8{ "side = (\n", "raise \"no side\"\n" }) |broken| {
        try preview.update("lib.kup", broken);
        const failed = try test_support.readFrame(a, preview.evaluate(a, target("main.kup"), .new).frame);
        try testing.expectEqualStrings("none", failed.header.kind);
        try preview.update("lib.kup", lib);
        const fixed = try test_support.readFrame(a, preview.evaluate(a, target("main.kup"), .new).frame);
        try testing.expectEqualStrings("3d", fixed.header.kind);
    }
}

test "LSP preview: a run a message stopped leaves no frame, and the next run makes it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    preview.session.vm.mute_errors = true; // the stopped run's error would print to the test log
    try preview.update("part.kup", "cube(2)\n");

    // As the inbox does when a message arrives during the run
    preview.session.vm.cancel_token.store(true, .release);
    try testing.expectEqual(.cancelled, std.meta.activeTag(preview.evaluate(arena.allocator(), target("part.kup"), .any)));
    try testing.expect(preview.frame == null);
    preview.session.vm.cancel_token.store(false, .release);
    try testing.expectEqualStrings("3d", (try frameOf(arena.allocator(), &preview, "part.kup")).header.kind);
}

/// Gives the document at `module_path` the values of the JSON object `json`.
fn setParams(preview: *SessionPreview, module_path: []const u8, json: []const u8) !void {
    var values: ParamValues = .{};
    defer values.deinit(testing.allocator);
    var why: ?[]u8 = null;
    try values.putJson(testing.allocator, json, &why);
    try preview.setParams(module_path, &values);
}

test "LSP preview: each document runs with its own values, and a refused one is named in its frame" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    preview.session.vm.mute_errors = true; // the refused value's error would print to the test log
    try preview.update("a.kup", "cube(param(:w, default: 2, validate: { min: 1 }))\n");
    try preview.update("b.kup", "square(param(:w, default: 1))\n");

    try setParams(&preview, "a.kup", "{\"w\": 3}");
    try testing.expectEqual(@as(i64, 3), (try frameOf(arena.allocator(), &preview, "a.kup")).header.params.values.object.get("w").?.integer);
    // The session runs b.kup with its own (none), and a.kup with its values again after it
    try testing.expectEqual(@as(i64, 1), (try frameOf(arena.allocator(), &preview, "b.kup")).header.params.values.object.get("w").?.integer);
    try testing.expectEqual(@as(i64, 3), (try frameOf(arena.allocator(), &preview, "a.kup")).header.params.values.object.get("w").?.integer);

    try setParams(&preview, "a.kup", "{\"w\": 0}");
    const refused = (try frameOf(arena.allocator(), &preview, "a.kup")).header;
    try testing.expectEqualStrings("w", refused.@"error".?.param.?);

    // A document closed forgets its values
    try preview.remove("a.kup");
    try preview.update("a.kup", "cube(param(:w, default: 2, validate: { min: 1 }))\n");
    try testing.expectEqual(@as(i64, 2), (try frameOf(arena.allocator(), &preview, "a.kup")).header.params.values.object.get("w").?.integer);
}

test "LSP preview: a frame's values are its document's own parameters, the same whether its imports ran or came from the cache" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    try preview.update("lib.kup", "side = param(:t, default: 3)\nexport side\n");

    // The first run imports lib.kup afresh; main.kup edited, the second from the VM's cache
    const main_source = "import { side } from \"./lib.kup\"\ncube(param(:w, default: 2) + side)\n";
    for ([_][]const u8{ main_source, main_source ++ "\n" }) |source| {
        try preview.update("main.kup", source);
        const values = (try frameOf(arena.allocator(), &preview, "main.kup")).header.params.values.object;
        try testing.expectEqual(@as(usize, 1), values.count());
        try testing.expectEqual(@as(i64, 2), values.get("w").?.integer);
    }
}

test "LSP preview: a frame gives a list's and a Map's values as JSON, and leaves out one with none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    try preview.update("part.kup", "xs = param(:xs, default: [[1, :a], [2, :b]])\ncut = param(:cut, default: { depth: 5 })\nkey = param(:key, title: \"Key\")\ncube(1)\n");

    var json: std.Io.Writer.Allocating = .init(arena.allocator());
    const taken = (try frameOf(arena.allocator(), &preview, "part.kup")).header.params.values;
    try json.writer.print("{f}", .{std.json.fmt(taken, .{})});
    try testing.expectEqualStrings("{\"xs\":[[1,\"a\"],[2,\"b\"]],\"cut\":{\"depth\":5}}", json.written());

    // A host's, as the panel gives them
    try setParams(&preview, "part.kup", "{\"xs\": [[5, \"c\"]], \"cut\": {\"depth\": 6}, \"key\": \"k\"}");
    json.clearRetainingCapacity();
    try json.writer.print("{f}", .{std.json.fmt((try frameOf(arena.allocator(), &preview, "part.kup")).header.params.values, .{})});
    try testing.expectEqualStrings("{\"xs\":[[5,\"c\"]],\"cut\":{\"depth\":6},\"key\":\"k\"}", json.written());
}

test "LSP preview: the frame kept of a module is dropped when it runs again as another's import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    preview.session.vm.mute_errors = true; // main.kup's compile error would print to the test log
    try preview.update("lib.kup", "side = param(:t, default: 1)\nexport side\ncube(side)\n");
    try testing.expectEqual(@as(i64, 1), (try frameOf(arena.allocator(), &preview, "lib.kup")).header.params.values.object.get("t").?.integer);

    // lib.kup runs, edited, for main.kup, which then doesn't compile: no frame of main.kup
    // takes the place of lib.kup's, and lib.kup is up to date when it is shown again
    try preview.update("lib.kup", "side = param(:t, default: 2)\nexport side\ncube(side)\n");
    try preview.update("main.kup", "import { side } from \"./lib.kup\"\ncube = 5\n");
    try testing.expect((try frameOf(arena.allocator(), &preview, "main.kup")).header.@"error" != null);
    try testing.expectEqual(@as(i64, 2), (try frameOf(arena.allocator(), &preview, "lib.kup")).header.params.values.object.get("t").?.integer);
}

test "LSP preview: each run's warnings are its own, the same on every run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    preview.session.vm.mute_errors = true; // the engine's warning would print to the test log
    const source = "CAD.config(engine: :brep)\npart = cube(1)\npart.material(color: \"#cc3333\")\n";
    // The second run, edited, finds the Solid built by the first in the result cache
    for ([_][]const u8{ source, source ++ "\n" }) |edited| {
        try preview.update("part.kup", edited);
        const warnings = (try frameOf(arena.allocator(), &preview, "part.kup")).header.warnings;
        try testing.expectEqual(@as(usize, 1), warnings.len);
        try testing.expectEqual(@as(?u32, 3), warnings[0].line);
    }
}

/// The paths of the modules `warnings` are of, sorted.
fn pathsOf(arena: std.mem.Allocator, warnings: []const lsp_preview.ModuleWarnings) ![]const []const u8 {
    const paths = try arena.alloc([]const u8, warnings.len);
    for (paths, warnings) |*path, module| path.* = module.module_path;
    std.mem.sortUnstable([]const u8, paths, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return paths;
}

test "LSP preview: the warnings taken are those of the modules that ran since, a stopped evaluation's runs too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    preview.session.vm.mute_errors = true; // the engine's warning would print to the test log
    try preview.update("lib.kup", "CAD.config(engine: :brep)\nshade = cube(1).material(color: \"#cc3333\")\nexport shade\n");
    try preview.update("main.kup", "import { shade } from \"./lib.kup\"\nshade\n");
    try preview.update("other.kup", "cube(1)\n");
    _ = try frameOf(a, &preview, "main.kup");
    const first = try preview.takeRunWarnings(a);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "lib.kup", "main.kup" }), try pathsOf(a, first));
    try testing.expectEqual(@as(?u32, 2), for (first) |module| {
        if (std.mem.eql(u8, module.module_path, "lib.kup")) break module.warnings[0].line;
    } else null);
    // Taken: none ran since
    try testing.expectEqual(@as(usize, 0), (try preview.takeRunWarnings(a)).len);

    // lib.kup edited, another document evaluated: lib.kup didn't run, and its last run's
    // warning (on a line that moved) isn't given again
    try preview.update("lib.kup", "\nCAD.config(engine: :brep)\nshade = cube(1).material(color: \"#cc3333\")\nexport shade\n");
    _ = try frameOf(a, &preview, "other.kup");
    try testing.expectEqualDeep(@as([]const []const u8, &.{"other.kup"}), try pathsOf(a, try preview.takeRunWarnings(a)));

    // Two evaluations before the warnings are taken (the first stopped by a message, whose
    // runs the server doesn't ask about): the runs of both are given
    try preview.update("other.kup", "cube(2)\n");
    _ = try frameOf(a, &preview, "main.kup");
    _ = try frameOf(a, &preview, "other.kup");
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "lib.kup", "main.kup", "other.kup" }), try pathsOf(a, try preview.takeRunWarnings(a)));
}

test "LSP preview: the files on disk are read once a workspace folder is named, and the working directory's never" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, true);
    defer preview.deinit();
    preview.session.vm.mute_errors = true; // the run's error would print to the test log
    // A data file the working directory reaches, as a hostile script opened alone would hope:
    // in a folder of the test's own, which the workspace folder holds at the same path
    var here = testing.tmpDir(.{});
    defer here.cleanup();
    try here.dir.writeFile(testing.io, .{ .sub_path = "size.json", .data = "{\"w\": 3}" });
    const data = try std.mem.join(a, "/", &.{ ".zig-cache", "tmp", &here.sub_path, "size.json" });
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, std.fs.path.dirname(data).?);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = data, .data = "{\"w\": 2}" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    try preview.update("part.kup", try std.fmt.allocPrint(a, "cube(import_json(\"{s}\")[:w])\n", .{data}));
    const alone = try frameOf(a, &preview, "part.kup");
    try testing.expectEqualStrings("none", alone.header.kind);
    try testing.expect(std.mem.find(u8, alone.header.@"error".?.message, "size.json") != null);
    // The folder named, its file is read (the failed run runs again)
    try preview.setRoot(root);
    const named = try frameOf(a, &preview, "part.kup");
    try testing.expectEqualStrings("3d", named.header.kind);
}

test "LSP preview: a module an import couldn't read is watched, and made, runs with its importer" {
    // fileChanged ignored a path it didn't know, so creating the module (or installing its
    // package) never ran the document again
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, true);
    defer preview.deinit();
    preview.session.vm.mute_errors = true;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try preview.setRoot(root);

    try preview.update("main.kup", "import { side } from \"./lib.kup\"\ncube(side)\n");
    try testing.expectEqualStrings("none", (try frameOf(a, &preview, "main.kup")).header.kind);
    const watched = try preview.filesRead(testing.allocator);
    defer lsp_preview.freeFiles(testing.allocator, watched);
    try testing.expectEqual(@as(usize, 1), watched.len);
    try testing.expectEqualStrings("lib.kup", watched[0]);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.kup", .data = "side = 3\nexport side\n" });
    try testing.expect(try preview.fileChanged("lib.kup"));
    try testing.expectEqualStrings("3d", (try frameOf(a, &preview, "main.kup")).header.kind);
}

test "LSP preview: a document opened from outside the workspace imports its neighbours, and nothing past its project" {
    // Its module path is absolute, which the workspace folder's files refused: its imports
    // failed, with no workspace folder named too
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, true);
    defer preview.deinit();
    preview.session.vm.mute_errors = true;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "proj/parts");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/kupcad.json", .data = "{}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/lib.kup", .data = "side = 3\nexport side\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "secret.kup", .data = "side = 9\nexport side\n" });
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    // As the server takes it from the document's URI: `/` between its folders, Windows' too
    std.mem.replaceScalar(u8, base, '\\', '/');
    const main = try std.mem.join(a, "/", &.{ base, "proj", "parts", "main.kup" });
    const uri = try std.fmt.allocPrint(a, "file://{s}", .{main});

    try preview.update(main, "import { side } from \"../lib.kup\"\ncube(side)\n");
    const imported = try frameFor(a, &preview, .{ .module_path = main, .uri = uri });
    try testing.expectEqualStrings("3d", imported.header.kind);
    // Past the project: no folder of its own grants it
    try preview.update(main, "import { side } from \"../../secret.kup\"\ncube(side)\n");
    const past = try frameFor(a, &preview, .{ .module_path = main, .uri = uri });
    try testing.expectEqualStrings("none", past.header.kind);
    try testing.expect(std.mem.find(u8, past.header.@"error".?.message, "secret.kup") != null);
}

test "LSP preview: a part named in a library has its source there, from the import cache too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    try preview.update("lib.kup", "x = 1\nlid = cube(1).named(\"lid\")\ndef make\n  cube(2).named(\"box\")\nend\nexport lid, make\n");
    const main = "import { lid, make } from \"./lib.kup\"\n[lid, make().translate(x: 5)]\n";
    // The second run imports the library from the cache: its top level doesn't run again
    for ([_][]const u8{ main, main ++ "\n" }) |edited| {
        try preview.update("main.kup", edited);
        const parts = (try frameOf(a, &preview, "main.kup")).header.parts;
        try testing.expectEqual(@as(usize, 2), parts.len);
        for (parts) |part| {
            const at = part.source orelse return error.TestExpectedSource;
            try testing.expectEqualStrings("lib.kup", at.file.?);
            try testing.expectEqual(@as(u32, if (std.mem.eql(u8, part.name, "lid")) 2 else 4), at.line);
        }
    }
}

test "LSP preview: a host's memory limit stands in for the interactive one, for runs and hovers" {
    // `kupcad lsp --memory-limit` (the desktop app's and the VS Code extension's setting): a
    // model the host exports, under the same limit, previews too
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const heavy = "a = []\n2000.times { |i| a.push(\"item number #{i}\") }\ncube(1)\n";
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    try preview.update("part.kup", heavy);
    try testing.expectEqual(null, (try frameOf(arena.allocator(), &preview, "part.kup")).header.@"error");

    preview.limitMemory(64 * 1024);
    try preview.update("part.kup", heavy ++ "\n");
    const refused = (try frameOf(arena.allocator(), &preview, "part.kup")).header.@"error" orelse return error.TestExpectedError;
    try testing.expect(std.mem.find(u8, refused.message, "memory") != null);
    try testing.expectEqual(@as(usize, 64 * 1024), preview.memoryLimitOf("part.kup")); // a hover's run's too
}

test "LSP preview: a project's vm_memory_limit holds without the host's, which wins over it, as in an export" {
    // Read from the .kupcad.json nearest each script on disk, as `kupcad build` reads it, so a
    // preview stops where the export would
    const warnings = test_support.expectWarnings(); // the broken settings are logged
    defer warnings.restore();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gb: usize = 1024 * 1024 * 1024;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "small");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "small/.kupcad.json", .data = "{\"vm_memory_limit\": 65536}" });
    try tmp.dir.createDirPath(testing.io, "large");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "large/.kupcad.json", .data = "{\"vm_memory_limit\": 1099511627776}" });
    try tmp.dir.createDirPath(testing.io, "broken");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken/.kupcad.json", .data = "{" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, true);
    defer preview.deinit();
    preview.session.vm.mute_errors = true;
    // Before a folder is named a relative path has no project
    try testing.expectEqual(limits.INTERACTIVE_MEMORY_LIMIT, preview.memoryLimitOf("small/part.kup"));
    try preview.setRoot(root);

    // Without the host's limit: the project's, else the interactive one (settings that don't
    // read too, as the editor's others)
    try testing.expectEqual(@as(usize, 65536), preview.memoryLimitOf("small/part.kup"));
    try testing.expectEqual(@as(usize, 1024 * gb), preview.memoryLimitOf("large/part.kup"));
    try testing.expectEqual(limits.INTERACTIVE_MEMORY_LIMIT, preview.memoryLimitOf("part.kup"));
    try testing.expectEqual(limits.INTERACTIVE_MEMORY_LIMIT, preview.memoryLimitOf("broken/part.kup"));
    // A document from outside the workspace, by its absolute path, gets its own project's
    const outside = try std.fs.path.join(a, &.{ root, "small", "part.kup" });
    try testing.expectEqual(@as(usize, 65536), preview.memoryLimitOf(outside));
    // A run of the small project's script stops at its limit
    const heavy = "a = []\n2000.times { |i| a.push(\"item number #{i}\") }\ncube(1)\n";
    try preview.update("small/part.kup", heavy);
    const refused = (try frameOf(a, &preview, "small/part.kup")).header.@"error" orelse return error.TestExpectedError;
    try testing.expect(std.mem.find(u8, refused.message, "65536") != null);

    // The host's wins, lower or higher: a cloned project can't lift it, and a setting raised
    // takes, so the same script runs
    preview.limitMemory(8 * gb);
    for ([_][]const u8{ "small/part.kup", "large/part.kup", "part.kup", outside }) |path| {
        try testing.expectEqual(@as(usize, 8 * gb), preview.memoryLimitOf(path));
    }
    try preview.update("small/part.kup", heavy ++ "\n");
    try testing.expectEqual(null, (try frameOf(a, &preview, "small/part.kup")).header.@"error");
}
