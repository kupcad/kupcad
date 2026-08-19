const std = @import("std");
const testing = std.testing;
const ast = @import("../../core/ast.zig");
const DocstringParser = @import("docstring.zig").DocstringParser;

const dummy_token: u24 = 0;

test "Docstring Parser: Parses generic @label with single-line content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    const raw = "# @label Bracket Width";
    const doc_idx = try parser.parse(raw, dummy_token);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = b.tree.docString(doc_node);

    try testing.expectEqualStrings("label", b.tree.getString(doc.tag_name));
    try testing.expectEqualStrings("Bracket Width", b.tree.getString(doc.content));
}

test "Docstring Parser: Parses generic @tooltip with multi-line indented continuation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    // The YARD continuation must be indented by at least 2 spaces after the '#'
    const raw =
        \\# @tooltip The overall span of the bracket.
        \\#   Keep under 50mm for standard printers.
        \\#   Very important note.
    ;
    const doc_idx = try parser.parse(raw, dummy_token);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = b.tree.docString(doc_node);

    try testing.expectEqualStrings("tooltip", b.tree.getString(doc.tag_name));

    const expected_content = "The overall span of the bracket.\nKeep under 50mm for standard printers.\nVery important note.";
    try testing.expectEqualStrings(expected_content, b.tree.getString(doc.content));
}

test "Docstring Parser: Breaks continuation on non-indented lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    // The third line is NOT indented, so it should be ignored by this tag.
    const raw =
        \\# @label Bracket Width
        \\#   This is a continuation.
        \\# This is NOT a continuation.
        \\#   This should also be ignored because the chain was broken.
    ;
    const doc_idx = try parser.parse(raw, dummy_token);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = b.tree.docString(doc_node);

    try testing.expectEqualStrings("label", b.tree.getString(doc.tag_name));
    try testing.expectEqualStrings("Bracket Width\nThis is a continuation.", b.tree.getString(doc.content));
}

test "Docstring Parser: Preserves deep indentation inside continuation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    const raw =
        \\# @tooltip Some info:
        \\#   * Item 1
        \\#     * Sub item
    ;
    const doc_idx = try parser.parse(raw, dummy_token);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = b.tree.docString(doc_node);

    try testing.expectEqualStrings("tooltip", b.tree.getString(doc.tag_name));
    // The base 3 spaces are stripped, but the extra 2 spaces on Sub item are kept!
    try testing.expectEqualStrings("Some info:\n* Item 1\n  * Sub item", b.tree.getString(doc.content));
}

test "Docstring Parser: Parses tag with no content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    const raw = "# @version";
    const doc_idx = try parser.parse(raw, dummy_token);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = b.tree.docString(doc_node);

    try testing.expectEqualStrings("version", b.tree.getString(doc.tag_name));
    try testing.expectEqualStrings("", b.tree.getString(doc.content));
}

test "Docstring Parser: Non-annotation comment evaluates to empty tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    // Standard comments without '@' should be silently ignored and yield empty tags
    const raw = "# Just a regular comment about the next line";
    const doc_idx = try parser.parse(raw, dummy_token);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = b.tree.docString(doc_node);

    try testing.expectEqualStrings("", b.tree.getString(doc.tag_name));
    try testing.expectEqualStrings("", b.tree.getString(doc.content));
}

test "Docstring Parser: Handles arbitrary spacing and carriage returns safely" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    // Inject heavy spaces, tabs, and carriage returns (\r) to simulate Windows files
    const raw = "# \t  @description \t  This is deeply indented. \r\n# \t  Line 2. \r";
    const doc_idx = try parser.parse(raw, dummy_token);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = b.tree.docString(doc_node);

    try testing.expectEqualStrings("description", b.tree.getString(doc.tag_name));
    // Under YARD continuation rules, base continuation spacing (3 spaces) is consumed,
    // leaving the 2 additional indentation spaces preserved:
    try testing.expectEqualStrings("This is deeply indented.\n  Line 2.", b.tree.getString(doc.content));
}
