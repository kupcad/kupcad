const std = @import("std");
const testing = std.testing;
const linter_mod = @import("linter.zig");
const token = @import("../../core/token.zig");

test "Linter: Initializes and deinitializes correctly" {
    var linter = linter_mod.Linter.init(testing.allocator, .{});
    defer linter.deinit();

    try testing.expectEqual(@as(usize, 0), linter.diagnostics.items.len);
    try testing.expectEqual(@as(usize, 0), linter.scopes.items.len);
    try testing.expectEqual(@as(usize, 0), linter.rules.items.len);
}

test "Linter: Registers default rules based on config" {
    // Selectively enable specific rules
    var linter = linter_mod.Linter.init(testing.allocator, .{
        .check_negative_dims = true,
        .check_unused_vars = false,
        .check_unreachable_code = true,
        .check_self_subtraction = false,
        .check_param_docs = false,
    });
    defer linter.deinit();

    try linter.registerDefaultRules();

    // Should only have registered the 2 rules we enabled
    try testing.expectEqual(@as(usize, 2), linter.rules.items.len);
    try testing.expectEqualStrings("Negative Dimension Check", linter.rules.items[0].vtable.name(linter.rules.items[0].ptr));
    try testing.expectEqualStrings("Unreachable Code Check", linter.rules.items[1].vtable.name(linter.rules.items[1].ptr));
}

test "Linter: Formats and stores custom diagnostics safely" {
    var linter = linter_mod.Linter.init(testing.allocator, .{});
    defer linter.deinit();

    const loc = token.Location{ .line = 1, .col = 5, .offset = 4, .length = 1, .file_id = 0 };

    // Call the format helper
    try linter.addDiagnostic(loc, .warning, "Found issue in {s} at index {d}", .{ "cube", 42 });

    try testing.expectEqual(@as(usize, 1), linter.diagnostics.items.len);
    try testing.expectEqualStrings("Found issue in cube at index 42", linter.diagnostics.items[0].message);
    try testing.expectEqual(linter_mod.DiagnosticSeverity.warning, linter.diagnostics.items[0].severity);
    try testing.expectEqual(@as(u32, 1), linter.diagnostics.items[0].loc.line);
}

test "Linter: Surfaces syntax errors from the Parser as Linter Diagnostics" {
    var linter = linter_mod.Linter.init(testing.allocator, .{});
    defer linter.deinit();

    // Intentionally bad syntax to trigger a parser error
    const source = "val = 10 + }";

    // The linter should catch the parser error and map it to a diagnostic
    try linter.check(source);

    try testing.expect(linter.diagnostics.items.len > 0);
    try testing.expectEqual(linter_mod.DiagnosticSeverity.@"error", linter.diagnostics.items[0].severity);
    try testing.expectEqualStrings("Invalid expression starting with '}'", linter.diagnostics.items[0].message);
}
