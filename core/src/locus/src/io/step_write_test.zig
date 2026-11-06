const std = @import("std");
const testing = std.testing;
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const primitives = @import("../construct/primitives.zig");
const step_write = @import("step_write.zig");

const tol = Tolerance.fromZone(1e-5);

fn count(text: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, text, needle);
}

test "step: a box is one solid of eight vertices, twelve edges, six faces, written once each" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.box(testing.allocator, tol, 2.1, 3, 4, false, &diag);
    defer b.deinit();
    const text = try step_write.write(testing.allocator, &.{&b});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "ISO-10303-21;\nHEADER;"));
    try testing.expect(std.mem.endsWith(u8, text, "ENDSEC;\nEND-ISO-10303-21;\n"));
    try testing.expectEqual(@as(usize, 8), count(text, "=VERTEX_POINT("));
    try testing.expectEqual(@as(usize, 12), count(text, "=EDGE_CURVE("));
    try testing.expectEqual(@as(usize, 12), count(text, "=LINE("));
    try testing.expectEqual(@as(usize, 24), count(text, "=ORIENTED_EDGE("));
    try testing.expectEqual(@as(usize, 6), count(text, "=EDGE_LOOP("));
    try testing.expectEqual(@as(usize, 6), count(text, "=FACE_OUTER_BOUND("));
    try testing.expectEqual(@as(usize, 6), count(text, "=PLANE("));
    try testing.expectEqual(@as(usize, 6), count(text, "=ADVANCED_FACE("));
    try testing.expectEqual(@as(usize, 1), count(text, "=CLOSED_SHELL("));
    try testing.expectEqual(@as(usize, 1), count(text, "=MANIFOLD_SOLID_BREP("));
    // Numbers at full precision, with a decimal point: 2.1 is "2.1", 0 is "0.", 4 is "4."
    try testing.expect(count(text, "(2.1,") > 0);
    try testing.expect(count(text, "2.100000") == 0);
    try testing.expect(count(text, "(0.,0.,0.)") > 0);
    try testing.expect(count(text, ",4.)") > 0);
    // The uncertainty is the body's zone
    try testing.expect(count(text, "LENGTH_MEASURE(0.00001)") == 1);
    // Every entity referenced exists: the ids are 1..n with no gap
    var max_id: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len < 2 or line[0] != '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        max_id = @max(max_id, try std.fmt.parseInt(u32, line[1..eq], 10));
    }
    try testing.expectEqual(@as(usize, max_id), count(text, "\n#") + 1);
}

test "step: a cylinder writes its circles and cylindrical surface; two bodies; a sheet is refused" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var c = try primitives.cylinder(testing.allocator, tol, 2.5, 10, true, &diag);
    defer c.deinit();
    const text = try step_write.write(testing.allocator, &.{&c});
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 4), count(text, "=VERTEX_POINT("));
    try testing.expectEqual(@as(usize, 6), count(text, "=EDGE_CURVE("));
    try testing.expectEqual(@as(usize, 4), count(text, "=CIRCLE("));
    try testing.expectEqual(@as(usize, 2), count(text, "=LINE("));
    try testing.expectEqual(@as(usize, 2), count(text, "=CYLINDRICAL_SURFACE("));
    try testing.expectEqual(@as(usize, 2), count(text, "=PLANE("));
    try testing.expectEqual(@as(usize, 4), count(text, "=ADVANCED_FACE("));
    try testing.expect(count(text, ",2.5)") >= 4);

    var b = try primitives.box(testing.allocator, tol, 1, 1, 1, false, &diag);
    defer b.deinit();
    const two = try step_write.write(testing.allocator, &.{ &c, &b });
    defer testing.allocator.free(two);
    try testing.expectEqual(@as(usize, 2), count(two, "=MANIFOLD_SOLID_BREP("));
    try testing.expect(count(two, "ADVANCED_BREP_SHAPE_REPRESENTATION('',(#17,#18)") == 1);

    var sq = try primitives.square(testing.allocator, tol, 1, 1, false, &diag);
    defer sq.deinit();
    try testing.expectError(error.NotSolid, step_write.write(testing.allocator, &.{&sq}));
    try testing.expectError(error.NotSolid, step_write.write(testing.allocator, &.{}));
}
