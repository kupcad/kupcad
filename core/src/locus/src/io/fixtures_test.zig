//! The primitives and a few boolean results as body JSON, each against its fixture in
//! src/fixtures, natively and under wasmtime (§6: the same bytes on every target): a change
//! to the bytes without a change to the geometry is a determinism bug; a meant change is
//! rewritten with `zig build test -Dupdate-snapshots` and reviewed like code. The booleans
//! are a corner union, a void, a chain and a cut by a slanted plane, whose vertices are
//! rounded: the arithmetic the targets must agree on to the last bit.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const transform = @import("../construct/transform.zig");
const mat = @import("../math/mat.zig");
const vec = @import("../math/vec.zig");
const body_json = @import("body_json.zig");
const pipeline = @import("../boolean/pipeline.zig");
const trim = @import("../boolean/trim.zig");

const tol = Tolerance.fromZone(1e-5);

const Fixture = struct { name: []const u8, expected: []const u8 };

const FIXTURES = [_]Fixture{
    .{ .name = "box", .expected = @embedFile("../fixtures/box.json") },
    .{ .name = "cylinder", .expected = @embedFile("../fixtures/cylinder.json") },
    .{ .name = "sphere", .expected = @embedFile("../fixtures/sphere.json") },
    .{ .name = "cone", .expected = @embedFile("../fixtures/cone.json") },
    .{ .name = "torus", .expected = @embedFile("../fixtures/torus.json") },
    .{ .name = "extruded", .expected = @embedFile("../fixtures/extruded.json") },
    .{ .name = "revolved", .expected = @embedFile("../fixtures/revolved.json") },
    .{ .name = "square", .expected = @embedFile("../fixtures/square.json") },
    .{ .name = "circle", .expected = @embedFile("../fixtures/circle.json") },
    .{ .name = "polygon", .expected = @embedFile("../fixtures/polygon.json") },
    .{ .name = "even_odd", .expected = @embedFile("../fixtures/even_odd.json") },
    .{ .name = "polyhedron", .expected = @embedFile("../fixtures/polyhedron.json") },
    .{ .name = "corner_union", .expected = @embedFile("../fixtures/corner_union.json") },
    .{ .name = "void", .expected = @embedFile("../fixtures/void.json") },
    .{ .name = "chain", .expected = @embedFile("../fixtures/chain.json") },
    .{ .name = "slanted_cut", .expected = @embedFile("../fixtures/slanted_cut.json") },
};

/// A box from `lo` to `hi`.
fn box(allocator: std.mem.Allocator, lo: vec.Vec3, hi: vec.Vec3, diag: *Diagnostics) !Body {
    var unit = try primitives.box(allocator, tol, hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], false, diag);
    defer unit.deinit();
    return transform.transform(allocator, &unit, &mat.Affine.translate(lo), .{}, diag);
}

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
    if (std.mem.eql(u8, name, "revolved")) {
        // A profile with every generator kind but the free-form one, turned three quarters:
        // an edge on the axis, a horizontal, a vertical and an oblique line, an apex
        var sketch = try primitives.polygon(allocator, tol, &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 2 }, .{ 1, 5 }, .{ 0, 5 } }, &diag);
        defer sketch.deinit();
        const up = mat.Affine.rotate(vec.X3, std.math.pi / 2.0);
        var profile = try transform.transform(allocator, &sketch, &up, .{}, &diag);
        defer profile.deinit();
        return sweep.revolve(allocator, &profile, vec.ZERO3, vec.Z3, 1.5 * std.math.pi, .{}, &diag);
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
    if (std.mem.eql(u8, name, "corner_union")) {
        var a = try box(allocator, .{ 0, 0, 0 }, .{ 2, 2, 2 }, &diag);
        defer a.deinit();
        var b = try box(allocator, .{ 1, 1, 1 }, .{ 3, 3, 3 }, &diag);
        defer b.deinit();
        return pipeline.boolean(allocator, &a, &b, .@"union", .{}, &diag, null);
    }
    if (std.mem.eql(u8, name, "void")) {
        var outer = try box(allocator, .{ 0, 0, 0 }, .{ 4, 4, 4 }, &diag);
        defer outer.deinit();
        var cavity = try box(allocator, .{ 1, 1, 1 }, .{ 3, 3, 3 }, &diag);
        defer cavity.deinit();
        return pipeline.boolean(allocator, &outer, &cavity, .difference, .{}, &diag, null);
    }
    if (std.mem.eql(u8, name, "chain")) {
        // Three boxes in a row, each overlapping the next, and a post on the middle one
        var a = try box(allocator, .{ 0, 0, 0 }, .{ 2, 1, 1 }, &diag);
        defer a.deinit();
        var b = try box(allocator, .{ 1.5, 0, 0 }, .{ 3.5, 1, 1 }, &diag);
        defer b.deinit();
        var c = try box(allocator, .{ 3, 0, 0 }, .{ 5, 1, 1 }, &diag);
        defer c.deinit();
        var post = try box(allocator, .{ 2.25, 0.25, 0.5 }, .{ 2.75, 0.75, 3 }, &diag);
        defer post.deinit();
        return pipeline.chain(allocator, &.{ &a, &b, &c, &post }, .@"union", .{}, &diag, null);
    }
    if (std.mem.eql(u8, name, "slanted_cut")) {
        var a = try box(allocator, .{ 0, 0, 0 }, .{ 3, 2, 1 }, &diag);
        defer a.deinit();
        return trim.trimByPlane(allocator, &a, .{ 1, 2, 3 }, 1.3, .{}, &diag, null);
    }
    unreachable;
}

test "fixtures: each primitive's and boolean result's body JSON is its fixture, byte for byte" {
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
