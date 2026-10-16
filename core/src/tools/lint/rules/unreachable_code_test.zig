const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const UnreachableCodeRule = @import("unreachable_code.zig").UnreachableCodeRule;
const lint_testing = @import("../testing.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    return lint_testing.lint(allocator, source, lint_testing.only(UnreachableCodeRule.id));
}

test "Linter Rule: UnreachableCodeRule catches code after return" {
    const source =
        \\def check_flow()
        \\  return
        \\  cube()
        \\end
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unreachable: the statement before this always returns, breaks, nexts or raises", engine.diagnostics.items[0].message);
}

test "Linter Rule: UnreachableCodeRule catches code after break and next" {
    inline for (.{ "break", "next" }) |keyword| {
        const source = "while true\n  " ++ keyword ++ "\n  cube() # Unreachable\nend";
        var engine = try runRule(testing.allocator, source);
        defer engine.deinit();

        try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
        try testing.expectEqualStrings("Unreachable: the statement before this always returns, breaks, nexts or raises", engine.diagnostics.items[0].message);
    }
}

test "Linter Rule: UnreachableCodeRule offers to delete the dead lines, never as a safe fix" {
    const source = "def f\n  return 1\n  puts 2\n  puts 3\nend\nf\n";
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();
    const fix = engine.diagnostics.items[0].fix.?;
    try testing.expect(!fix.safe); // `check --fix` leaves dead code for its author
    try testing.expectEqual(@as(usize, 1), fix.edits.len);
    const e = fix.edits[0];
    try testing.expectEqualStrings("  puts 2\n  puts 3\n", source[e.offset .. e.offset + e.length]);
    try testing.expectEqualStrings("", e.replacement);
}
