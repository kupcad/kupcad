const std = @import("std");
const testing = std.testing;
const Reporter = @import("reporter.zig").Reporter;

test "Reporter: --errors json tells a host a message that isn't UTF-8 as text" {
    // A DXF's layer named in its codepage (0xD8) made the message an array of numbers
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const reporter: Reporter = .{ .io = testing.io, .capture = &out.writer, .errors = .json };
    reporter.fail(.{ .kind = "runtime", .message = "no outline on a layer 'Im\xD8ller'", .file = "plate.kup" });
    try testing.expectEqualStrings("{\"error\":{\"kind\":\"runtime\",\"message\":\"no outline on a layer 'Im\u{FFFD}ller'\",\"file\":\"plate.kup\",\"line\":null,\"column\":null}}\n", out.written());
}
