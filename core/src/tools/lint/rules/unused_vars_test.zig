const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const UnusedVarsRule = @import("unused_vars.zig").UnusedVarsRule;
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    // Disable all default rules to strictly isolate the environment to just what we append below
    var engine = linter_mod.Linter.init(allocator, .{
        .check_negative_dims = false,
        .check_unused_vars = false,
        .check_unreachable_code = false,
        .check_self_subtraction = false,
        .check_param_docs = false,
    });

    var rule_impl = UnusedVarsRule{};
    try engine.rules.append(allocator, rule_impl.rule());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());

    const root = try parser.parseProgram();
    try engine.check(&parser.b.tree, root, parser.diagnostics.list.items);

    return engine;
}

test "Linter Rule: UnusedVarsRule catches unused variables" {
    const source =
        \\x = 10
        \\_y = 20
        \\z = 30
        \\cube(z)
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unused variable 'x'. Prefix with '_' if intentional.", engine.diagnostics.items[0].message);
}

test "Linter Rule: UnusedVarsRule detects usage across nested scopes" {
    const source =
        \\wall_thickness = 5.0
        \\begin
        \\  cube(wall_thickness)
        \\end
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "Linter Rule: UnusedVarsRule flags unused function parameters" {
    // Note: Since `build_part` is defined at the top level and never called, it WILL also trigger an unused warning!
    // We add a dummy call to `build_part` to ensure it is marked as used so we ONLY flag `height`.
    const source =
        \\def build_part(width, height)
        \\  cube(width)
        \\end
        \\build_part(10, 20)
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unused variable 'height'. Prefix with '_' if intentional.", engine.diagnostics.items[0].message);
}
