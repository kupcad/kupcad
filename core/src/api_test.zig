const std = @import("std");
const testing = std.testing;
const api = @import("api.zig");

test "Formatter: formats raw KupCAD code to expected layout" {
    const input_code = @embedFile("fixtures/format_in.kup");
    const expected_code = @embedFile("fixtures/format_out.kup");
    const allocator = testing.allocator;

    const formatted = try api.formatCode(allocator, input_code, .{});
    defer allocator.free(formatted);

    try testing.expectEqualStrings(expected_code, formatted);
}

test "Linter API: checkCode surfaces all expected diagnostics on bad fixture" {
    const bad_code = @embedFile("fixtures/linter_bad.kup");
    const allocator = testing.allocator;

    const diags = try api.checkCode(allocator, bad_code, .{});
    defer {
        for (diags) |d| allocator.free(d.message);
        allocator.free(diags);
    }

    // Must surface exactly 4 diagnostics (3 warnings, 1 info)
    try testing.expectEqual(@as(usize, 4), diags.len);

    // CSG Warning on Line 7
    try testing.expectEqual(.warning, diags[0].severity);
    try testing.expectEqual(@as(u32, 7), diags[0].loc.line);
    try testing.expectEqualStrings("CSG Warning: Self-difference operation ('a - a') will result in empty geometry.", diags[0].message);

    // Unreachable Code Warning on Line 11
    try testing.expectEqual(.warning, diags[1].severity);
    try testing.expectEqual(@as(u32, 11), diags[1].loc.line);
    try testing.expectEqualStrings("Unreachable code detected after explicit control flow return/break.", diags[1].message);

    // Unused Variable Warning on Line 3
    try testing.expectEqual(.warning, diags[2].severity);
    try testing.expectEqual(@as(u32, 3), diags[2].loc.line);
    try testing.expectEqualStrings("Unused variable 'unused_var'. Prefix with '_' if intentional.", diags[2].message);

    // ParamDoc Missing Reference Info on Line 1
    try testing.expectEqual(.info, diags[3].severity);
    try testing.expectEqual(@as(u32, 1), diags[3].loc.line);
    try testing.expectEqualStrings("@param annotation references variable 'missing_var', which is never declared in standard scope.", diags[3].message);
}
