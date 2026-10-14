const std = @import("std");
const testing = std.testing;
const Document = @import("document.zig").Document;
const limits = @import("limits.zig");

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
    // One entry per AST node
    try testing.expectEqual(doc.tree.nodes.items.len, doc.symbols.len);
    try testing.expectEqual(doc.tree.nodes.items.len, doc.parents.len);
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

test "Document: parse rejects sources over MAX_SOURCE_BYTES" {
    // Regression: LSP/WASM entry points bypass the CLI file cap, so the size
    // limit must be enforced here as well
    const src = try testing.allocator.alloc(u8, limits.MAX_SOURCE_BYTES + 1);
    defer testing.allocator.free(src);
    @memset(src, ' ');
    try testing.expectError(error.SourceTooLarge, Document.parse(testing.allocator, src));
}

test "Document: running out of memory never hides a syntax error" {
    // Diagnostics.add dropped a diagnostic it could not store, so broken source could
    // parse with no errors reported.
    const source = "w = 10\nx = )\n";
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var doc = Document.parse(failing.allocator(), source) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer doc.deinit();
        try testing.expect(doc.diagnostics.len > 0);
        if (!failing.has_induced_failure) break;
    }
}

test "Diagnostics: a diagnostic that can't be stored is flagged, not lost silently" {
    const Diagnostics = @import("errors.zig").Diagnostics;
    for (0..2) |fail_index| { // the message, then the list entry
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var diags = Diagnostics.init(failing.allocator());
        defer diags.deinit();
        diags.add(.{ .offset = 0, .length = 1, .file_id = 0 }, "boom {d}", .{1});
        try testing.expect(diags.dropped);
        try testing.expectEqual(@as(usize, 0), diags.list.items.len);
    }
}
