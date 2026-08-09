const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const resolver = @import("resolver.zig");
const errors = @import("errors.zig");

// Use the existing KupCAD parser test utility
const Lexer = @import("../frontend/kupcad/lexer.zig").Lexer;
const Parser = @import("../frontend/kupcad/parser.zig").Parser;
const ParserTest = @import("../frontend/test_utils.zig").ParserTest;
const KTest = ParserTest(Lexer, Parser);

/// Helper function to scan the AST for all `.identifier` nodes matching a specific name,
/// and asserts that the Resolver assigned at least one of them the expected scope kind and slot index.
fn expectResolved(res: *const resolver.Resolver, tree: *const ast.Tree, name: []const u8, expected_kind: resolver.ScopeKind, expected_index: u24) !void {
    var found_match = false;
    for (tree.nodes.items, 0..) |node, i| {
        if (node.tag == .identifier) {
            const id_str = tree.getString(@as(ast.StringId, @enumFromInt(node.data)));
            if (std.mem.eql(u8, id_str, name)) {
                const sym = res.symbols[i];
                // Because Parsers often leave "dead" orphan nodes behind when transforming
                // expressions into assignments, we just want to ensure the "live" node was resolved!
                if (sym.kind == expected_kind and sym.index == expected_index) {
                    found_match = true;
                    break;
                }
            }
        }
    }

    if (!found_match) {
        std.debug.print("Resolved Identifier '{s}' not found matching {any} at slot/index {d}!\n", .{ name, expected_kind, expected_index });
        return error.TestExpectedEqual;
    }
}

test "Resolver: correctly classifies local, instance, and global variables" {
    const source =
        \\def calculate(x)
        \\  y = 10
        \\  a = x
        \\  b = y
        \\  c = @inst
        \\  d = $glob
        \\  e = missing
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const root_idx = try pt.parser.parseProgram();

    var diags = errors.Diagnostics.init(testing.allocator);
    defer diags.deinit();

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, pt.parser.tokens.starts, pt.parser.tokens.lengths, &diags);
    defer res.deinit();

    try res.resolve(root_idx);

    const tree = &pt.parser.b.tree;

    // Parameters and declared variables are correctly slotted sequentially as locals
    try expectResolved(&res, tree, "x", .local, 0); // Param x is slot 0
    try expectResolved(&res, tree, "y", .local, 1); // Local y is slot 1

    // Explicit syntax prefixes are instantly categorized
    try expectResolved(&res, tree, "@inst", .instance_var, 0);
    try expectResolved(&res, tree, "$glob", .global, 0);

    // Undeclared variables fall back to global runtime lookups
    try expectResolved(&res, tree, "missing", .global, 0);
}

test "Resolver: correctly resolves upvalues across closure boundaries" {
    const source =
        \\def outer(x)
        \\  ->(y) {
        \\    a = x
        \\    b = y
        \\  }
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const root_idx = try pt.parser.parseProgram();

    var diags = errors.Diagnostics.init(testing.allocator);
    defer diags.deinit();

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, pt.parser.tokens.starts, pt.parser.tokens.lengths, &diags);
    defer res.deinit();

    try res.resolve(root_idx);

    const tree = &pt.parser.b.tree;

    // 'x' crosses a lambda boundary, making it an upvalue pointing to outer's slot 0
    try expectResolved(&res, tree, "x", .upvalue, 0);

    // 'y' belongs to the lambda's own scope, making it a local pointing to lambda's slot 0
    try expectResolved(&res, tree, "y", .local, 0);
}

test "Resolver: block parameters resolve as local variables" {
    const source =
        \\10.times do |i, val|
        \\  a = i
        \\  b = val
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const root_idx = try pt.parser.parseProgram();

    var diags = errors.Diagnostics.init(testing.allocator);
    defer diags.deinit();

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, pt.parser.tokens.starts, pt.parser.tokens.lengths, &diags);
    defer res.deinit();

    try res.resolve(root_idx);

    const tree = &pt.parser.b.tree;

    // Block parameters `|i, val|` should map seamlessly into slots 0 and 1
    try expectResolved(&res, tree, "i", .local, 0);
    try expectResolved(&res, tree, "val", .local, 1);
}

test "Resolver: permits break and next inside loops" {
    const source =
        \\while true
        \\  break if false
        \\  next
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const root_idx = try pt.parser.parseProgram();

    var diags = errors.Diagnostics.init(testing.allocator);
    defer diags.deinit();

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, pt.parser.tokens.starts, pt.parser.tokens.lengths, &diags);
    defer res.deinit();

    try res.resolve(root_idx);

    // Should have 0 errors since break and next are legally inside the while loop
    try testing.expectEqual(@as(usize, 0), diags.list.items.len);
}

test "Resolver: rejects break and next outside loops" {
    const source =
        \\if true
        \\  break
        \\end
        \\next
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const root_idx = try pt.parser.parseProgram();

    var diags = errors.Diagnostics.init(testing.allocator);
    defer diags.deinit();

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, pt.parser.tokens.starts, pt.parser.tokens.lengths, &diags);
    defer res.deinit();

    try res.resolve(root_idx);

    // Should catch exactly 2 errors
    try testing.expectEqual(@as(usize, 2), diags.list.items.len);
    try testing.expectEqualStrings("Cannot use 'break' outside of a loop", diags.list.items[0].message);
    try testing.expectEqualStrings("Cannot use 'next' outside of a loop", diags.list.items[1].message);
}

test "Resolver: prevents break from escaping closure boundaries" {
    const source =
        \\while true
        \\  def inner()
        \\    break
        \\  end
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const root_idx = try pt.parser.parseProgram();

    var diags = errors.Diagnostics.init(testing.allocator);
    defer diags.deinit();

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, pt.parser.tokens.starts, pt.parser.tokens.lengths, &diags);
    defer res.deinit();

    try res.resolve(root_idx);

    // The break is technically inside a while loop, but it crosses a function boundary!
    // It should be completely illegal.
    try testing.expectEqual(@as(usize, 1), diags.list.items.len);
    try testing.expectEqualStrings("Cannot use 'break' outside of a loop", diags.list.items[0].message);
}

test "Resolver: single-level upvalue capture" {
    const source =
        \\def outer(x)
        \\  ->() { x }
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const root_idx = try pt.parser.parseProgram();

    var diags = errors.Diagnostics.init(testing.allocator);
    defer diags.deinit();

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, pt.parser.tokens.starts, pt.parser.tokens.lengths, &diags);
    defer res.deinit();

    try res.resolve(root_idx);
    try testing.expectEqual(@as(usize, 0), diags.list.items.len);

    // Find the lambda node in the AST
    var lambda_node_idx: ast.NodeIndex = .none;
    for (pt.parser.b.tree.nodes.items, 0..) |node, i| {
        if (node.tag == .lambda_expr) {
            lambda_node_idx = @enumFromInt(i);
            break;
        }
    }
    try testing.expect(lambda_node_idx != .none);

    // Verify the closure captures side-table
    const captures = res.closure_captures.get(lambda_node_idx).?;
    try testing.expectEqual(@as(usize, 1), captures.len);

    // It should capture 'x' directly from outer's local slots (is_local = true)
    try testing.expectEqual(true, captures[0].is_local);
    try testing.expectEqual(@as(u24, 0), captures[0].index); // outer's slot 0 (the 'x' param)
}

test "Resolver: deep recursive upvalue capture" {
    const source =
        \\def outer(x)
        \\  ->() {
        \\    ->() { x }
        \\  }
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const root_idx = try pt.parser.parseProgram();

    var diags = errors.Diagnostics.init(testing.allocator);
    defer diags.deinit();

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, pt.parser.tokens.starts, pt.parser.tokens.lengths, &diags);
    defer res.deinit();

    try res.resolve(root_idx);
    try testing.expectEqual(@as(usize, 0), diags.list.items.len);

    // Because the AST is built bottom-up, the inner lambda is created first in the nodes array.
    var inner_lambda: ast.NodeIndex = .none;
    var outer_lambda: ast.NodeIndex = .none;

    for (pt.parser.b.tree.nodes.items, 0..) |node, i| {
        if (node.tag == .lambda_expr) {
            if (inner_lambda == .none) {
                inner_lambda = @enumFromInt(i);
            } else {
                outer_lambda = @enumFromInt(i);
            }
        }
    }

    try testing.expect(inner_lambda != .none);
    try testing.expect(outer_lambda != .none);

    // 1. Verify Outer Lambda captures 'x' directly from the 'outer' function locals
    const outer_captures = res.closure_captures.get(outer_lambda).?;
    try testing.expectEqual(@as(usize, 1), outer_captures.len);
    try testing.expectEqual(true, outer_captures[0].is_local);
    try testing.expectEqual(@as(u24, 0), outer_captures[0].index); // outer function's slot 0

    // 2. Verify Inner Lambda captures 'x' as an UPVALUE from the Outer Lambda
    const inner_captures = res.closure_captures.get(inner_lambda).?;
    try testing.expectEqual(@as(usize, 1), inner_captures.len);
    // It is NOT local to the outer lambda, so is_local must be false!
    try testing.expectEqual(false, inner_captures[0].is_local);
    // It targets the 0th upvalue index of the outer lambda's upvalue array
    try testing.expectEqual(@as(u24, 0), inner_captures[0].index);
}
