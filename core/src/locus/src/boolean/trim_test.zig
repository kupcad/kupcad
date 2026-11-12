//! Trims and splits by a plane: a cube cut level through the middle, missed above and below,
//! cut on a slant through a corner, split in two; a curved solid refused until M5.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const primitives = @import("../construct/primitives.zig");
const mass = @import("../measure/mass.zig");
const overlap = @import("../query/overlap.zig");
const pipeline = @import("pipeline.zig");
const trim = @import("trim.zig");
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);
const CLOSE = 1e-9;

fn cube() !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return primitives.box(testing.allocator, tol, 2, 2, 2, false, &diag);
}

/// `body` trimmed, checked, and its volume.
fn trimmed(body: *const Body, normal: vec.Vec3, offset: f64) !struct { body: Body, volume: f64 } {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var out = try trim.trimByPlane(testing.allocator, body, normal, offset, .{}, &diag, null);
    errdefer out.deinit();
    var report = try check.run(testing.allocator, &out, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    try overlap.check(testing.allocator, &out, .{}, &diag);
    return .{ .body = out, .volume = (try mass.mass(&out, .{}, &diag)).volume };
}

test "trim: a cube cut level through its middle keeps its top half; missed, all or nothing" {
    var c = try cube();
    defer c.deinit();
    var half = try trimmed(&c, .{ 0, 0, 1 }, 1);
    defer half.body.deinit();
    try testing.expectApproxEqAbs(@as(f64, 4), half.volume, CLOSE);
    try testing.expectEqual(@as(usize, 6), half.body.counts().faces);
    // The normal's length does not matter, the offset is along its unit
    var scaled = try trimmed(&c, .{ 0, 0, 5 }, 1);
    defer scaled.body.deinit();
    try testing.expectApproxEqAbs(@as(f64, 4), scaled.volume, CLOSE);
    var below = try trimmed(&c, .{ 0, 0, -1 }, -1);
    defer below.body.deinit();
    try testing.expectApproxEqAbs(@as(f64, 4), below.volume, CLOSE);
    var none = try trimmed(&c, .{ 0, 0, 1 }, 3);
    defer none.body.deinit();
    try testing.expect(none.body.isEmpty());
    var all = try trimmed(&c, .{ 0, 0, 1 }, -1);
    defer all.body.deinit();
    try testing.expectApproxEqAbs(@as(f64, 8), all.volume, CLOSE);
    try testing.expectEqual(@as(usize, 6), all.body.counts().faces);
}

test "trim: a slant through two corners keeps a triangular prism; a split's halves make the whole" {
    var c = try cube();
    defer c.deinit();
    // x + y ≥ 2: half of the square below each height
    var prism = try trimmed(&c, .{ 1, 1, 0 }, @sqrt(2.0));
    defer prism.body.deinit();
    try testing.expectApproxEqAbs(@as(f64, 4), prism.volume, 1e-9);
    try testing.expectEqual(@as(usize, 5), prism.body.counts().faces);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var parts = try trim.splitByPlane(testing.allocator, &c, .{ 1, 2, 3 }, 2.5, .{}, &diag);
    defer for (&parts) |*p| p.deinit();
    const v0 = (try mass.mass(&parts[0], .{}, &diag)).volume;
    const v1 = (try mass.mass(&parts[1], .{}, &diag)).volume;
    try testing.expect(v0 > 0 and v1 > 0);
    try testing.expectApproxEqAbs(@as(f64, 8), v0 + v1, 1e-9);
}

test "trim: a curved solid is refused, naming its face, until M5; a zero normal is not a plane" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cylinder = try primitives.cylinder(testing.allocator, tol, 1, 2, false, &diag);
    defer cylinder.deinit();
    try testing.expectError(error.NotImplemented, trim.trimByPlane(testing.allocator, &cylinder, .{ 0, 0, 1 }, 1, .{}, &diag, null));
    try testing.expectEqual(diagnostics.EntityKind.face, diag.first().?.entity.kind);
    var c = try cube();
    defer c.deinit();
    diag.clear();
    try testing.expectError(error.InvalidInput, trim.trimByPlane(testing.allocator, &c, .{ 0, 0, 0 }, 1, .{}, &diag, null));
}
