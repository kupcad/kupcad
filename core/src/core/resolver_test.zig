const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const resolver = @import("resolver.zig");
const errors = @import("errors.zig");

// Use the existing KupCAD parser test utility
const Lexer = @import("../frontend/lexer.zig").Lexer;
const Parser = @import("../frontend/parser.zig").Parser;
const ParserTest = @import("../frontend/test_utils.zig").ParserTest;
const KTest = ParserTest(Lexer, Parser);

/// Scans the AST for the `.identifier` nodes named `name`, and asserts that the Resolver gave
/// at least one of them the kind `expected_kind`.
fn expectResolved(res: *const resolver.Resolver, tree: *const ast.Tree, name: []const u8, expected_kind: resolver.ScopeKind) !void {
    for (tree.nodes.items, 0..) |node, i| {
        if (node.tag != .identifier or !std.mem.eql(u8, tree.nodeString(&node), name)) continue;
        // Because Parsers often leave "dead" orphan nodes behind when transforming
        // expressions into assignments, we just want to ensure the "live" node was resolved!
        if (res.symbols[i] == expected_kind) return;
    }
    std.debug.print("Resolved Identifier '{s}' not found as {any}\n", .{ name, expected_kind });
    return error.TestExpectedEqual;
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

    // Parameters and declared variables are locals
    try expectResolved(&res, tree, "x", .local);
    try expectResolved(&res, tree, "y", .local);

    // Explicit syntax prefixes are instantly categorized
    try expectResolved(&res, tree, "@inst", .instance_var);
    try expectResolved(&res, tree, "$glob", .global);

    // Undeclared variables fall back to global runtime lookups
    try expectResolved(&res, tree, "missing", .global);
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

    // 'x' crosses a lambda boundary, making it an upvalue
    try expectResolved(&res, tree, "x", .upvalue);

    // 'y' belongs to the lambda's own scope, making it a local
    try expectResolved(&res, tree, "y", .local);
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

    // Block parameters `|i, val|` are the block's locals
    try expectResolved(&res, tree, "i", .local);
    try expectResolved(&res, tree, "val", .local);
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

test "Resolver: a lambda allows next but not break" {
    // A lambda behaves like a block: `next` leaves it, but there is no iteration to break.
    const source =
        \\f = ->(x) { next x }
        \\g = ->(x) { break x }
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const root_idx = try pt.parser.parseProgram();

    var diags = errors.Diagnostics.init(testing.allocator);
    defer diags.deinit();

    var res = try resolver.Resolver.init(testing.allocator, &pt.parser.b.tree, pt.parser.tokens.starts, pt.parser.tokens.lengths, &diags);
    defer res.deinit();

    try res.resolve(root_idx);

    try testing.expectEqual(@as(usize, 1), diags.list.items.len);
    try testing.expectEqualStrings("Cannot use 'break' outside of a loop", diags.list.items[0].message);
}

test "Resolver: a script variable read inside a def or a block is a global, as when it runs" {
    const source =
        \\width = 4
        \\def f
        \\  width
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
    try expectResolved(&res, &pt.parser.b.tree, "width", .global);
}

test "Resolver: a name of a closure two levels out is an upvalue" {
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
    try expectResolved(&res, &pt.parser.b.tree, "x", .upvalue);
}

test "Resolver: an if, while or case body is no scope, as in the parser, linter and compiler" {
    // A name an `if` body assigned was resolved as a global after it: hover was wrong and
    // go-to-definition found nothing.
    const source =
        \\def f(c)
        \\  if c
        \\    y = 2
        \\  end
        \\  while c
        \\    w = 1
        \\    c = false
        \\  end
        \\  case c
        \\  when 1 then v = 3
        \\  end
        \\  y + w + v
        \\end
    ;
    var doc = try @import("../frontend/document.zig").Document.parse(testing.allocator, source);
    defer doc.deinit();
    const tree = &doc.tree;
    var checked: usize = 0;
    for (tree.nodes.items, 0..) |node, i| {
        if (node.tag != .identifier or doc.parents[i] == .none) continue;
        const name = tree.nodeString(&node);
        if (name.len != 1 or std.mem.indexOfScalar(u8, "ywv", name[0]) == null) continue;
        errdefer std.debug.print("{s}\n", .{name});
        try testing.expectEqual(resolver.ScopeKind.local, doc.symbols[i]);
        try testing.expectEqual(ast.Tag.assignment, tree.getNode(doc.declarations[i]).?.tag);
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 3), checked);
}

test "Resolver: a call's block, a super's included, is a scope its names end with" {
    const source =
        \\[1].each { |a| b = a }
        \\b
        \\class C < D
        \\  def m
        \\    super { |s| s }
        \\  end
        \\end
    ;
    var doc = try @import("../frontend/document.zig").Document.parse(testing.allocator, source);
    defer doc.deinit();
    const tree = &doc.tree;
    const root_stmts = tree.getNodes(tree.block(tree.getNode(tree.root).?).stmts);
    // The `b` after the block is no local of the script
    try testing.expectEqual(resolver.ScopeKind.global, doc.symbols[@backingInt(root_stmts[1])]);
    // `s`, the parameter of super's block, is a local of it
    for (tree.nodes.items, 0..) |node, i| {
        if (node.tag != .identifier or !std.mem.eql(u8, tree.nodeString(&node), "s") or doc.parents[i] == .none) continue;
        try testing.expectEqual(resolver.ScopeKind.local, doc.symbols[i]);
        try testing.expectEqual(ast.Tag.block, tree.getNode(doc.declarations[i]).?.tag);
        return;
    }
    return error.NoUseOfS;
}

test "Resolver: correctly classifies class variables (@@) separately from instance variables (@)" {
    const source =
        \\def check
        \\  a = @instance
        \\  b = @@class_var
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

    // Instance variables start with single '@'
    try expectResolved(&res, tree, "@instance", .instance_var);

    // Class variables start with '@@' and resolve to .global (not .instance_var)
    try expectResolved(&res, tree, "@@class_var", .global);
}

test "Resolver: a local's or an upvalue's use records the node that declared it" {
    const Document = @import("../frontend/document.zig").Document;
    const source =
        \\a = 1
        \\def f(p)
        \\  p + a
        \\end
        \\[1].each { |q| q }
        \\a = 2
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    const tree = &doc.tree;
    // The live nodes: the ones the parent map reaches (the parser leaves orphans behind)
    var first_assignment: ast.NodeIndex = .none;
    var checked: usize = 0;
    for (tree.nodes.items, 0..) |node, i| {
        const idx: ast.NodeIndex = @fromBackingInt(@as(u32, @intCast(i)));
        if (doc.parents[i] == .none and idx != tree.root) continue;
        const declared = doc.declarations[i];
        switch (node.tag) {
            .assignment => {
                if (first_assignment == .none) first_assignment = idx;
                // Both assignments of `a` are declared by the first
                try testing.expectEqual(first_assignment, declared);
                checked += 1;
            },
            .identifier => {
                const name = tree.nodeString(&node);
                const by = tree.getNode(declared) orelse return error.NoDeclaration;
                const expected: ast.Tag = if (std.mem.eql(u8, name, "p")) .def_stmt else if (std.mem.eql(u8, name, "a")) .assignment else .block;
                errdefer std.debug.print("{s}: {s}\n", .{ name, @tagName(by.tag) });
                try testing.expectEqual(expected, by.tag);
                if (std.mem.eql(u8, name, "a")) try testing.expectEqual(first_assignment, declared);
                checked += 1;
            },
            else => {},
        }
    }
    // The two assignments, p, a and q's use (declared by the block, whose parameter it is)
    try testing.expectEqual(@as(usize, 5), checked);
}
