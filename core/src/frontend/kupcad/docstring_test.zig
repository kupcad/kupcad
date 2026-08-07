const std = @import("std");
const testing = std.testing;
const ast = @import("../../core/ast.zig");
const token = @import("../../core/token.zig");
const DocstringParser = @import("docstring.zig").DocstringParser;

const dummy_loc = token.Location{ .line = 1, .col = 1, .offset = 0, .length = 0, .file_id = 0 };

test "Docstring Parser: Standard @param with type and description" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    const raw = "# @param width [Length] Overall box width";
    const doc_idx = try parser.parse(raw, dummy_loc);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = doc_node.kind.param_doc;

    try testing.expectEqualStrings("param", doc.tag_name);
    try testing.expectEqualStrings("width", doc.target_name.?);
    try testing.expectEqualStrings("Length", doc.type_name.?);
    try testing.expectEqualStrings("Overall box width", doc.description);
    try testing.expect(doc.options_expr == .none);
}

test "Docstring Parser: @param with Lookbook options hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    const raw = "# @param depth [Length] Depth offset { min: 10, max: 100 }";
    const doc_idx = try parser.parse(raw, dummy_loc);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = doc_node.kind.param_doc;

    try testing.expectEqualStrings("param", doc.tag_name);
    try testing.expectEqualStrings("depth", doc.target_name.?);
    try testing.expectEqualStrings("Length", doc.type_name.?);
    try testing.expectEqualStrings("Depth offset", doc.description);
    try testing.expect(doc.options_expr != .none);

    const hash_node = b.tree.getNode(doc.options_expr).?;
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).hash_literal, std.meta.activeTag(hash_node.kind));
    const hash = hash_node.kind.hash_literal;

    const key_node = b.tree.getNode(hash[0].key).?;
    try testing.expectEqualStrings("min", key_node.kind.symbol);
}

test "Docstring Parser: Multi-line description condensation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    const raw =
        \\# @param config [Hash] The configuration hash that determines
        \\#   how the component is generated and what materials
        \\#   are explicitly supported.
    ;

    const doc_idx = try parser.parse(raw, dummy_loc);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = doc_node.kind.param_doc;

    try testing.expectEqualStrings("param", doc.tag_name);
    try testing.expectEqualStrings("config", doc.target_name.?);
    try testing.expectEqualStrings("Hash", doc.type_name.?);

    // Now accurately preserves physical linebreaks
    try testing.expectEqualStrings("The configuration hash that determines\nhow the component is generated and what materials\nare explicitly supported.", doc.description);
}

test "Docstring Parser: Non-annotation comment evaluates to empty tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    const raw = "# Just a regular comment";
    const doc_idx = try parser.parse(raw, dummy_loc);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = doc_node.kind.param_doc;

    try testing.expectEqualStrings("", doc.tag_name);
}

test "Docstring Parser: Graceful handling of invalid options hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    // This hash contains a syntax error (`bad_syntax` with no value)
    const raw = "# @param width [Length] Width { min: 10, bad_syntax }";

    const doc_idx = try parser.parse(raw, dummy_loc);
    const doc_node = b.tree.getNode(doc_idx).?;
    const doc = doc_node.kind.param_doc;

    try testing.expectEqualStrings("param", doc.tag_name);
    try testing.expectEqualStrings("width", doc.target_name.?);
    try testing.expectEqualStrings("Length", doc.type_name.?);
    try testing.expectEqualStrings("Width", doc.description);

    // The embedded parser should swallow the syntax error safely and leave options_expr as none
    try testing.expect(doc.options_expr == .none);
}

test "Docstring Parser: Graceful handling of missing closing brackets and incomplete tags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();
    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    // Missing closing bracket for type
    const doc1_idx = try parser.parse("# @param width [Length", dummy_loc);
    const doc1_node = b.tree.getNode(doc1_idx).?;
    const doc1 = doc1_node.kind.param_doc;

    try testing.expectEqualStrings("param", doc1.tag_name);
    try testing.expectEqualStrings("width", doc1.target_name.?);
    try testing.expect(doc1.type_name == null);
    try testing.expectEqualStrings("[Length", doc1.description);

    // Incomplete param tag (missing name and description)
    const doc2_idx = try parser.parse("# @param", dummy_loc);
    const doc2_node = b.tree.getNode(doc2_idx).?;
    const doc2 = doc2_node.kind.param_doc;

    try testing.expectEqualStrings("param", doc2.tag_name);
    try testing.expect(doc2.target_name == null);
    try testing.expect(doc2.type_name == null);
    try testing.expectEqualStrings("", doc2.description);

    // Bare @ symbol
    const doc3_idx = try parser.parse("# @", dummy_loc);
    const doc3_node = b.tree.getNode(doc3_idx).?;
    const doc3 = doc3_node.kind.param_doc;

    try testing.expectEqualStrings("", doc3.tag_name);
    try testing.expect(doc3.target_name == null);
    try testing.expect(doc3.type_name == null);
    try testing.expectEqualStrings("", doc3.description);
}
