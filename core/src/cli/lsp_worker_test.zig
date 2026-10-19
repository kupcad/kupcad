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
    try testing.expect(std.mem.find(u8, hovered.payload, "**Volume:** `8.00`") != null);
    const removed = try lsp_worker.readFrame(&out, testing.allocator);
    defer testing.allocator.free(removed.payload);
    try testing.expectEqualSlices(u8, &.{0}, removed.payload);
    try testing.expectEqual(@as(usize, 0), preview.session.workspace.modules.items.len);
}

test "lsp worker: a worker that dies is a crash for the preview, and the next use starts another" {
    if (builtin.target.os.tag != .linux and !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    const warnings = @import("../test_support.zig").expectWarnings(); // the worker's end is logged as one
    defer warnings.restore();
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

test "lsp worker: the files a run read reach the server, and a change to one runs its readers again" {
    const path = "part.kup";
    const source = "s = import_json(\"b.json\")\ncube(import_json(\"a.json\")[:side])\n";
    var requests: std.Io.Writer.Allocating = .init(testing.allocator);
    defer requests.deinit();
    try lsp_worker.writeFrame(&requests.writer, .update, &.{ &u32Bytes(path.len), path, source });
    try lsp_worker.writeFrame(&requests.writer, .evaluate, &.{ &.{0}, path });
    try lsp_worker.writeFrame(&requests.writer, .files_read, &.{});
    try lsp_worker.writeFrame(&requests.writer, .file_changed, &.{"a.json"});
    try lsp_worker.writeFrame(&requests.writer, .file_changed, &.{"unread.json"});

    var preview: SessionPreview = undefined;
    try preview.init(testing.allocator, testing.io, false);
    defer preview.deinit();
    // As the files on disk would be
    try preview.documents.vfs().writeFile("a.json", "{\"side\": 2}");
    try preview.documents.vfs().writeFile("b.json", "{}");
    var in: std.Io.Reader = .fixed(requests.written());
    var replies: std.Io.Writer.Allocating = .init(testing.allocator);
    defer replies.deinit();
    try lsp_worker.serve(testing.io, testing.allocator, &preview, &in, &replies.writer);

    var out: std.Io.Reader = .fixed(replies.written());
    // Updated, evaluated (nothing to show: no mesh wanted), the files, a file it read, one it didn't
    const expected = [_][]const u8{ &.{0}, &.{@backingInt(std.meta.Tag(@import("lsp_preview.zig").Outcome).nothing)}, "a.json\x00b.json", &.{1}, &.{0} };
    for (expected) |payload| {
        const reply = try lsp_worker.readFrame(&out, testing.allocator);
        defer testing.allocator.free(reply.payload);
        try testing.expectEqual(lsp_worker.Kind.reply, reply.kind);
        try testing.expectEqualSlices(u8, payload, reply.payload);
    }
    const node = preview.session.nodes.items[0];
    try testing.expect(node.is_stale and node.data_changed);
}

test "lsp worker: the paths of a files_read reply read back as they were sent" {
    const cases = [_][]const []const u8{ &.{}, &.{"a.json"}, &.{ "a.json", "data/b c.json", "scan.STL" } };
    for (cases) |files| {
        const joined = try lsp_worker.joinPaths(testing.allocator, files);
        defer testing.allocator.free(joined);
        const read = try lsp_worker.splitPaths(testing.allocator, joined);
        defer @import("lsp_preview.zig").freeFiles(testing.allocator, read);
        try testing.expectEqual(files.len, read.len);
        for (files, read) |want, got| try testing.expectEqualStrings(want, got);
    }
}
