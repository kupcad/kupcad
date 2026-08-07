const std = @import("std");
const testing = std.testing;
const api = @import("api.zig");

test "Formatter: formats raw KupCAD code to expected layout" {
    const input_code = @embedFile("fixtures/format_in.kup");
    const expected_code = @embedFile("fixtures/format_out.kup");
    const allocator = testing.allocator;

    const formatted = try api.formatCode(allocator, input_code, .{});
    defer allocator.free(formatted);

    try testing.expectEqualStrings(expected_code, formatted);
}

test "Linter API: checkCode surfaces all expected diagnostics on bad fixture" {
    const bad_code = @embedFile("fixtures/linter_bad.kup");
    const allocator = testing.allocator;

    const diags = try api.checkCode(allocator, bad_code, .{});
    defer {
        for (diags) |d| allocator.free(d.message);
        allocator.free(diags);
    }

    // Must surface exactly 4 diagnostics (3 warnings, 1 info)
    try testing.expectEqual(@as(usize, 4), diags.len);

    // CSG Warning on Line 7
    try testing.expectEqual(.warning, diags[0].severity);
    try testing.expectEqual(@as(u32, 7), diags[0].loc.line);
    try testing.expectEqualStrings("CSG Warning: Self-difference operation ('part - part') will result in empty geometry.", diags[0].message);

    // Unreachable Code Warning on Line 11
    try testing.expectEqual(.warning, diags[1].severity);
    try testing.expectEqual(@as(u32, 11), diags[1].loc.line);
    try testing.expectEqualStrings("Unreachable code detected after explicit control flow return/break.", diags[1].message);

    // ParamDoc Missing Reference Info on Line 1
    try testing.expectEqual(.info, diags[2].severity);
    try testing.expectEqual(@as(u32, 1), diags[2].loc.line);
    try testing.expectEqualStrings("@param annotation references variable 'missing_var', which is never declared in standard scope.", diags[2].message);

    // Unused Variable Warning on Line 3
    try testing.expectEqual(.warning, diags[3].severity);
    try testing.expectEqual(@as(u32, 3), diags[3].loc.line);
    try testing.expectEqualStrings("Unused variable 'unused_var'. Prefix with '_' if intentional.", diags[3].message);
}

test "Document: successfully parses valid code and owns the AST" {
    const source =
        \\# A comment
        \\width = 10
    ;

    var doc = try api.Document.parse(testing.allocator, source);
    defer doc.deinit();

    // Verify successful tree generation
    try testing.expect(doc.tree.root != .none);

    // Verify block statement holds our assignment using Data-Oriented lookup
    const root_node = doc.tree.getNode(doc.tree.root).?;
    const block = root_node.kind.block;

    try testing.expectEqual(@as(usize, 1), block.stmts.len);

    const stmt_node = doc.tree.getNode(block.stmts[0]).?;
    try testing.expectEqualStrings("width", stmt_node.kind.assignment.name);

    // Verify comment was captured
    try testing.expectEqual(@as(usize, 1), doc.comments.len);
    try testing.expectEqualStrings("# A comment", doc.comments[0].lexeme);

    // Verify LineIndex was built
    try testing.expect(doc.line_index.line_starts.len > 0);

    // No diagnostics should be emitted for valid code
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);
}

test "Document: safely handles parsing syntax errors without leaking" {
    const source = "val = 10 + }"; // Intentional syntax error

    var doc = try api.Document.parse(testing.allocator, source);
    defer doc.deinit();

    // Verify that the parser diagnostic was captured natively in the document
    try testing.expectEqual(@as(usize, 1), doc.diagnostics.len);
    try testing.expectEqualStrings("Invalid expression starting with '}'", doc.diagnostics[0].message);
}
