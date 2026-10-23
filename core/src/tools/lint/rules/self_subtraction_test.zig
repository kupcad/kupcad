const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const SelfSubtractionRule = @import("self_subtraction.zig").SelfSubtractionRule;
const lint_testing = @import("../testing.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    return lint_testing.lint(allocator, source, lint_testing.only(SelfSubtractionRule.id));
}

test "Linter Rule: SelfSubtractionRule catches a shape taken from itself, by - or difference" {
    const cases = [_]struct { source: []const u8, message: ?[]const u8 }{
        .{ .source = "part = cube(1)\nresult = part - part", .message = "'part - part' subtracts a shape from itself, which leaves nothing" },
        .{ .source = "s = square(1)\nresult = s.difference(s)", .message = "'s.difference(s)' subtracts a shape from itself, which leaves nothing" },
        // A number taken from itself is 0, as meant; a value of unknown kind may be one
        .{ .source = "n = 5\nresult = n - n", .message = null },
        .{ .source = "result = part - part", .message = null },
        .{ .source = "part = cube(1)\nresult = part.difference(part, part)", .message = null },
    };
    for (cases) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.source});
        var engine = try runRule(testing.allocator, case.source);
        defer engine.deinit();
        if (case.message) |message| {
            try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
            try testing.expectEqualStrings(message, engine.diagnostics.items[0].message);
        } else try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
    }
}
