//! The language server's preview in this process: the frame it gives of the document the
//! viewport shows, as the viewport reads it.

const std = @import("std");
const testing = std.testing;
const lsp_preview = @import("lsp_preview.zig");
const SessionPreview = lsp_preview.SessionPreview;
const Target = lsp_preview.Target;
const ParamValues = @import("../core/param_values.zig").ParamValues;
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
