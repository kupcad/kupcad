const std = @import("std");
const testing = std.testing;
const ast = @import("../../../core/ast.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const linter_mod = @import("../linter.zig");
const NegativeDimRule = @import("negative_dim.zig").NegativeDimRule;

fn walkAndCheck(node: *ast.Node, rule: @import("rule.zig").LintRule, diags: *std.ArrayListUnmanaged(linter_mod.LinterDiagnostic), allocator: std.mem.Allocator) !void {
    try rule.checkNode(node, diags, allocator);

    // Minimal walker for testing purposes to reach expressions
    switch (node.kind) {
        .block => |b| for (b.stmts) |stmt| try walkAndCheck(stmt, rule, diags, allocator),
        .assignment => |a| try walkAndCheck(a.value, rule, diags, allocator),
        .property_assignment => |pa| try walkAndCheck(pa.value, rule, diags, allocator),
        .method_call => |mc| {
            if (mc.receiver) |r| try walkAndCheck(r, rule, diags, allocator);
            for (mc.args) |arg| try walkAndCheck(arg.value, rule, diags, allocator);
        },
        else => {},
    }
}

test "Linter Rule: NegativeDimRule catches negative dimensions in method calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "box = Box.new(x: -50, y: 20)";
    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());

    const tree = try parser.parseProgram();

    var diags: std.ArrayListUnmanaged(linter_mod.LinterDiagnostic) = .empty;
    var rule_impl = NegativeDimRule{};

    try walkAndCheck(tree, rule_impl.rule(), &diags, arena.allocator());

    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqualStrings("CAD Warning: Property 'x' in primitive construction has non-positive dimension.", diags.items[0].message);
}

test "Linter Rule: NegativeDimRule catches negative dimensions in property assignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "box.width = -10";
    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());

    const tree = try parser.parseProgram();

    var diags: std.ArrayListUnmanaged(linter_mod.LinterDiagnostic) = .empty;
    var rule_impl = NegativeDimRule{};

    try walkAndCheck(tree, rule_impl.rule(), &diags, arena.allocator());

    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqualStrings("CAD Warning: Property 'width' in primitive construction has non-positive dimension.", diags.items[0].message);
}
