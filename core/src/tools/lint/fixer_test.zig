const std = @import("std");
const testing = std.testing;
const linter = @import("linter.zig");
const fixer = @import("fixer.zig");

fn finding(edits: []linter.Edit, safe: bool) linter.LinterDiagnostic {
    return .{ .loc = .{ .offset = 0, .length = 0, .file_id = 0 }, .severity = .warning, .message = "", .origin = .{ .rule = "test" }, .fix = .{ .title = "", .edits = edits, .safe = safe } };
}

test "Fixer: applies safe fixes in source order, whatever order they come in" {
    var late = [_]linter.Edit{.{ .offset = 8, .length = 1, .replacement = "Z" }};
    var early = [_]linter.Edit{ .{ .offset = 0, .length = 1, .replacement = "_a" }, .{ .offset = 4, .length = 1, .replacement = "_a" } };
    const diags = [_]linter.LinterDiagnostic{ finding(&late, true), finding(&early, true) };
    const applied = (try fixer.applySafeFixes(testing.allocator, "a = a + b", &diags)).?;
    defer testing.allocator.free(applied.source);
    try testing.expectEqualStrings("_a = _a + Z", applied.source);
    try testing.expectEqual(@as(usize, 2), applied.fixes);
}

test "Fixer: leaves suggestions, and fixes that overlap one already taken, alone" {
    var first = [_]linter.Edit{.{ .offset = 0, .length = 3, .replacement = "xyz" }};
    var overlapping = [_]linter.Edit{.{ .offset = 2, .length = 2, .replacement = "!!" }};
    var same_place = [_]linter.Edit{.{ .offset = 0, .length = 0, .replacement = "#" }};
    var suggestion = [_]linter.Edit{.{ .offset = 4, .length = 1, .replacement = "?" }};
    const diags = [_]linter.LinterDiagnostic{ finding(&first, true), finding(&overlapping, true), finding(&same_place, true), finding(&suggestion, false) };
    const applied = (try fixer.applySafeFixes(testing.allocator, "abc d", &diags)).?;
    defer testing.allocator.free(applied.source);
    try testing.expectEqualStrings("xyz d", applied.source);
    try testing.expectEqual(@as(usize, 1), applied.fixes);

    // Nothing safe to apply: no new text.
    const only_suggestion = [_]linter.LinterDiagnostic{finding(&suggestion, false)};
    try testing.expectEqual(@as(?fixer.Applied, null), try fixer.applySafeFixes(testing.allocator, "abc d", &only_suggestion));
}
