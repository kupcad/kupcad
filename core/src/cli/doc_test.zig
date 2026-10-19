const std = @import("std");
const testing = std.testing;
const doc_cmd = @import("doc.zig");
const Reporter = @import("reporter.zig").Reporter;

fn runOn(tmp: *testing.TmpDir, name: []const u8, out: *std.Io.Writer.Allocating) !doc_cmd.Outcome {
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, name });
    defer testing.allocator.free(path);
    const reporter: Reporter = .{ .io = testing.io, .capture = &out.writer };
    return doc_cmd.run(testing.allocator, path, reporter);
}

test "doc: prints the schema of a script, and fails on one with syntax errors" {
    // It printed the schema of whatever parsed and exited 0.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "good.kup", .data = "width = param(:width, default: 10)\ncube(width)\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.kup", .data = "width = )\n" });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(.success, try runOn(&tmp, "good.kup", &out));
    try testing.expect(std.mem.find(u8, out.written(), "\"width\"") != null);

    out.clearRetainingCapacity();
    try testing.expectEqual(.failure, try runOn(&tmp, "broken.kup", &out));
    try testing.expect(std.mem.find(u8, out.written(), "broken.kup:1:") != null);
    try testing.expect(std.mem.find(u8, out.written(), "No schema: 1 syntax error in") != null);
    try testing.expect(std.mem.find(u8, out.written(), "{") == null);
}
