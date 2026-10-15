const std = @import("std");
const testing = std.testing;
const Document = @import("../core/document.zig").Document;
const hints_mod = @import("lsp_hints.zig");

/// The hints for `source`, as "name@offset" joined by spaces.
fn hintsOf(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out: std.Io.Writer.Allocating = .init(arena);
    for (try hints_mod.parameterHints(arena, &doc), 0..) |hint, i| {
        try out.writer.print("{s}{s}@{d}", .{ if (i == 0) "" else " ", hint.name, hint.offset });
    }
    return out.written();
}

test "LSP hints: each positional argument of a primitive gets its Signature's name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("x@5 y@8 z@11", try hintsOf(a, "cube(1, 2, 3)"));
    // A lone size sets every side.
    try testing.expectEqualStrings("size@5", try hintsOf(a, "cube(5)"));
    // At the start of the argument, not its operator; none for an argument already named so.
    try testing.expectEqualStrings("x@11", try hintsOf(a, "y = 1\ncube(y + 1, y)"));
    try testing.expectEqualStrings("y@14", try hintsOf(a, "x = 1\ncube(x, 2)"));
    // Keywords need none, and after a splat the positions are unknown.
    try testing.expectEqualStrings("", try hintsOf(a, "cube(x: 1, y: 2)"));
    try testing.expectEqualStrings("", try hintsOf(a, "dims = [1, 2, 3]\ncube(*dims)"));
}

test "LSP hints: methods of solids and sketches, from their Signatures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The hand-written table these replace showed revolve's `deg` as `segments`.
    try testing.expectEqualStrings("r@11 deg@24", try hintsOf(a, "p = circle(2)\np.revolve(90)"));
    try testing.expectEqualStrings("size@7 h@18", try hintsOf(a, "square(4).extrude(10)"));
    try testing.expectEqualStrings("size@5 x@18 y@21 z@24", try hintsOf(a, "cube(1).translate(1, 2, 3)"));
    // A method of the script's own class is its own.
    try testing.expectEqualStrings("", try hintsOf(a, "class G\n  def translate(a) = a\nend\nG.new.translate(1)"));
}
