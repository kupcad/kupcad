//! The convex hull of sketches (docs/architecture.md §7.5): the polygon about every
//! vertex and every arc's extreme points (its topmost, bottommost, leftmost and rightmost
//! points where it has them), by the monotone chain. The arcs themselves are left out of
//! the hull's boundary, so a disc's hull is the polygon through its four extreme points
//! and its two vertices, as the plan documents; the hull of points is the same function.

const std = @import("std");
const vec = @import("../math/vec.zig");
const predicates = @import("../math/predicates.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const primitives = @import("../construct/primitives.zig");
const Body = body_mod.Body;
const Vec2 = vec.Vec2;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// The hull of the sketches together, as a sheet; the inputs untouched. Fewer than three
/// distinct points, or all on a line, is `error.Degenerate`.
pub fn hull(allocator: std.mem.Allocator, sheets: []const *const Body, options: diagnostics.Options, diag: *Diagnostics) Error!Body {
    try diagnostics.input.nonEmpty(diag, "sheets", sheets.len);
    try options.checkCancel();
    var tol = options.tolerance orelse sheets[0].tol;
    var points = std.ArrayList(Vec2).empty;
    defer points.deinit(allocator);
    for (sheets) |sheet| {
        if (sheet.kind != .sheet) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "an operand: a sheet" });
        if (options.tolerance == null) tol = tol.merge(sheet.tol);
        try collect(allocator, sheet, &points, diag);
    }
    const ring = try hullOf(allocator, points.items);
    defer allocator.free(ring);
    if (ring.len < 3) return diag.fail(error.Degenerate, .{ .code = .empty_input, .label = "the hull: fewer than three points off one line", .measured = @floatFromInt(ring.len), .threshold = 3 });
    return primitives.polygon(allocator, tol, ring, diag);
}

/// The sketch's vertices and its arcs' extreme points.
fn collect(allocator: std.mem.Allocator, sheet: *const Body, points: *std.ArrayList(Vec2), diag: *Diagnostics) Error!void {
    for (sheet.vertices.items) |v| {
        if (v.tombstone) continue;
        const p = sheet.geometry.point(v.point);
        try points.append(allocator, .{ p[0], p[1] });
    }
    for (sheet.edges.items) |e| {
        if (e.flags.tombstone) continue;
        const curve = sheet.geometry.curve(e.curve);
        switch (curve) {
            .line => {},
            .circle => |circle| {
                // The circle's points farthest along each axis, those the arc reaches
                for ([_]vec.Vec3{ vec.X3, vec.Y3, vec.neg(vec.X3), vec.neg(vec.Y3) }) |axis| {
                    const p = vec.addScaled(circle.c, axis, circle.r);
                    const t = circle.project(p);
                    const span = e.t1 - e.t0;
                    const along = @mod(t - e.t0, 2 * std.math.pi);
                    if (along <= span + sheet.tol.param) try points.append(allocator, .{ p[0], p[1] });
                }
            },
            else => return diag.fail(error.NotRepresentable, .{ .code = .not_implemented, .label = "a sketch edge that is neither a line nor an arc" }),
        }
    }
}

/// The convex hull of `points` counter-clockwise, by the monotone chain (de Berg §1.1),
/// the exact orientation predicate deciding each turn; collinear points on the hull are
/// left out. Owned by `allocator`.
pub fn hullOf(allocator: std.mem.Allocator, points: []const Vec2) Error![]Vec2 {
    const sorted = try allocator.dupe(Vec2, points);
    defer allocator.free(sorted);
    std.mem.sort(Vec2, sorted, {}, lexicographic);
    var ring = std.ArrayList(Vec2).empty;
    defer ring.deinit(allocator);
    // The lower chain, then the upper, each dropping what would turn right or go straight
    for (sorted) |p| {
        if (ring.items.len > 0 and samePoint(ring.items[ring.items.len - 1], p)) continue;
        while (ring.items.len >= 2 and predicates.orient2d(ring.items[ring.items.len - 2], ring.items[ring.items.len - 1], p) <= 0) _ = ring.pop();
        try ring.append(allocator, p);
    }
    const lower = ring.items.len;
    var i = sorted.len;
    while (i > 1) {
        i -= 1;
        const p = sorted[i - 1];
        if (samePoint(ring.items[ring.items.len - 1], p)) continue;
        while (ring.items.len > lower and predicates.orient2d(ring.items[ring.items.len - 2], ring.items[ring.items.len - 1], p) <= 0) _ = ring.pop();
        try ring.append(allocator, p);
    }
    // The upper chain ends where the lower began
    if (ring.items.len > 1) _ = ring.pop();
    return ring.toOwnedSlice(allocator);
}

fn lexicographic(_: void, a: Vec2, b: Vec2) bool {
    if (a[0] != b[0]) return a[0] < b[0];
    return a[1] < b[1];
}

fn samePoint(a: Vec2, b: Vec2) bool {
    return a[0] == b[0] and a[1] == b[1];
}
