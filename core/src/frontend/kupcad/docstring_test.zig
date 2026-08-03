const std = @import("std");
const testing = std.testing;
const ast = @import("../../core/ast.zig");
const token = @import("../../core/token.zig");
const DocstringParser = @import("docstring.zig").DocstringParser;

const dummy_loc = token.Location{ .line = 1, .col = 1, .file_id = 0 };

test "Docstring Parser: Standard @param with type and description" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };
    const raw = "# @param width [Length] Overall box width";

    const doc = try parser.parse(raw, dummy_loc);

    try testing.expectEqualStrings("param", doc.tag_name);
    try testing.expectEqualStrings("width", doc.target_name.?);
    try testing.expectEqualStrings("Length", doc.type_name.?);
    try testing.expectEqualStrings("Overall box width", doc.description);
    try testing.expect(doc.options_expr == null);
}

test "Docstring Parser: @param with Lookbook options hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };
    const raw = "# @param depth [Length] Depth offset { min: 10, max: 100 }";

    const doc = try parser.parse(raw, dummy_loc);

    try testing.expectEqualStrings("param", doc.tag_name);
    try testing.expectEqualStrings("depth", doc.target_name.?);
    try testing.expectEqualStrings("Length", doc.type_name.?);
    try testing.expectEqualStrings("Depth offset", doc.description);

    // Verify the embedded parser spun up and captured the hash literal!
    try testing.expect(doc.options_expr != null);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).hash_literal, std.meta.activeTag(doc.options_expr.?.kind));

    const hash = doc.options_expr.?.kind.hash_literal;
    try testing.expectEqual(@as(usize, 2), hash.len);
    try testing.expectEqualStrings("min", hash[0].key.kind.symbol);
    try testing.expectEqual(@as(f64, 10.0), hash[0].value.kind.number);
    try testing.expectEqualStrings("max", hash[1].key.kind.symbol);
    try testing.expectEqual(@as(f64, 100.0), hash[1].value.kind.number);
}

test "Docstring Parser: @return tag (no target name)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };
    const raw = "# @return [Mesh] The generated enclosure part";

    const doc = try parser.parse(raw, dummy_loc);

    try testing.expectEqualStrings("return", doc.tag_name);
    try testing.expect(doc.target_name == null); // @return has no target variable
    try testing.expectEqualStrings("Mesh", doc.type_name.?);
    try testing.expectEqualStrings("The generated enclosure part", doc.description);
}

test "Docstring Parser: @deprecated tag (no type, no target name)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };
    const raw = "# @deprecated Use Box.new instead of this function.";

    const doc = try parser.parse(raw, dummy_loc);

    try testing.expectEqualStrings("deprecated", doc.tag_name);
    try testing.expect(doc.target_name == null);
    try testing.expect(doc.type_name == null);
    try testing.expectEqualStrings("Use Box.new instead of this function.", doc.description);
}

test "Docstring Parser: @param without a type signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };
    const raw = "# @param is_active Whether the part is rendering";

    const doc = try parser.parse(raw, dummy_loc);

    try testing.expectEqualStrings("param", doc.tag_name);
    try testing.expectEqualStrings("is_active", doc.target_name.?);
    try testing.expect(doc.type_name == null);
    try testing.expectEqualStrings("Whether the part is rendering", doc.description);
}

test "Docstring Parser: Multi-line description condensation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };

    // Simulating how the lexer grabs continuous indented parameter blocks
    const raw =
        \\# @param config [Hash] The configuration hash that determines
        \\#   how the component is generated and what materials
        \\#   are explicitly supported.
    ;

    const doc = try parser.parse(raw, dummy_loc);

    try testing.expectEqualStrings("param", doc.tag_name);
    try testing.expectEqualStrings("config", doc.target_name.?);
    try testing.expectEqualStrings("Hash", doc.type_name.?);

    // Should neatly compress into a single line string
    try testing.expectEqualStrings("The configuration hash that determines how the component is generated and what materials are explicitly supported.", doc.description);
}

test "Docstring Parser: Non-annotation comment evaluates to empty tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    var parser = DocstringParser{ .allocator = arena.allocator(), .b = &b };
    const raw = "# Just a regular comment";

    const doc = try parser.parse(raw, dummy_loc);

    try testing.expectEqualStrings("", doc.tag_name);
}
