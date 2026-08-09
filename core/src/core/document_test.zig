const std = @import("std");
const testing = std.testing;
const Document = @import("document.zig").Document;
const ast = @import("ast.zig");

test "Document: parse successfully resolves semantics and parents" {
    const source =
        \\# A comment
        \\width = 10
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    // Verify AST was built
    try testing.expect(doc.tree.root != .none);

    // Verify comments were extracted
    try testing.expectEqual(@as(usize, 1), doc.comments.len);
    try testing.expectEqualStrings("# A comment", doc.comments[0].lexeme);

    // Verify semantic side-tables were fully populated!
    try testing.expect(doc.symbols.len > 0);
    try testing.expect(doc.parents.len > 0);
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);
}

test "Document: parseRaw skips semantic resolution and parent mapping" {
    const source =
        \\# Another comment
        \\height = 20
    ;
    var doc = try Document.parseRaw(testing.allocator, source);
    defer doc.deinit();

    // Verify AST was built
    try testing.expect(doc.tree.root != .none);

    // Verify comments were still extracted
    try testing.expectEqual(@as(usize, 1), doc.comments.len);
    try testing.expectEqualStrings("# Another comment", doc.comments[0].lexeme);

    // Verify semantic side-tables were SKIPPED
    try testing.expectEqual(@as(usize, 0), doc.symbols.len);
    try testing.expectEqual(@as(usize, 0), doc.parents.len);
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);
}

test "Document: safely handles parsing syntax errors without leaking" {
    const source = "val = 10 + }"; // Intentional syntax error

    // Test that the standard parse catches it
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.diagnostics.len);
    try testing.expectEqualStrings("Invalid expression starting with '}'", doc.diagnostics[0].message);

    // Test that parseRaw also catches it early
    var raw_doc = try Document.parseRaw(testing.allocator, source);
    defer raw_doc.deinit();

    try testing.expectEqual(@as(usize, 1), raw_doc.diagnostics.len);
    try testing.expectEqualStrings("Invalid expression starting with '}'", raw_doc.diagnostics[0].message);
}
