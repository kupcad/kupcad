const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const lsp_worker = @import("lsp_worker.zig");
const SessionPreview = @import("lsp_preview.zig").SessionPreview;
const ast = @import("../core/ast.zig");

fn u32Bytes(n: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, n, .little);
    return b;
}

test "lsp worker: a frame reads back as it was written" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try lsp_worker.writeFrame(&out.writer, .update, &.{ "ab", "", "cde" });
    try lsp_worker.writeFrame(&out.writer, .cancel, &.{});
    var in: std.Io.Reader = .fixed(out.written());
    const first = try lsp_worker.readFrame(&in, testing.allocator);
    defer testing.allocator.free(first.payload);
    try testing.expectEqual(lsp_worker.Kind.update, first.kind);
    try testing.expectEqualStrings("abcde", first.payload);
    const second = try lsp_worker.readFrame(&in, testing.allocator);
    defer testing.allocator.free(second.payload);
    try testing.expectEqual(lsp_worker.Kind.cancel, second.kind);
    try testing.expectEqual(@as(usize, 0), second.payload.len);
    try testing.expectError(error.EndOfStream, lsp_worker.readFrame(&in, testing.allocator));
}

test "lsp worker: serve answers updates, an evaluation, a hover and a removal in order" {
    const path = "part.kup";
    const source = "a = cube(2)\n";
    var requests: std.Io.Writer.Allocating = .init(testing.allocator);
    defer requests.deinit();
    try lsp_worker.writeFrame(&requests.writer, .update, &.{ &u32Bytes(path.len), path, source });
    try lsp_worker.writeFrame(&requests.writer, .evaluate, &.{ &.{1}, path });
    // The assignment's node: the hover is about `a`.
    var doc = try @import("../api.zig").Document.parse(testing.allocator, source);
    defer doc.deinit();
    const stmts = doc.tree.getNodes(doc.tree.block(doc.tree.getNode(doc.tree.root).?).stmts);
    try lsp_worker.writeFrame(&requests.writer, .hover, &.{ &u32Bytes(4), &u32Bytes(@backingInt(stmts[0])), path });
    try lsp_worker.writeFrame(&requests.writer, .remove, &.{path});

    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    var in: std.Io.Reader = .fixed(requests.written());
    var replies: std.Io.Writer.Allocating = .init(testing.allocator);
    defer replies.deinit();
    try lsp_worker.serve(testing.io, testing.allocator, &preview, &in, &replies.writer);

    var out: std.Io.Reader = .fixed(replies.written());
    const updated = try lsp_worker.readFrame(&out, testing.allocator);
    defer testing.allocator.free(updated.payload);
    try testing.expectEqualSlices(u8, &.{0}, updated.payload);
    const evaluated = try lsp_worker.readFrame(&out, testing.allocator);
    defer testing.allocator.free(evaluated.payload);
    try testing.expectEqual(@as(u8, 0), evaluated.payload[0]); // mesh
    try testing.expectEqualStrings("glTF", evaluated.payload[1..5]);
    const hovered = try lsp_worker.readFrame(&out, testing.allocator);
    defer testing.allocator.free(hovered.payload);
    try testing.expectEqual(@as(u8, 1), hovered.payload[0]);
    try testing.expect(std.mem.indexOf(u8, hovered.payload, "**Volume:** `8.00`") != null);
    const removed = try lsp_worker.readFrame(&out, testing.allocator);
    defer testing.allocator.free(removed.payload);
    try testing.expectEqualSlices(u8, &.{0}, removed.payload);
    try testing.expectEqual(@as(usize, 0), preview.session.workspace.modules.items.len);
}

test "lsp worker: a worker that dies is a crash for the preview, and the next use starts another" {
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    @import("../test_support.zig").expectWarnings(); // the worker's end is logged as one
    // A stand-in that ends at once, as one that crashed on its first request would.
    const argv = [_][]const u8{ "/bin/sh", "-c", "exit 3" };
    var worker = lsp_worker.WorkerPreview.init(testing.allocator, testing.io, &argv);
    defer worker.deinit();
    const preview = worker.preview();
    try preview.update("part.kup", "cube(1)\n");
    for (0..2) |_| {
        try testing.expectEqual(std.meta.Tag(@import("lsp_preview.zig").Outcome).crashed, std.meta.activeTag(preview.evaluate(testing.allocator, "part.kup", true)));
        try testing.expect(worker.pid() == null);
    }
    try testing.expect(try preview.hoverFacts(testing.allocator, "part.kup", @fromBackingInt(0)) == null);
    try preview.remove("part.kup");
}
