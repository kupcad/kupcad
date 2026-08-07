const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const NegativeDimRule = @import("negative_dim.zig").NegativeDimRule;
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    var engine = linter_mod.Linter.init(allocator, .{});
    var rule_impl = NegativeDimRule{};
    try engine.rules.append(allocator, rule_impl.rule());

    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, allocator);
    const root = try parser.parseProgram();

    try engine.check(&parser.b.tree, root, parser.diagnostics.list.items);
    return engine;
}

test "Linter Rule: NegativeDimRule catches negative dimensions in method calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "cyl = Cylinder.new(r: -50, h: 20)";
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("CAD Warning: Property 'r' in primitive construction has non-positive dimension.", engine.diagnostics.items[0].message);
}

test "Linter Rule: NegativeDimRule catches negative dimensions in property assignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "box.width = -10";
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("CAD Warning: Property 'width' in primitive construction has non-positive dimension.", engine.diagnostics.items[0].message);
}

test "Linter Rule: NegativeDimRule ignores negative coordinates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "box = Box.new(x: -50, y: -20, z: -10)";
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "Linter Rule: NegativeDimRule catches negative dimensions inside arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "box = Box.new(size: [10, -20, 30])";
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("CAD Warning: Property 'size' in primitive construction has non-positive dimension.", engine.diagnostics.items[0].message);
}
