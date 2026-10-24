const std = @import("std");
const testing = std.testing;
const lint_finding = @import("finding.zig");
const linter = @import("linter.zig");
const LineIndex = @import("../../core/line_index.zig").LineIndex;

const Edit = struct { line: u32, column: u32, endLine: u32, endColumn: u32, offset: u32, length: u32, text: []const u8 };
const Json = struct {
    line: u32,
    column: u32,
    endLine: u32,
    endColumn: u32,
    offset: u32,
    length: u32,
    severity: []const u8,
    rule: ?[]const u8,
    code: []const u8,
    message: []const u8,
    fix: ?struct { title: []const u8, safe: bool, edits: []const Edit },
};

/// `diag` in `source`, placed and written as JSON, read back strictly (a field missing or
/// added fails).
fn written(arena: std.mem.Allocator, source: []const u8, diag: linter.LinterDiagnostic) !Json {
    const line_index = try LineIndex.init(arena, source);
    const finding = try lint_finding.Finding.place(arena, &line_index, diag);
    const text = try std.json.Stringify.valueAlloc(arena, finding, .{});
    return std.json.parseFromSliceLeaky(Json, arena, text, .{});
}

test "finding: placed by line and UTF-8 column, by offset and length, its fix's edits too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `größe` takes 7 bytes: the column after it counts them
    const source = "größe = 1\nx = größe\n";
    var edits = [_]linter.Edit{.{ .offset = 0, .length = 7, .replacement = "_größe" }};
    const diag: linter.LinterDiagnostic = .{
        .loc = .{ .offset = 0, .length = 7, .file_id = 0 },
        .severity = .warning,
        .message = "Unused variable 'größe'.",
        .origin = .{ .rule = "unused-variable" },
        .fix = .{ .title = "Rename 'größe' to '_größe'", .edits = &edits, .safe = true },
    };
    const json = try written(arena.allocator(), source, diag);
    try testing.expectEqual(@as(u32, 1), json.line);
    try testing.expectEqual(@as(u32, 1), json.column);
    try testing.expectEqual(@as(u32, 8), json.endColumn);
    try testing.expectEqual(@as(u32, 0), json.offset);
    try testing.expectEqual(@as(u32, 7), json.length);
    try testing.expectEqualStrings("warning", json.severity);
    try testing.expectEqualStrings("unused-variable", json.rule.?);
    try testing.expectEqualStrings("unused-variable", json.code);
    try testing.expect(json.fix.?.safe);
    try testing.expectEqualStrings("_größe", json.fix.?.edits[0].text);
    try testing.expectEqual(@as(u32, 8), json.fix.?.edits[0].endColumn);

    // A syntax error: on the second line, no rule's, no fix
    const syntax: linter.LinterDiagnostic = .{ .loc = .{ .offset = 14, .length = 1, .file_id = 0 }, .severity = .@"error", .message = "unexpected", .origin = .{ .error_code = .@"unexpected-token" } };
    const err_json = try written(arena.allocator(), source, syntax);
    try testing.expectEqual(@as(u32, 2), err_json.line);
    try testing.expectEqual(@as(u32, 3), err_json.column);
    try testing.expectEqual(@as(?[]const u8, null), err_json.rule);
    try testing.expectEqualStrings("unexpected-token", err_json.code);
    try testing.expect(err_json.fix == null);
}
