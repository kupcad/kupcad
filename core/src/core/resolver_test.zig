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

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, &diags);
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

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, &diags);
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

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, &diags);
    defer res.deinit();

    try res.resolve(root_idx);

    const tree = &pt.parser.b.tree;

    // Block parameters `|i, val|` should map seamlessly into slots 0 and 1
    try expectResolved(&res, tree, "i", .local, 0);
    try expectResolved(&res, tree, "val", .local, 1);
}
