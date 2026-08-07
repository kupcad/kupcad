const std = @import("std");
const testing = std.testing;
const ast = @import("../../../core/ast.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const linter_mod = @import("../linter.zig");
const NegativeDimRule = @import("negative_dim.zig").NegativeDimRule;

fn walkAndCheck(engine: *linter_mod.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex, rule: @import("rule.zig").LintRule) !void {
    if (node_idx == .none) return;
    const node = tree.getNode(node_idx) orelse return;

    try rule.checkNode(engine, tree, node_idx);

    // Minimal walker for testing purposes to reach expressions
    switch (node.kind) {
        .block => |b| for (b.stmts) |stmt| try walkAndCheck(engine, tree, stmt, rule),
        .assignment => |a| try walkAndCheck(engine, tree, a.value, rule),
        .property_assignment => |pa| try walkAndCheck(engine, tree, pa.value, rule),
        .method_call => |mc| {
            if (mc.receiver != .none) try walkAndCheck(engine, tree, mc.receiver, rule);
            for (mc.args) |arg| try walkAndCheck(engine, tree, arg.value, rule);
        },
        else => {},
    }
}

test "Linter Rule: NegativeDimRule catches negative dimensions in method calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "cyl = Cylinder.new(r: -50, h: 20)";
    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());

    const tree_root = try parser.parseProgram();

    var engine = linter_mod.Linter.init(arena.allocator(), .{});
    defer engine.deinit();

    var rule_impl = NegativeDimRule{};
    try walkAndCheck(&engine, &parser.b.tree, tree_root, rule_impl.rule());

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("CAD Warning: Property 'r' in primitive construction has non-positive dimension.", engine.diagnostics.items[0].message);
}

test "Linter Rule: NegativeDimRule catches negative dimensions in property assignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "box.width = -10";
    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());

    const tree_root = try parser.parseProgram();

    var engine = linter_mod.Linter.init(arena.allocator(), .{});
    defer engine.deinit();

    var rule_impl = NegativeDimRule{};
    try walkAndCheck(&engine, &parser.b.tree, tree_root, rule_impl.rule());

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("CAD Warning: Property 'width' in primitive construction has non-positive dimension.", engine.diagnostics.items[0].message);
}

test "Linter Rule: NegativeDimRule ignores negative coordinates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "box = Box.new(x: -50, y: -20, z: -10)";
    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());

    const tree_root = try parser.parseProgram();

    var engine = linter_mod.Linter.init(arena.allocator(), .{});
    defer engine.deinit();

    var rule_impl = NegativeDimRule{};
    try walkAndCheck(&engine, &parser.b.tree, tree_root, rule_impl.rule());

    // Should be zero diagnostics!
    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "Linter Rule: NegativeDimRule catches negative dimensions inside arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "box = Box.new(size: [10, -20, 30])";
    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());
    const tree_root = try parser.parseProgram();

    var engine = linter_mod.Linter.init(arena.allocator(), .{});
    defer engine.deinit();

    var rule_impl = NegativeDimRule{};
    try walkAndCheck(&engine, &parser.b.tree, tree_root, rule_impl.rule());

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("CAD Warning: Property 'size' in primitive construction has non-positive dimension.", engine.diagnostics.items[0].message);
}
