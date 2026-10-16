const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const ParamOrderRule = @import("param_order.zig").ParamOrderRule;
const lint_testing = @import("../testing.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    return lint_testing.lint(allocator, source, lint_testing.only(ParamOrderRule.id));
}

test "Linter Rule: ParamOrderRule warns on usage before definition" {
    const source =
        \\x = param(:width)
        \\param(:width, default: 20)
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Parameter ':width' used before definition.", engine.diagnostics.items[0].message);
}

test "Linter Rule: ParamOrderRule warns on parameter definitions inside functions" {
    const source =
        \\def build_part()
        \\  param(:height, default: 10)
        \\end
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Parameter ':height' definition should be placed at the top level for static UI extraction.", engine.diagnostics.items[0].message);
}

test "Linter Rule: ParamOrderRule passes on clean top-level definitions" {
    const source =
        \\param(:width, default: 20)
        \\box = cube(param(:width))
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "Linter Rule: ParamOrderRule warns on a definition in any body, an if's included" {
    var engine = try runRule(testing.allocator, "if ok\n  param(:height, default: 10)\nend");
    defer engine.deinit();
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
}
