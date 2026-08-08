const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");

// --- Test Helpers ---

// Dummy token index for testing
const dummy_token: u24 = 0;

// --- Tests ---

test "AST: Node struct size is optimized to 8 bytes" {
    // Ensuring the Node stays compact is critical for cache locality
    // 1 byte (Tag) + 3 bytes (main_token) + 4 bytes (data/payload index) = 8 bytes
    try testing.expectEqual(@as(usize, 8), @sizeOf(ast.Node));
}

test "AST Builder: String interning deduplicates perfectly" {
    var builder = ast.Builder.init(testing.allocator);
    defer builder.deinit();

    const str1_id = try builder.intern("my_variable");
    const str2_id = try builder.intern("my_variable");
    const str3_id = try builder.intern("other_variable");

    // The identical strings should map to the exact same StringId (u32 enum)
    try testing.expectEqual(str1_id, str2_id);
    // The different string should get a new unique StringId
    try testing.expect(str1_id != str3_id);

    // Retrieve the strings back from the Tree's string pool
    try testing.expectEqualStrings("my_variable", builder.tree.getString(str1_id));
    try testing.expectEqualStrings("other_variable", builder.tree.getString(str3_id));
}

test "AST Builder: Constructs and stores primitive Number payloads" {
    var builder = ast.Builder.init(testing.allocator);
    defer builder.deinit();

    // The builder handles underscores and advanced parsing natively before pushing
    const num_idx = try builder.number("1_000_000.5", dummy_token);
    const node = builder.tree.getNode(num_idx).?;

    try testing.expectEqual(ast.Tag.number, node.tag);

    // Retrieve the value via the unified data reconstructor helper
    const actual_val = builder.tree.number(node);
    try testing.expectEqual(@as(f64, 1000000.5), actual_val);
}

test "AST Builder: Safely parses hex and binary Number literals" {
    var builder = ast.Builder.init(testing.allocator);
    defer builder.deinit();

    const hex_idx = try builder.number("0xFF", dummy_token);
    const bin_idx = try builder.number("0b1010", dummy_token);

    const hex_node = builder.tree.getNode(hex_idx).?;
    const bin_node = builder.tree.getNode(bin_idx).?;

    try testing.expectEqual(@as(f64, 255.0), builder.tree.number(hex_node));
    try testing.expectEqual(@as(f64, 10.0), builder.tree.number(bin_node));
}

test "AST Builder: Constructs and retrieves complex Binary Expressions" {
    var builder = ast.Builder.init(testing.allocator);
    defer builder.deinit();

    const left_idx = try builder.number("10", dummy_token);
    const right_idx = try builder.number("20", dummy_token);

    const bin_idx = try builder.binary(.add, left_idx, right_idx, dummy_token);
    const node = builder.tree.getNode(bin_idx).?;

    try testing.expectEqual(ast.Tag.binary_op, node.tag);

    // Use the specific Tree accessor helper for BinaryExpr payloads
    const bin_payload = builder.tree.binaryExpr(node);

    try testing.expectEqual(ast.BinaryOp.add, bin_payload.op);
    try testing.expectEqual(left_idx, bin_payload.left);
    try testing.expectEqual(right_idx, bin_payload.right);
}

test "AST Builder: Constructs span-based Block nodes accurately" {
    var builder = ast.Builder.init(testing.allocator);
    defer builder.deinit();

    // Create 3 dummy statements
    const stmt1 = try builder.number("1", dummy_token);
    const stmt2 = try builder.number("2", dummy_token);
    const stmt3 = try builder.number("3", dummy_token);

    const stmts = [_]ast.NodeIndex{ stmt1, stmt2, stmt3 };
    const params = [_]ast.NodeIndex{}; // Empty params for this block

    const block_idx = try builder.block(&params, &stmts, dummy_token, dummy_token);
    const node = builder.tree.getNode(block_idx).?;

    try testing.expectEqual(ast.Tag.block, node.tag);

    // Reconstruct the block payload from extra_data
    const block_payload = builder.tree.block(node);
    try testing.expectEqual(@as(u32, dummy_token), block_payload.end_token);

    // Extract the span of statements from the auxiliary indices array
    const extracted_stmts = builder.tree.getNodes(block_payload.stmts);
    try testing.expectEqual(@as(usize, 3), extracted_stmts.len);
    try testing.expectEqual(stmt1, extracted_stmts[0]);
    try testing.expectEqual(stmt2, extracted_stmts[1]);
    try testing.expectEqual(stmt3, extracted_stmts[2]);
}

test "AST Builder: Assignment node generation with interning" {
    var builder = ast.Builder.init(testing.allocator);
    defer builder.deinit();

    const val_idx = try builder.number("42", dummy_token);
    const var_name = try builder.intern("my_var");

    // Test a compound assignment `my_var += 42`
    const assign_idx = try builder.assignment(var_name, .add, val_idx, dummy_token);
    const node = builder.tree.getNode(assign_idx).?;

    try testing.expectEqual(ast.Tag.assignment, node.tag);

    const assign_payload = builder.tree.assignment(node);

    try testing.expectEqualStrings("my_var", builder.tree.getString(assign_payload.name));
    try testing.expectEqual(ast.BinaryOp.add, assign_payload.op.?);
    try testing.expectEqual(val_idx, assign_payload.value);
}
