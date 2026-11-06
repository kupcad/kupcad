const std = @import("std");
const testing = std.testing;
const api = @import("../../api.zig");
const locus = @import("locus");
const brep_trace = @import("brep_trace.zig");

test "B-Rep trace: a script's transforms leave a numbered body file per phase, each a body that loads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);
    const phases = try brep_trace.run(testing.allocator, testing.io, "cube(1).translate(1, 0, 0).mirror(0, 0, 1)", .none, tmp.dir, &diag);
    try testing.expectEqual(@as(usize, 4), phases);
    try testing.expect(diag.message == null);
    for ([_][]const u8{ "001-transform-mapped.json", "002-transform-checked.json", "003-transform-mapped.json", "004-transform-checked.json" }) |name| {
        const text = try tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(text);
        var body = try locus.io.body_json.load(testing.allocator, text);
        body.deinit();
    }

    // A failing script keeps the phases before its failure, and says why it failed
    const before = try brep_trace.run(testing.allocator, testing.io, "cube(1).translate(1, 0, 0) + cube(2)", .none, tmp.dir, &diag);
    try testing.expectEqual(@as(usize, 2), before);
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "brep engine can't") != null);
}
