const std = @import("std");
const testing = std.testing;
const api = @import("api.zig");

test "Formatter: formats raw KupCAD code to expected layout" {
    const input_code = @embedFile("fixtures/format_in.kup");
    const expected_code = @embedFile("fixtures/format_out.kup");

    const allocator = testing.allocator;
    const formatted = try api.formatCode(allocator, input_code);
    defer allocator.free(formatted);

    try testing.expectEqualStrings(expected_code, formatted);
}
