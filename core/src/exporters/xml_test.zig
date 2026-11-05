const std = @import("std");
const testing = std.testing;
const xml = @import("xml.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

test "XML: each tag knows its line, past newlines in comments, CDATA and values" {
    const text = "<svg>\n<!-- a\ncomment -->\n<g\n  id=\"a\nb\"><![CDATA[\n]]>\n<rect/></g>\n</svg>";
    const lines = [_]struct { name: []const u8, line: usize }{
        .{ .name = "svg", .line = 1 }, .{ .name = "g", .line = 4 },   .{ .name = "rect", .line = 8 },
        .{ .name = "g", .line = 8 },   .{ .name = "svg", .line = 9 },
    };
    var scanner = xml.Scanner{ .text = text };
    var diag: Diagnostic = .{};
    for (lines) |expected| {
        const tag = (try scanner.next(&diag)).?;
        try testing.expectEqualStrings(expected.name, tag.name);
        try testing.expectEqual(expected.line, tag.line);
    }
    try testing.expectEqual(null, try scanner.next(&diag));
}

test "XML: a file's newlines are counted once each as it is scanned, from a tag on too" {
    // Every tag's line was counted from the start of the file: reading one was quadratic in
    // its size (a 3 MB 3MF took 31 s). The scanner counts up to where it has got.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..1000) |_| try text.appendSlice(testing.allocator, "<vertex x=\"0\"/>\n");
    var scanner = xml.Scanner{ .text = text.items };
    var diag: Diagnostic = .{};
    var tags: usize = 0;
    var mid: ?xml.Tag = null;
    while (try scanner.next(&diag)) |tag| : (tags += 1) {
        try testing.expectEqual(tags + 1, tag.line);
        // Counted to the tag, no further back than the last one
        try testing.expectEqual(tag.offset, scanner.counted);
        if (tags == 500) mid = tag;
    }
    try testing.expectEqual(@as(usize, 1000), tags);
    // A scanner from a tag (a `use` reading again what it names) goes on from its line
    var again = xml.Scanner.startingAt(text.items, mid.?);
    try testing.expectEqual(@as(usize, 501), (try again.next(&diag)).?.line);
    try testing.expectEqual(@as(usize, 502), (try again.next(&diag)).?.line);
}

test "XML: what doesn't end says on which line it starts" {
    const cases = [_]struct { text: []const u8, message: []const u8 }{
        .{ .text = "<a>\n\n<!-- open", .message = "line 3: a comment doesn't end" },
        .{ .text = "<a>\n<b", .message = "line 2: a tag doesn't end" },
        .{ .text = "\n<!DOCTYPE", .message = "line 2: a declaration doesn't end" },
    };
    for (cases) |case| {
        var scanner = xml.Scanner{ .text = case.text };
        var diag: Diagnostic = .{};
        const failed = while (scanner.next(&diag)) |tag| {
            if (tag == null) break false;
        } else |_| true;
        try testing.expect(failed);
        try testing.expectEqualStrings(case.message, diag.message());
    }
}
