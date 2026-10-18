const std = @import("std");
const testing = std.testing;
const check_output = @import("check_output.zig");
const api = @import("../api.zig");
const suppressions = @import("../tools/lint/suppressions.zig");

test "SARIF: every result names a declared rule and every path is a URI" {
    // Code scanning rejected the file: raw paths with spaces, suppression results naming
    // a rule the run didn't declare, and syntax errors with no ruleId at all (each is now
    // under its own code).
    var collector = check_output.Collector.init(testing.allocator);
    defer collector.deinit();
    const diags = [_]api.LinterDiagnostic{
        .{ .loc = .{ .offset = 0, .length = 3, .file_id = 0 }, .severity = .@"error", .message = "unexpected token", .origin = .{ .error_code = .@"unexpected-token" } },
        .{ .loc = .{ .offset = 4, .length = 1, .file_id = 0 }, .severity = .warning, .message = "nothing to suppress", .origin = .{ .rule = suppressions.RULE } },
        .{ .loc = .{ .offset = 4, .length = 1, .file_id = 0 }, .severity = .info, .message = "unused", .origin = .{ .rule = "unused-variable" } },
    };
    try collector.add("my parts/ünit#1.kup", "x = 1\ny = 2\n", &diags);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try collector.writeSarif(&out.writer);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();

    const run = parsed.value.object.get("runs").?.array.items[0].object;
    const rules = run.get("tool").?.object.get("driver").?.object.get("rules").?.array.items;
    const results = run.get("results").?.array.items;
    try testing.expectEqual(@as(usize, 3), results.len);
    for (results) |r| {
        const rule_id = r.object.get("ruleId").?.string;
        var declared = false;
        for (rules) |rule| declared = declared or std.mem.eql(u8, rule.object.get("id").?.string, rule_id);
        try testing.expect(declared);
        const location = r.object.get("locations").?.array.items[0].object.get("physicalLocation").?.object;
        try testing.expectEqualStrings("my%20parts/%C3%BCnit%231.kup", location.get("artifactLocation").?.object.get("uri").?.string);
        try testing.expect(location.get("region").?.object.get("startLine").?.integer >= 1);
        try testing.expect(location.get("region").?.object.get("startColumn").?.integer >= 1);
    }
    try testing.expectEqualStrings("unexpected-token", results[0].object.get("ruleId").?.string);
    try testing.expectEqualStrings("note", results[2].object.get("level").?.string);
}
