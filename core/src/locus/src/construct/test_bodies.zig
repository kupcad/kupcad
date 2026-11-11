//! Bodies with free-form geometry for tests (a sketch has only lines and arcs, so these
//! are built by hand): a sheet with a B-spline side, one with an elliptic side, a quarter
//! disc whose arc is a rational B-spline, a box whose top is a bilinear patch, flat or a
//! saddle. Shared by the STEP writer's and the tessellator's tests.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const nurbs = @import("../geometry/nurbs.zig");
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const primitives = @import("primitives.zig");
const sew = @import("sew.zig");
const Vec3 = vec.Vec3;
const Body = body_mod.Body;
const Tolerance = tolerance.Tolerance;
const Diagnostics = diagnostics.Diagnostics;

/// A sheet on z = 0 over the square [0, 2] × [0, 3] whose right side is a free-form
/// curve (a straight line as a degree-one B-spline): what a sketch with a spline edge is.
pub fn splineSheet(allocator: std.mem.Allocator, tol: Tolerance, diag: *Diagnostics) !Body {
    var b = try primitives.Builder.init(allocator, tol, .sheet, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const corners = [4]Vec3{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 3, 0 }, .{ 0, 3, 0 } };
    var v: [4]types.VertexIndex = undefined;
    for (corners, 0..) |p, i| v[i] = try b.vertex(p);
    var spline = try nurbs.lineSegment(allocator, corners[1], corners[2], 0, 1);
    defer spline.deinit(allocator);
    const right = try b.body.geometry.addNurbsCurve(allocator, .{ .degree = spline.degree, .knots = spline.knots, .points = spline.points });
    const edges = [4]sew.EdgeSpec{
        try b.straight(v[0], v[1]),
        .{ .start = v[1], .end = v[2], .curve = right, .t0 = 0, .t1 = 1 },
        try b.straight(v[2], v[3]),
        try b.straight(v[3], v[0]),
    };
    const plane = try b.plane(geometry.Frame.world);
    return b.finish(&.{.{ .surface = plane, .loops = &.{.{ .edges = &edges }}, .uv_box = .{ .min = .{ 0, 0 }, .max = .{ 2, 3 } } }}, .sheet);
}

/// A sheet on z = 0: the square [0, 2] × [0, 3] whose right side bulges out as half an
/// ellipse about (2, 1.5), 1.5 along y and 0.8 along x (area 6 + 0.6π).
pub fn ellipseSheet(allocator: std.mem.Allocator, tol: Tolerance, diag: *Diagnostics) !Body {
    var b = try primitives.Builder.init(allocator, tol, .sheet, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const corners = [4]Vec3{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 3, 0 }, .{ 0, 3, 0 } };
    var v: [4]types.VertexIndex = undefined;
    for (corners, 0..) |p, i| v[i] = try b.vertex(p);
    // At angle 0 the top corner (2, 3), at π the bottom one (2, 0); the loop runs the
    // edge from the bottom, so backwards along the parameter
    const right = try b.body.geometry.addEllipse(allocator, .{ .c = .{ 2, 1.5, 0 }, .x = vec.Y3, .y = vec.X3, .a = 1.5, .b = 0.8 });
    const edges = [4]sew.EdgeSpec{
        try b.straight(v[0], v[1]),
        .{ .start = v[1], .end = v[2], .curve = right, .t0 = 0, .t1 = std.math.pi, .forward = false },
        try b.straight(v[2], v[3]),
        try b.straight(v[3], v[0]),
    };
    const plane = try b.plane(geometry.Frame.world);
    return b.finish(&.{.{ .surface = plane, .loops = &.{.{ .edges = &edges }}, .uv_box = .{ .min = .{ 0, 0 }, .max = .{ 2.8, 3 } } }}, .sheet);
}

/// A quarter disc of radius 2 on z = 0 whose arc is a rational B-spline.
pub fn quarterDisc(allocator: std.mem.Allocator, tol: Tolerance, diag: *Diagnostics) !Body {
    var arc = try nurbs.circleArc(allocator, vec.ZERO3, vec.X3, vec.Y3, 2, 0, std.math.pi / 2.0);
    defer arc.deinit(allocator);
    var b = try primitives.Builder.init(allocator, tol, .sheet, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const ends = [3]Vec3{ .{ 2, 0, 0 }, .{ 0, 2, 0 }, .{ 0, 0, 0 } };
    var v: [3]types.VertexIndex = undefined;
    for (ends, 0..) |p, i| v[i] = try b.vertex(p);
    const curve = try b.body.geometry.addNurbsCurve(allocator, .{ .degree = arc.degree, .knots = arc.knots, .points = arc.points });
    const sector = [3]sew.EdgeSpec{
        .{ .start = v[0], .end = v[1], .curve = curve, .t0 = arc.knots[0], .t1 = arc.knots[arc.knots.len - 1] },
        try b.straight(v[1], v[2]),
        try b.straight(v[2], v[0]),
    };
    return b.finish(&.{.{ .surface = try b.plane(geometry.Frame.world), .loops = &.{.{ .edges = &sector }}, .uv_box = .{ .min = .{ 0, 0 }, .max = .{ 2, 2 } } }}, .sheet);
}

/// A box of 2 × 3 × 4 whose top is the bilinear patch over its four top corners, the
/// corner above (2, 3) raised by `lift`: flat at 0, a saddle otherwise (volume
/// `6 · (16 + lift) / 4`, the patch's height averaging its corners').
pub fn patchTopBox(allocator: std.mem.Allocator, tol: Tolerance, lift: f64, diag: *Diagnostics) !Body {
    var b = try primitives.Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const c = [8]Vec3{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 3, 0 }, .{ 0, 3, 0 }, .{ 0, 0, 4 }, .{ 2, 0, 4 }, .{ 2, 3, 4 + lift }, .{ 0, 3, 4 } };
    var v: [8]types.VertexIndex = undefined;
    for (c, 0..) |p, i| v[i] = try b.vertex(p);
    var patch = try nurbs.bilinear(allocator, c[4], c[5], c[7], c[6], .{ 0, 1 }, .{ 0, 1 });
    defer patch.deinit(allocator);
    const top = try b.body.geometry.addNurbsSurface(allocator, .{ .degree_u = patch.degree_u, .degree_v = patch.degree_v, .knots_u = patch.knots_u, .knots_v = patch.knots_v, .count_u = patch.count_u, .count_v = patch.count_v, .points = patch.points });
    // Each face's corners counter-clockwise seen from outside
    const quads = [6][4]usize{ .{ 0, 3, 2, 1 }, .{ 0, 1, 5, 4 }, .{ 1, 2, 6, 5 }, .{ 2, 3, 7, 6 }, .{ 3, 0, 4, 7 }, .{ 4, 5, 6, 7 } };
    const normals = [5]Vec3{ vec.neg(vec.Z3), vec.neg(vec.Y3), vec.X3, vec.Y3, vec.neg(vec.X3) };
    var edges: [6][4]sew.EdgeSpec = undefined;
    var loops: [6][1]sew.LoopSpec = undefined;
    var specs: [6]sew.FaceSpec = undefined;
    for (quads, 0..) |q, f| {
        for (0..4) |k| edges[f][k] = try b.straight(v[q[k]], v[q[(k + 1) % 4]]);
        loops[f] = .{.{ .edges = &edges[f] }};
        if (f < 5) {
            const frame = geometry.Frame.init(c[q[0]], vec.normalized(vec.sub(c[q[1]], c[q[0]])).?, normals[f]);
            specs[f] = .{ .surface = try b.plane(frame), .loops = &loops[f], .uv_box = .{ .min = .{ 0, 0 }, .max = .{ 4 + @abs(lift), 4 + @abs(lift) } } };
        } else {
            specs[f] = .{ .surface = top, .loops = &loops[f], .uv_box = .{ .min = .{ 0, 0 }, .max = .{ 1, 1 } } };
        }
    }
    return b.finish(&specs, .outer);
}
