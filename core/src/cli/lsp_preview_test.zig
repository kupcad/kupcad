//! The language server's preview in this process: the frame it gives of the document the
//! viewport shows, as the viewport reads it.

const std = @import("std");
const testing = std.testing;
const SessionPreview = @import("lsp_preview.zig").SessionPreview;
const preview_frame = @import("../preview/frame.zig");

/// What these tests read of a frame's header.
const Header = struct {
    kind: []const u8,
    @"error": ?struct { message: []const u8, line: ?u32, column: ?u32, param: ?[]const u8 },
    params: struct { values: std.json.Value },
};

const Read = struct { header: Header, bytes: []const u8, body: []const u8 };

/// The frame `preview` gives of `module_path`, owned and read by `arena`.
fn frameOf(arena: std.mem.Allocator, preview: *SessionPreview, module_path: []const u8) !Read {
    const bytes = switch (preview.evaluate(arena, module_path, true)) {
        .frame => |b| b,
        else => return error.TestExpectedFrame,
    };
    const parts = try preview_frame.split(bytes);
    const header = try std.json.parseFromSliceLeaky(Header, arena, parts.header, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    return .{ .header = header, .bytes = bytes, .body = parts.body };
}

test "LSP preview: a document's frame, made by its run and kept while nothing it reads changes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    try preview.update("part.kup", "w = param(:width, default: 2)\ncube(w)\n");

    const first = try frameOf(arena.allocator(), &preview, "part.kup");
    try testing.expectEqualStrings("3d", first.header.kind);
    try testing.expectEqualStrings("glTF", first.body[0..4]);
    try testing.expectEqual(@as(i64, 2), first.header.params.values.object.get("width").?.integer);
    // Not run again: the same frame, its timings and all
    const again = try frameOf(arena.allocator(), &preview, "part.kup");
    try testing.expectEqualSlices(u8, first.bytes, again.bytes);

    // A Sketch is shown as SVG
    try preview.update("part.kup", "square(4)\n");
    const flat = try frameOf(arena.allocator(), &preview, "part.kup");
    try testing.expectEqualStrings("2d", flat.header.kind);
    try testing.expect(std.mem.find(u8, flat.body, "<svg") != null);
}

test "LSP preview: no frame while no viewer watches, and the next one wanted runs the document again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    try preview.update("part.kup", "cube(2)\n");
    try testing.expectEqual(.nothing, std.meta.activeTag(preview.evaluate(arena.allocator(), "part.kup", false)));
    try testing.expectEqualStrings("3d", (try frameOf(arena.allocator(), &preview, "part.kup")).header.kind);
    // A document closed, that nothing imports, has none
    try preview.remove("part.kup");
    try testing.expectEqual(.nothing, std.meta.activeTag(preview.evaluate(arena.allocator(), "part.kup", true)));
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
    try testing.expectEqualStrings("none", syntax.kind);
    try testing.expect(std.mem.startsWith(u8, syntax.@"error".?.message, "lib.kup:"));
    // Its line would be the document's: the message says where in the import
    try testing.expect(syntax.@"error".?.line == null);

    try preview.update("lib.kup", "x = 1\nraise \"no side\"\nside = 2\nexport side\n");
    const raised = (try frameOf(arena.allocator(), &preview, "main.kup")).header;
    try testing.expect(std.mem.startsWith(u8, raised.@"error".?.message, "lib.kup:2:"));
    try testing.expect(std.mem.find(u8, raised.@"error".?.message, "no side") != null);

    // Fixed, the document runs with it
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
    try testing.expectEqual(.cancelled, std.meta.activeTag(preview.evaluate(arena.allocator(), "part.kup", true)));
    try testing.expect(preview.frame == null);
    preview.session.vm.cancel_token.store(false, .release);
    try testing.expectEqualStrings("3d", (try frameOf(arena.allocator(), &preview, "part.kup")).header.kind);
}
