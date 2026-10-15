const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const SelfSubtractionRule = @import("self_subtraction.zig").SelfSubtractionRule;
const lint_testing = @import("../testing.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    return lint_testing.lint(allocator, source, lint_testing.only(SelfSubtractionRule.id));
}

test "Linter Rule: SelfSubtractionRule catches a - a" {
    const source = "result = part - part";
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("'part - part' subtracts a shape from itself, which leaves nothing", engine.diagnostics.items[0].message);
}
