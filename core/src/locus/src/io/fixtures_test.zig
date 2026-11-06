//! The primitives as body JSON, each against its fixture in src/fixtures: a change to a
//! primitive's bytes without a change to its geometry is a determinism bug; a meant change
//! is rewritten with `zig build test -Dupdate-snapshots` and reviewed like code.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const body_json = @import("body_json.zig");

const tol = Tolerance.fromZone(1e-5);

const Fixture = struct { name: []const u8, expected: []const u8 };

const FIXTURES = [_]Fixture{
    .{ .name = "box", .expected = @embedFile("../fixtures/box.json") },
    .{ .name = "cylinder", .expected = @embedFile("../fixtures/cylinder.json") },
    .{ .name = "sphere", .expected = @embedFile("../fixtures/sphere.json") },
    .{ .name = "cone", .expected = @embedFile("../fixtures/cone.json") },
    .{ .name = "torus", .expected = @embedFile("../fixtures/torus.json") },
    .{ .name = "extruded", .expected = @embedFile("../fixtures/extruded.json") },
    .{ .name = "square", .expected = @embedFile("../fixtures/square.json") },
    .{ .name = "circle", .expected = @embedFile("../fixtures/circle.json") },
    .{ .name = "polygon", .expected = @embedFile("../fixtures/polygon.json") },
    .{ .name = "even_odd", .expected = @embedFile("../fixtures/even_odd.json") },
    .{ .name = "polyhedron", .expected = @embedFile("../fixtures/polyhedron.json") },
};

/// The primitive named `name`, as the fixtures build it.
pub fn build(allocator: std.mem.Allocator, name: []const u8) !Body {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    if (std.mem.eql(u8, name, "box")) return primitives.box(allocator, tol, 10, 20, 30, false, &diag);
    if (std.mem.eql(u8, name, "cylinder")) return primitives.cylinder(allocator, tol, 5, 12, true, &diag);
    if (std.mem.eql(u8, name, "sphere")) return primitives.sphere(allocator, tol, 4, &diag);
    if (std.mem.eql(u8, name, "cone")) return primitives.cone(allocator, tol, 5, 0, 8, false, &diag);
    if (std.mem.eql(u8, name, "torus")) return primitives.torus(allocator, tol, 6, 1.5, &diag);
    if (std.mem.eql(u8, name, "extruded")) {
        // A plate with a round hole's worth of corners, swept up
        var plate = try primitives.polygonsEvenOdd(allocator, tol, &.{ &.{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } }, &.{ .{ -3, -3 }, .{ -3, 3 }, .{ 3, 3 }, .{ 3, -3 } } }, &diag);
        defer plate.deinit();
        return sweep.extrude(allocator, &plate, .{ 0, 0, 4 }, .{}, &diag);
    }
    if (std.mem.eql(u8, name, "square")) return primitives.square(allocator, tol, 4, 3, true, &diag);
    if (std.mem.eql(u8, name, "circle")) return primitives.circle(allocator, tol, 2.5, &diag);
    if (std.mem.eql(u8, name, "polygon")) return primitives.polygon(allocator, tol, &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 1 }, .{ 1, 3 } }, &diag);
    if (std.mem.eql(u8, name, "even_odd")) {
        const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
        const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
        return primitives.polygonsEvenOdd(allocator, tol, &.{ &outer, &inner }, &diag);
    }
    if (std.mem.eql(u8, name, "polyhedron")) {
        const pts = [_][3]f64{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 } };
        const tris = [_][3]u32{ .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 4 } };
        return primitives.polyhedron(allocator, tol, &pts, &tris, &diag);
    }
    unreachable;
}

test "fixtures: each primitive's body JSON is its fixture, byte for byte" {
    const update = @import("test_paths").update_snapshots;
    if (update and builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    for (FIXTURES) |f| {
        var body = try build(testing.allocator, f.name);
        defer body.deinit();
        const text = try body_json.dump(testing.allocator, &body);
        defer testing.allocator.free(text);
        if (update) {
            const path = try std.fs.path.join(testing.allocator, &.{ @import("test_paths").locus_dir, "src/fixtures", f.name });
            defer testing.allocator.free(path);
            const with_ext = try std.mem.concat(testing.allocator, u8, &.{ path, ".json" });
            defer testing.allocator.free(with_ext);
            var file = try std.Io.Dir.cwd().createFile(testing.io, with_ext, .{});
            defer file.close(testing.io);
            try file.writeStreamingAll(testing.io, text);
            continue;
        }
        errdefer std.debug.print("fixture {s} differs: rerun with -Dupdate-snapshots and review the diff\n", .{f.name});
        try testing.expectEqualStrings(f.expected, text);
        // And it reads back as a valid body with the same hash
        var loaded = try body_json.load(testing.allocator, text);
        defer loaded.deinit();
        try testing.expectEqual(try body_json.hash(testing.allocator, &body), try body_json.hash(testing.allocator, &loaded));
    }
}
