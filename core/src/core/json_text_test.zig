const std = @import("std");
const testing = std.testing;
const json_text = @import("json_text.zig");

/// A layer name a DXF file gives in its codepage: `Ø` as Windows-1252's byte 0xD8.
const CODEPAGE = "Im\xD8ller";

test "json_text: a string that isn't UTF-8 is text, U+FFFD where a byte isn't" {
    // std.json wrote it as an array of numbers, `[73, 109, 216, ...]`
    const Failure = struct { kind: []const u8, message: []const u8, file: ?[]const u8 = null };
    const json = try json_text.valueAlloc(testing.allocator, .{ .@"error" = Failure{ .kind = "runtime", .message = "no layer '" ++ CODEPAGE ++ "'" } }, .{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"error\":{\"kind\":\"runtime\",\"message\":\"no layer 'Im\u{FFFD}ller'\",\"file\":null}}", json);
    const parsed = try std.json.parseFromSlice(struct { @"error": Failure }, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("no layer 'Im\u{FFFD}ller'", parsed.value.@"error".message);
}

test "json_text: valid text, numbers, nulls and nesting are written as std.json writes them" {
    const Part = struct { name: []const u8, size: [3]f64, color: ?[]const u8, count: u32, nodes: []const []const u8 };
    const parts = [_]Part{
        .{ .name = "lid \"top\"\n", .size = .{ 1, 2.5, 3 }, .color = null, .count = 2, .nodes = &.{ "lid", "lid_2" } },
        .{ .name = "Ø ⌀ 😀", .size = .{ 0, 0, 0 }, .color = "#ff0000", .count = 1, .nodes = &.{} },
    };
    for ([_]std.json.Stringify.Options{ .{}, .{ .emit_null_optional_fields = false }, .{ .escape_unicode = true } }) |options| {
        const ours = try json_text.valueAlloc(testing.allocator, parts, options);
        defer testing.allocator.free(ours);
        const theirs = try std.json.Stringify.valueAlloc(testing.allocator, parts, options);
        defer testing.allocator.free(theirs);
        try testing.expectEqualStrings(theirs, ours);
    }
}

test "json_text: each byte that doesn't start a UTF-8 sequence is one U+FFFD, a whole sequence kept" {
    const cases = [_]struct { bytes: []const u8, text: []const u8 }{
        .{ .bytes = "\xD8", .text = "\u{FFFD}" },
        // A sequence cut short, a lone continuation, an overlong one and a surrogate
        .{ .bytes = "a\xE2\x8C", .text = "a\u{FFFD}\u{FFFD}" },
        .{ .bytes = "\x80b", .text = "\u{FFFD}b" },
        .{ .bytes = "\xC0\xAF", .text = "\u{FFFD}\u{FFFD}" },
        .{ .bytes = "\xED\xA0\x80", .text = "\u{FFFD}\u{FFFD}\u{FFFD}" },
        .{ .bytes = "⌀\x00Ø", .text = "⌀\x00Ø" },
    };
    for (cases) |case| {
        const text = try json_text.textZ(testing.allocator, case.bytes);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(case.text, text);
        try testing.expect(std.unicode.utf8ValidateSlice(text));
        const json = try std.fmt.allocPrint(testing.allocator, "{f}", .{json_text.fmt(case.bytes, .{})});
        defer testing.allocator.free(json);
        const parsed = try std.json.parseFromSlice([]const u8, testing.allocator, json, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(case.text, parsed.value);
    }
}
