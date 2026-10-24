const std = @import("std");
const testing = std.testing;
const frame = @import("frame.zig");
const ParamValues = @import("../core/param_values.zig").ParamValues;
const test_support = @import("../test_support.zig");

test "frame: a header and a body come apart as they went in, the header's fields the protocol's" {
    var values: ParamValues = .{};
    defer values.deinit(testing.allocator);
    try values.put(testing.allocator, "width", .{ .number = 20 });
    try values.put(testing.allocator, "material", .{ .text = "PLA" });
    const header: frame.Header = .{
        .document = "file:///work/box.kup",
        .kind = .@"3d",
        .parts = &.{.{ .name = "lid", .count = 2, .nodes = &.{ "lid", "lid_2" }, .color = "#cc3333", .opacity = 1 }},
        .warnings = &.{.{ .message = "mended", .line = 3, .column = 5 }},
        .params = .{ .schema = .{ .meta = .{ .title = "Box" }, .parameters = &.{} }, .values = values },
        .timing = .{ .runMs = 1.5, .renderMs = 0.25 },
    };
    const body = "glTF\x02\x00\x00\x00 the model";
    const bytes = try frame.encode(testing.allocator, header, body);
    defer testing.allocator.free(bytes);

    const parts = try frame.split(bytes);
    try testing.expectEqualStrings(body, parts.body);
    // Read back strictly, as a front end's types would: a field renamed or added fails
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const h = (try test_support.readFrame(arena.allocator(), bytes)).header;
    try testing.expectEqual(frame.PROTOCOL_VERSION, h.protocolVersion);
    try testing.expectEqualStrings("file:///work/box.kup", h.document.?);
    try testing.expectEqualStrings("3d", h.kind);
    try testing.expectEqualStrings("lid_2", h.parts[0].nodes[1]);
    try testing.expectEqual(@as(?u32, 3), h.warnings[0].line);
    try testing.expectEqual(@as(i64, 20), h.params.values.object.get("width").?.integer);
    try testing.expectEqualStrings("PLA", h.params.values.object.get("material").?.string);
    try testing.expectEqualStrings("Box", h.params.schema.object.get("meta").?.object.get("title").?.string);
    try testing.expect(h.@"error" == null);
}

test "frame: one too short for its header's length is refused" {
    try testing.expectError(error.BadFrame, frame.split(""));
    try testing.expectError(error.BadFrame, frame.split("\x00\x00"));
    // A header said to be 9 bytes long, of which 2 came
    try testing.expectError(error.BadFrame, frame.split("\x09\x00\x00\x00{}"));
    const empty = try frame.split("\x02\x00\x00\x00{}");
    try testing.expectEqualStrings("{}", empty.header);
    try testing.expectEqual(@as(usize, 0), empty.body.len);
}
