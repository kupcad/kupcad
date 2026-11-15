//! Where a point lies against a solid (docs/architecture.md §7.6, KNOWLEDGE §7's
//! classification): on its boundary when within the zone of a face (the foot of the point
//! on the face's surface in the face, or an edge of the face within the zone), else inside
//! or outside by a ray. The ray goes first along a normal: from the point to its foot on a
//! nearby face, where that foot is strictly inside the face, so the first meeting is
//! usually that very face, met squarely; then along the directions of a fixed table,
//! skewed off the axes. The nearest meeting decides when it is clean (one face, strictly
//! inside it, not tangent): the ray leaves the solid there (the face's normal along the
//! ray) exactly when the point is inside. A ray that meets nothing leaves from outside. A
//! ray whose nearest meeting is an edge, a vertex or a tangency is retried; when every
//! one is, the classification is refused with a finding, never guessed.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const index_mod = @import("index.zig");
const in_face = @import("in_face.zig");
const raycast = @import("raycast.zig");
const Vec3 = vec.Vec3;
const Body = body_mod.Body;
const Box3 = geometry.Box3;
const FaceIndex = index_mod.FaceIndex;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

pub const Place = in_face.Place;

/// The nearby faces whose feet give the first rays.
const FOOT_RAYS: usize = 6;
/// The retry directions: skewed off the axes and off each other, so no two meet one edge
/// alike (unit length once normalized).
const TABLE = [_]Vec3{
    .{ 0.5384, 0.6202, 0.5706 },   .{ -0.6114, 0.4718, 0.6352 },   .{ 0.4471, -0.7291, 0.5182 },
    .{ 0.7022, 0.3914, -0.5948 },  .{ -0.3391, -0.6527, -0.6775 }, .{ 0.8119, -0.4133, 0.4123 },
    .{ -0.7543, 0.5862, -0.2955 }, .{ 0.2347, 0.9104, -0.3404 },   .{ -0.4806, -0.2193, 0.8492 },
    .{ 0.9211, 0.1877, 0.3412 },   .{ -0.1563, -0.9318, 0.3277 },  .{ 0.3778, -0.2541, -0.8902 },
};

/// Inside, outside, or on the boundary of `body` within its zone.
pub fn classify(allocator: std.mem.Allocator, body: *const Body, index: *const FaceIndex, p: Vec3, options: diagnostics.Options, diag: *Diagnostics) Error!Place {
    try options.checkCancel();
    const zone = body.tol.zone;
    if (index.box.isEmpty() or !index.box.inflated(zone).contains(p)) return .outside;

    // On the boundary: within the zone of a face's surface inside the face, or of an edge
    var near: std.ArrayList(u32) = .empty;
    defer near.deinit(allocator);
    try collectBox(allocator, index, Box3.ofPoint(p).inflated(zone), &near);
    for (near.items) |item| {
        const f = index.faces[item];
        if (try in_face.nearEdge(body, f, p, zone, diag)) return .boundary;
        const uv = in_face.uvOf(body, f, p);
        const foot = body.geometry.surface(body.face(f).surface).eval(uv[0], uv[1]);
        if (vec.distance(foot, p) <= zone and try in_face.classify(body, f, foot, uv, zone, diag) != .outside) return .boundary;
    }

    // The rays, long enough to leave the body's box from anywhere in it
    var reach: f64 = 0;
    for ([_]f64{ index.box.min[0], index.box.max[0] }) |x| for ([_]f64{ index.box.min[1], index.box.max[1] }) |y| for ([_]f64{ index.box.min[2], index.box.max[2] }) |z| {
        reach = @max(reach, vec.distance(p, .{ x, y, z }));
    };
    reach += 4 * zone;
    var found: std.ArrayList(raycast.Candidate) = .empty;
    defer found.deinit(allocator);

    // Along the normals of the nearest faces' feet
    var nearest: [FOOT_RAYS]u32 = undefined;
    for (nearestFaces(index, p, &nearest)) |item| {
        const f = index.faces[item];
        const uv = in_face.uvOf(body, f, p);
        const foot = body.geometry.surface(body.face(f).surface).eval(uv[0], uv[1]);
        if (vec.distance(foot, p) <= zone) continue;
        if (try in_face.classify(body, f, foot, uv, zone, diag) != .inside) continue;
        const dir = vec.normalized(vec.sub(foot, p)) orelse continue;
        if (try decide(allocator, body, index, p, dir, reach, &found, diag)) |place| return place;
    }
    // Along the table's directions
    for (TABLE) |raw| {
        const dir = vec.normalized(raw).?;
        if (try decide(allocator, body, index, p, dir, reach, &found, diag)) |place| return place;
    }
    return diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "the rays of a point's classification (each met an edge, a vertex or a tangent face first)", .measured = @floatFromInt(FOOT_RAYS + TABLE.len), .threshold = @floatFromInt(FOOT_RAYS + TABLE.len) });
}

/// Whether `p` is in `body`, its boundary included (within the zone).
pub fn contains(allocator: std.mem.Allocator, body: *const Body, index: *const FaceIndex, p: Vec3, options: diagnostics.Options, diag: *Diagnostics) Error!bool {
    return try classify(allocator, body, index, p, options, diag) != .outside;
}

/// The ray from `p` along `dir`: outside when it meets nothing, inside or outside by its
/// nearest meeting when that is clean, null (retry) when it is not.
fn decide(allocator: std.mem.Allocator, body: *const Body, index: *const FaceIndex, p: Vec3, dir: Vec3, reach: f64, found: *std.ArrayList(raycast.Candidate), diag: *Diagnostics) Error!?Place {
    found.clearRetainingCapacity();
    try raycast.candidates(allocator, body, index, p, dir, 0, reach, found, diag);
    if (found.items.len == 0) return .outside;
    var nearest: usize = 0;
    for (found.items, 0..) |c, i| {
        if (c.t < found.items[nearest].t) nearest = i;
    }
    const first = found.items[nearest];
    // Another meeting at the same place makes it an edge or a vertex
    for (found.items, 0..) |c, i| {
        if (i != nearest and c.t - first.t <= body.tol.zone) return null;
    }
    if (first.place != .inside or @abs(first.cosine) <= raycast.CLEAN_COSINE) return null;
    return if (first.cosine > 0) .inside else .outside;
}

/// The items whose (grown) boxes overlap `box`. Appended to `out`.
fn collectBox(allocator: std.mem.Allocator, index: *const FaceIndex, box: Box3, out: *std.ArrayList(u32)) Error!void {
    const Collect = struct {
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u32),
        failed: bool = false,
        fn visit(self: *@This(), item: u32) bool {
            self.out.append(self.allocator, item) catch {
                self.failed = true;
                return false;
            };
            return true;
        }
    };
    var collect: Collect = .{ .allocator = allocator, .out = out };
    index.bvh.query(box, &collect, Collect.visit);
    if (collect.failed) return error.OutOfMemory;
}

/// The `out.len` items nearest `p` by their box's distance, nearest first, ties by item:
/// the first of a sort of them all, found in one pass (a classification per fragment of a
/// boolean's faces sorted every face for six, 2026-11-12). The filled part of `out`.
fn nearestFaces(index: *const FaceIndex, p: Vec3, out: []u32) []u32 {
    var dist: [FOOT_RAYS]f64 = undefined;
    var n: usize = 0;
    for (0..index.faces.len) |i| {
        const item: u32 = @intCast(i);
        const d = boxDistance(index.boxOf(item), p);
        // Its place among those kept: after every one nearer, or as near and earlier
        var at = n;
        while (at > 0 and dist[at - 1] > d) at -= 1;
        if (at == out.len) continue;
        const last = @min(n, out.len - 1);
        var k = last;
        while (k > at) : (k -= 1) {
            out[k] = out[k - 1];
            dist[k] = dist[k - 1];
        }
        out[at] = item;
        dist[at] = d;
        n = @min(n + 1, out.len);
    }
    return out[0..n];
}

fn boxDistance(box: Box3, p: Vec3) f64 {
    var sum: f64 = 0;
    for (0..3) |k| {
        const d = @max(0, @max(box.min[k] - p[k], p[k] - box.max[k]));
        sum += d * d;
    }
    return @sqrt(sum);
}
