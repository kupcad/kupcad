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
    defer api.freeDiagnostics(allocator, diags);

    // Must surface exactly 5 diagnostics:
    // 1. Unused variable 'unused_var'
    // 2. Unused variable 'check_flow'
    // 3. Self-subtraction
    // 4. Unreachable code
    // 5. Missing Param Doc
    try testing.expectEqual(@as(usize, 5), diags.len);

    var found_csg = false;
    var found_unreachable = false;
    var found_unused_var = false;
    var found_unused_flow = false;
    var found_missing_doc = false;

    for (diags) |d| {
        if (std.mem.indexOf(u8, d.message, "Self-difference") != null) found_csg = true;
        if (std.mem.indexOf(u8, d.message, "Unreachable code") != null) found_unreachable = true;
        if (std.mem.indexOf(u8, d.message, "Unused variable 'unused_var'") != null) found_unused_var = true;
        if (std.mem.indexOf(u8, d.message, "Unused variable 'check_flow'") != null) found_unused_flow = true;
        if (std.mem.indexOf(u8, d.message, "references variable 'missing_var'") != null) found_missing_doc = true;
    }

    try testing.expect(found_csg);
    try testing.expect(found_unreachable);
    try testing.expect(found_unused_var);
    try testing.expect(found_unused_flow);
    try testing.expect(found_missing_doc);
}
