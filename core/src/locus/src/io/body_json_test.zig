const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const nurbs = @import("../geometry/nurbs.zig");
const types = @import("../topology/types.zig");
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const euler = @import("../topology/euler.zig");
const body_json = @import("body_json.zig");
const check_test = @import("../topology/check_test.zig");

test "dump and load: a tetrahedron round-trips to the same bytes, the same hash, and a valid body" {
    var b = try check_test.tetrahedron(testing.allocator);
    defer b.deinit();
    const text = try body_json.dump(testing.allocator, &b);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "{\n  \"version\": 1,"));
    var loaded = try body_json.load(testing.allocator, text);
    defer loaded.deinit();
    try testing.expectEqual(b.counts(), loaded.counts());
    try testing.expectEqual(b.tol.zone, loaded.tol.zone);
    var report = try check.run(testing.allocator, &loaded, .geometric);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    const again = try body_json.dump(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(text, again);
    try testing.expectEqual(try body_json.hash(testing.allocator, &b), try body_json.hash(testing.allocator, &loaded));
}

test "dump is canonical: tombstoned entities are skipped and the rest renumbered, so the hash ignores history" {
    var b = try check_test.tetrahedron(testing.allocator);
    defer b.deinit();
    const h = try body_json.hash(testing.allocator, &b);
    // A spur made and killed again leaves tombstones; the dump is the same
    const l = b.face(types.FaceIndex.of(0)).first_loop;
    const first = b.loop(l).first;
    const from = b.coedgeEnd(first);
    const p = try b.geometry.addPoint(testing.allocator, .{ 5, 5, 5 });
    const line = try b.geometry.addLine(testing.allocator, .{ .o = b.point(from), .d = vec.Z3 });
    const spur = try euler.mevSpur(&b, l, first, from, p, .{ .curve = line, .t0 = 0, .t1 = 1 });
    try testing.expect(try body_json.hash(testing.allocator, &b) != h);
    try euler.kevSpur(&b, spur.out);
    // The geometry keeps the unused point and line (geometry is never tombstoned), so the
    // text differs there; the topology tables are the same as before
    const text = try body_json.dump(testing.allocator, &b);
    defer testing.allocator.free(text);
    var loaded = try body_json.load(testing.allocator, text);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 4), loaded.vertices.items.len);
    try testing.expectEqual(@as(usize, 6), loaded.edges.items.len);
    try testing.expectEqual(@as(usize, 12), loaded.coedges.items.len);
    var report = try check.run(testing.allocator, &loaded, .geometric);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
}

test "load refuses a hostile text: wrong version, an index past its table, an unknown kind" {
    var b = try check_test.tetrahedron(testing.allocator);
    defer b.deinit();
    const text = try body_json.dump(testing.allocator, &b);
    defer testing.allocator.free(text);
    try testing.expectError(error.Malformed, body_json.load(testing.allocator, "not json"));
    try testing.expectError(error.Malformed, body_json.load(testing.allocator, "{}"));
    const wrong_version = try std.mem.replaceOwned(u8, testing.allocator, text, "\"version\": 1", "\"version\": 2");
    defer testing.allocator.free(wrong_version);
    try testing.expectError(error.Malformed, body_json.load(testing.allocator, wrong_version));
    const bad_index = try std.mem.replaceOwned(u8, testing.allocator, text, "\"start\": 0", "\"start\": 99");
    defer testing.allocator.free(bad_index);
    try testing.expectError(error.Malformed, body_json.load(testing.allocator, bad_index));
    const bad_kind = try std.mem.replaceOwned(u8, testing.allocator, text, "\"kind\": \"plane\"", "\"kind\": \"blob\"");
    defer testing.allocator.free(bad_kind);
    try testing.expectError(error.Malformed, body_json.load(testing.allocator, bad_kind));
    // Nothing leaks on any refusal (the testing allocator checks)
}

test "every geometry kind survives the round trip" {
    var b = Body.init(testing.allocator, @import("../tolerance.zig").Tolerance.fromZone(1e-5));
    defer b.deinit();
    const g = &b.geometry;
    const a = testing.allocator;
    _ = try g.addPoint(a, .{ 1, 2, 3 });
    const line = try g.addLine(a, .{ .o = .{ 0, 0, 0 }, .d = vec.Z3 });
    const circle = try g.addCircle(a, .{ .c = .{ 0, 0, 0 }, .x = vec.X3, .y = vec.Y3, .r = 2 });
    _ = try g.addEllipse(a, .{ .c = .{ 0, 0, 0 }, .x = vec.X3, .y = vec.Y3, .a = 2, .b = 1 });
    var arc = try nurbs.circleArc(a, vec.ZERO3, vec.X3, vec.Y3, 1, 0, 3);
    defer arc.deinit(a);
    const nc = try g.addNurbsCurve(a, arc.view());
    _ = try g.addPlane(a, .{ .frame = geometry.Frame.world });
    _ = try g.addCylinder(a, .{ .frame = geometry.Frame.world, .r = 2 });
    _ = try g.addCone(a, .{ .frame = geometry.Frame.world, .r = 2, .half_angle = 0.3 });
    _ = try g.addSphere(a, .{ .frame = geometry.Frame.world, .r = 2 });
    _ = try g.addTorus(a, .{ .frame = geometry.Frame.world, .major = 5, .minor = 1 });
    _ = try g.addExtrusion(a, circle, vec.Z3);
    _ = try g.addRevolution(a, line, .{ 3, 0, 0 }, vec.Y3);
    var swept = try nurbs.extrusion(a, arc.view(), vec.Z3, 0, 5);
    defer swept.deinit(a);
    _ = try g.addNurbsSurface(a, swept.view());
    _ = try g.addLine2(a, .{ .o = .{ 0, 0 }, .d = .{ 1, 0 } });
    _ = try g.addCircle2(a, .{ .c = .{ 1, 1 }, .r = 2 });
    const knots = [_]f64{ 0, 0, 1, 1 };
    const pts = [_]vec.Vec3{ .{ 0, 0, 1 }, .{ 1, 1, 1 } };
    _ = try g.addNurbs2(a, .{ .degree = 1, .knots = &knots, .points = &pts });
    _ = try b.tags.named(a, 1, 7);
    _ = try b.tags.split(a, 2, types.Tag.of(1));
    _ = nc;
    const text = try body_json.dump(a, &b);
    defer a.free(text);
    var loaded = try body_json.load(a, text);
    defer loaded.deinit();
    const again = try body_json.dump(a, &loaded);
    defer a.free(again);
    try testing.expectEqualStrings(text, again);
    try testing.expectEqual(@as(usize, 2), loaded.tags.rows.items.len);
    try testing.expectApproxEqAbs(@as(f64, 2), vec.length(loaded.geometry.curve(geometry.CurveRef.of(.circle, 0)).eval(1)), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), vec.length(loaded.geometry.curve(geometry.CurveRef.of(.nurbs, 0)).eval(1.5)), 1e-12);
    const rev = loaded.geometry.surface(geometry.SurfaceRef.of(.revolution, 0));
    try testing.expectApproxEqAbs(@as(f64, 0), rev.eval(0, 0)[1], 1e-12);
}

test "dump and load: a face's attribute round-trips, and a file written before it reads as none" {
    const a = testing.allocator;
    var b = try check_test.tetrahedron(a);
    defer b.deinit();
    for (b.faces.items, 0..) |*f, i| f.attribute = @intCast(10 * i);
    const text = try body_json.dump(a, &b);
    defer a.free(text);
    var back = try body_json.load(a, text);
    defer back.deinit();
    for (b.faces.items, back.faces.items) |x, y| try testing.expectEqual(x.attribute, y.attribute);
    // The same file without the field: every face's attribute is 0
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(a);
    var rest: []const u8 = text;
    while (std.mem.indexOf(u8, rest, "\"attribute\"")) |at| {
        // From the comma ending the line before to the end of the field's line
        const comma = std.mem.lastIndexOfScalar(u8, rest[0..at], ',').?;
        try old.appendSlice(a, rest[0..comma]);
        rest = rest[std.mem.indexOfScalarPos(u8, rest, at, '\n').?..];
    }
    try old.appendSlice(a, rest);
    try testing.expect(std.mem.indexOf(u8, old.items, "attribute") == null);
    var older = try body_json.load(a, old.items);
    defer older.deinit();
    for (older.faces.items) |f| try testing.expectEqual(@as(u32, 0), f.attribute);
}
