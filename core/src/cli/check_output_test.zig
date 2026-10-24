const std = @import("std");
const testing = std.testing;
const check_output = @import("check_output.zig");
const api = @import("../api.zig");
const suppressions = @import("../tools/lint/suppressions.zig");
const lint_finding = @import("../tools/lint/finding.zig");

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

test "JSON: each finding is its path, then the finding every host gets (tools/lint/finding.zig)" {
    // `check --format json` and the browser's check_code_wasm write one shape: the CLI's
    // with the file's path first, and nothing else between them differs
    const source = "x = 1\ncube(-2)\n";
    var collector = check_output.Collector.init(testing.allocator);
    defer collector.deinit();
    const diags = try api.checkCode(testing.allocator, testing.io, source, .{});
    defer api.freeDiagnostics(testing.allocator, diags);
    try collector.add("part.kup", source, diags);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try collector.writeJson(&out.writer, .{ .files = 1, .errors = 0, .warnings = diags.len, .infos = 0 });
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const findings = parsed.value.object.get("findings").?.array.items;
    try testing.expectEqual(diags.len, findings.len);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line_index = try api.LineIndex.init(arena.allocator(), source);
    for (findings, diags) |cli, d| {
        try testing.expectEqualStrings("part.kup", cli.object.get("path").?.string);
        const alone = try std.json.Stringify.valueAlloc(arena.allocator(), try lint_finding.Finding.place(arena.allocator(), &line_index, d), .{});
        const host = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), alone, .{});
        // The CLI's keys are "path" and the host's, in the host's order
        const keys = cli.object.keys();
        try testing.expectEqualStrings("path", keys[0]);
        try testing.expectEqual(host.object.count(), keys.len - 1);
        for (keys[1..], host.object.keys()) |a, b| try testing.expectEqualStrings(b, a);
        const cli_text = try std.json.Stringify.valueAlloc(arena.allocator(), cli.object.get("offset").?, .{});
        const host_text = try std.json.Stringify.valueAlloc(arena.allocator(), host.object.get("offset").?, .{});
        try testing.expectEqualStrings(host_text, cli_text);
    }
}
