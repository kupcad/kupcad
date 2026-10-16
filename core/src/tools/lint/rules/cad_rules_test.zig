const std = @import("std");
const testing = std.testing;
const lint_testing = @import("../testing.zig");

/// The one suggestion the single finding of `rule_id` in `source` makes, applied.
fn suggested(comptime rule_id: []const u8, source: []const u8) !?[]u8 {
    var engine = try lint_testing.lint(testing.allocator, source, lint_testing.only(rule_id));
    defer engine.deinit();
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    const fix = engine.diagnostics.items[0].fix orelse return null;
    try testing.expect(!fix.safe); // a guess at the intent: offered, never applied by --fix
    try testing.expectEqual(@as(usize, 1), fix.edits.len);
    const e = fix.edits[0];
    return try std.mem.concat(testing.allocator, u8, &.{ source[0..e.offset], e.replacement, source[e.offset + e.length ..] });
}

test "Lint: unknown-keyword suggests the nearest keyword, when one is clearly nearest" {
    const fixed = (try suggested("unknown-keyword", "cube(sise: 3)")).?;
    defer testing.allocator.free(fixed);
    try testing.expectEqualStrings("cube(size: 3)", fixed);
    try testing.expectEqual(@as(?[]u8, null), try suggested("unknown-keyword", "sphere(r: 2, colour: 1)"));
}

test "Lint: segments-as-sides suggests sides:, except with round_r: or chamfer:" {
    const fixed = (try suggested("segments-as-sides", "cylinder(d: 8, h: 5, segments: 6)")).?;
    defer testing.allocator.free(fixed);
    try testing.expectEqualStrings("cylinder(d: 8, h: 5, sides: 6)", fixed);
    try testing.expectEqual(@as(?[]u8, null), try suggested("segments-as-sides", "cylinder(r: 5, h: 9, segments: 6, chamfer: 1)"));
}
