const std = @import("std");
const testing = std.testing;
const actions = @import("lsp_actions.zig");
const api = @import("../api.zig");

fn actionsOn(arena: std.mem.Allocator, source: []const u8, line: u32, encoding: actions.Encoding) ![]actions.Action {
    const doc = try arena.create(api.Document);
    doc.* = try api.Document.parse(arena, source);
    return actions.actionsFor(arena, testing.io, doc, .{}, line, line, encoding);
}

test "LSP actions: a finding's fix, preferred when safe, and a disable action indented like its line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = "def f\n  spare = 1\n  2\nend\nf\n";
    const found = try actionsOn(arena.allocator(), source, 1, .utf16);
    try testing.expectEqual(@as(usize, 2), found.len);

    try testing.expectEqualStrings("Rename 'spare' to '_spare'", found[0].title);
    try testing.expect(found[0].preferred);
    try testing.expectEqual(actions.Position{ .line = 1, .character = 2 }, found[0].edits[0].start);
    try testing.expectEqual(actions.Position{ .line = 1, .character = 7 }, found[0].edits[0].end);
    try testing.expectEqualStrings("_spare", found[0].edits[0].text);

    try testing.expectEqualStrings("Disable unused-variable for this line", found[1].title);
    try testing.expect(!found[1].preferred);
    try testing.expectEqual(actions.Position{ .line = 1, .character = 0 }, found[1].edits[0].start);
    try testing.expectEqualStrings("  # kupcad:disable-next-line unused-variable\n", found[1].edits[0].text);

    // Nothing on a line without findings.
    try testing.expectEqual(@as(usize, 0), (try actionsOn(arena.allocator(), source, 2, .utf16)).len);
}

test "LSP actions: columns follow the client's encoding past non-ASCII text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // "é" is 2 bytes in UTF-8 and 1 UTF-16 unit; "𝑥" is 4 bytes and 2 units.
    const source = "puts \"é𝑥\"; spare = 1\nputs 2\n";
    const utf16 = try actionsOn(arena.allocator(), source, 0, .utf16);
    try testing.expectEqual(@as(u32, 12), utf16[0].edits[0].start.character);
    const utf8 = try actionsOn(arena.allocator(), source, 0, .utf8);
    try testing.expectEqual(@as(u32, 15), utf8[0].edits[0].start.character);
}

test "LSP actions: a suggestion is offered but not preferred" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try actionsOn(arena.allocator(), "cube(sise: 3)\n", 0, .utf16);
    try testing.expectEqualStrings("Use 'size'", found[0].title);
    try testing.expect(!found[0].preferred);
}

test "LSP actions: a stray suppression comment gets no disable action" {
    // The quick fix inserted a disable comment above it, which itself warned.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = "# kupcad:disable-next-line unused-variable\nx = 1\nx\n";
    const found = try actionsOn(arena.allocator(), source, 0, .utf8);
    try testing.expectEqual(@as(usize, 0), found.len);
}
