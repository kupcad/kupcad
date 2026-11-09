const std = @import("std");
const testing = std.testing;
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const primitives = @import("../construct/primitives.zig");
const step_write = @import("step_write.zig");
const vec = @import("../math/vec.zig");
const types = @import("../topology/types.zig");
const Body = @import("../topology/body.zig").Body;

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

test "step: a cone narrowing along its axis is written widening along the axis reversed, its semi-angle positive" {
    // OpenCascade reads a negative semi-angle as zero (a cylinder): the narrowing cone's
    // surface is the same one described from the other end of the axis
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var narrowing = try primitives.cone(testing.allocator, tol, 2, 1, 3, false, &diag);
    defer narrowing.deinit();
    const text = try step_write.write(testing.allocator, &.{&narrowing});
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 2), count(text, "=CONICAL_SURFACE("));
    try testing.expectEqual(@as(usize, 2), count(text, ",2.,0.3217505543966422)"));
    try testing.expectEqual(@as(usize, 0), count(text, ",-0.3217505543966422)"));
    // The two cone faces' placements point down the axis; the caps' keep their own
    try testing.expect(count(text, "=DIRECTION('',(-0.,-0.,-1.))") >= 2);

    var widening = try primitives.cone(testing.allocator, tol, 1, 2, 3, false, &diag);
    defer widening.deinit();
    const up = try step_write.write(testing.allocator, &.{&widening});
    defer testing.allocator.free(up);
    try testing.expectEqual(@as(usize, 2), count(up, ",1.,0.3217505543966422)"));
}

/// A sheet on z = 0 over the square [0, 2] × [0, 3] whose right side is a free-form
/// curve (a straight line as a degree-one B-spline): what a sketch with a spline edge is.
fn splineSheet(diag: *Diagnostics) !Body {
    const sew = @import("../construct/sew.zig");
    const geometry = @import("../geometry/types.zig");
    const nurbs = @import("../geometry/nurbs.zig");
    var b = try primitives.Builder.init(testing.allocator, tol, .sheet, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const corners = [4]vec.Vec3{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 3, 0 }, .{ 0, 3, 0 } };
    var v: [4]types.VertexIndex = undefined;
    for (corners, 0..) |p, i| v[i] = try b.vertex(p);
    var spline = try nurbs.lineSegment(testing.allocator, corners[1], corners[2], 0, 1);
    defer spline.deinit(testing.allocator);
    const right = try b.body.geometry.addNurbsCurve(testing.allocator, .{ .degree = spline.degree, .knots = spline.knots, .points = spline.points });
    const edges = [4]sew.EdgeSpec{
        try b.straight(v[0], v[1]),
        .{ .start = v[1], .end = v[2], .curve = right, .t0 = 0, .t1 = 1 },
        try b.straight(v[2], v[3]),
        try b.straight(v[3], v[0]),
    };
    const plane = try b.plane(geometry.Frame.world);
    return b.finish(&.{.{ .surface = plane, .loops = &.{.{ .edges = &edges }}, .uv_box = .{ .min = .{ 0, 0 }, .max = .{ 2, 3 } } }}, .sheet);
}

test "step: a free-form edge is a B-spline curve; swept, a surface of linear extrusion or of revolution" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const sweep = @import("../construct/sweep.zig");
    const transform = @import("../construct/transform.zig");
    const mat = @import("../math/mat.zig");
    const check = @import("../topology/check.zig");
    var sheet = try splineSheet(&diag);
    defer sheet.deinit();

    var block = try sweep.extrude(testing.allocator, &sheet, .{ 0, 0, 4 }, .{}, &diag);
    defer block.deinit();
    var report = try check.run(testing.allocator, &block, .geometric);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    const text = try step_write.write(testing.allocator, &.{&block});
    defer testing.allocator.free(text);
    // The bottom and top edges, and the surface's own generator
    try testing.expectEqual(@as(usize, 3), count(text, "=B_SPLINE_CURVE_WITH_KNOTS("));
    try testing.expectEqual(@as(usize, 1), count(text, "=SURFACE_OF_LINEAR_EXTRUSION("));
    try testing.expectEqual(@as(usize, 5), count(text, "=PLANE("));
    try testing.expect(count(text, ",(2,2),(0.,1.),") == 3);

    var shifted = try transform.transform(testing.allocator, &sheet, &mat.Affine.translate(.{ 1, 0, 0 }), .{}, &diag);
    defer shifted.deinit();
    var profile = try transform.transform(testing.allocator, &shifted, &mat.Affine.rotate(vec.X3, std.math.pi / 2.0), .{}, &diag);
    defer profile.deinit();
    var ring = try sweep.revolve(testing.allocator, &profile, vec.ZERO3, vec.Z3, 2 * std.math.pi, .{}, &diag);
    defer ring.deinit();
    var ring_report = try check.run(testing.allocator, &ring, .geometric);
    defer ring_report.deinit(testing.allocator);
    try testing.expect(ring_report.ok());
    const ring_text = try step_write.write(testing.allocator, &.{&ring});
    defer testing.allocator.free(ring_text);
    try testing.expectEqual(@as(usize, 2), count(ring_text, "=SURFACE_OF_REVOLUTION("));
    try testing.expectEqual(@as(usize, 2), count(ring_text, "=AXIS1_PLACEMENT("));
}

/// A box of 2 × 3 × 4 whose top is the bilinear patch over its four corners.
fn patchTopBox(diag: *Diagnostics) !Body {
    const sew = @import("../construct/sew.zig");
    const geometry = @import("../geometry/types.zig");
    const nurbs = @import("../geometry/nurbs.zig");
    var b = try primitives.Builder.init(testing.allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const c = [8]vec.Vec3{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 3, 0 }, .{ 0, 3, 0 }, .{ 0, 0, 4 }, .{ 2, 0, 4 }, .{ 2, 3, 4 }, .{ 0, 3, 4 } };
    var v: [8]types.VertexIndex = undefined;
    for (c, 0..) |p, i| v[i] = try b.vertex(p);
    var patch = try nurbs.bilinear(testing.allocator, c[4], c[5], c[7], c[6], .{ 0, 1 }, .{ 0, 1 });
    defer patch.deinit(testing.allocator);
    const top = try b.body.geometry.addNurbsSurface(testing.allocator, .{ .degree_u = patch.degree_u, .degree_v = patch.degree_v, .knots_u = patch.knots_u, .knots_v = patch.knots_v, .count_u = patch.count_u, .count_v = patch.count_v, .points = patch.points });
    // Each face's corners counter-clockwise seen from outside
    const quads = [6][4]usize{ .{ 0, 3, 2, 1 }, .{ 0, 1, 5, 4 }, .{ 1, 2, 6, 5 }, .{ 2, 3, 7, 6 }, .{ 3, 0, 4, 7 }, .{ 4, 5, 6, 7 } };
    const normals = [5]vec.Vec3{ vec.neg(vec.Z3), vec.neg(vec.Y3), vec.X3, vec.Y3, vec.neg(vec.X3) };
    var edges: [6][4]sew.EdgeSpec = undefined;
    var loops: [6][1]sew.LoopSpec = undefined;
    var specs: [6]sew.FaceSpec = undefined;
    for (quads, 0..) |q, f| {
        for (0..4) |k| edges[f][k] = try b.straight(v[q[k]], v[q[(k + 1) % 4]]);
        loops[f] = .{.{ .edges = &edges[f] }};
        if (f < 5) {
            const frame = geometry.Frame.init(c[q[0]], vec.normalized(vec.sub(c[q[1]], c[q[0]])).?, normals[f]);
            specs[f] = .{ .surface = try b.plane(frame), .loops = &loops[f], .uv_box = .{ .min = .{ 0, 0 }, .max = .{ 4, 4 } } };
        } else {
            specs[f] = .{ .surface = top, .loops = &loops[f], .uv_box = .{ .min = .{ 0, 0 }, .max = .{ 1, 1 } } };
        }
    }
    return b.finish(&specs, .outer);
}

/// A quarter disc of radius 2 on z = 0 whose arc is a rational B-spline.
fn quarterDisc(diag: *Diagnostics) !Body {
    const sew = @import("../construct/sew.zig");
    const geometry = @import("../geometry/types.zig");
    const nurbs = @import("../geometry/nurbs.zig");
    var arc = try nurbs.circleArc(testing.allocator, vec.ZERO3, vec.X3, vec.Y3, 2, 0, std.math.pi / 2.0);
    defer arc.deinit(testing.allocator);
    var b = try primitives.Builder.init(testing.allocator, tol, .sheet, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const ends = [3]vec.Vec3{ .{ 2, 0, 0 }, .{ 0, 2, 0 }, .{ 0, 0, 0 } };
    var v: [3]types.VertexIndex = undefined;
    for (ends, 0..) |p, i| v[i] = try b.vertex(p);
    const curve = try b.body.geometry.addNurbsCurve(testing.allocator, .{ .degree = arc.degree, .knots = arc.knots, .points = arc.points });
    const sector = [3]sew.EdgeSpec{
        .{ .start = v[0], .end = v[1], .curve = curve, .t0 = arc.knots[0], .t1 = arc.knots[arc.knots.len - 1] },
        try b.straight(v[1], v[2]),
        try b.straight(v[2], v[0]),
    };
    return b.finish(&.{.{ .surface = try b.plane(geometry.Frame.world), .loops = &.{.{ .edges = &sector }}, .uv_box = .{ .min = .{ 0, 0 }, .max = .{ 2, 2 } } }}, .sheet);
}

test "step: a face on a B-spline surface, and a rational curve's weights" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const check = @import("../topology/check.zig");
    var body = try patchTopBox(&diag);
    defer body.deinit();
    var report = try check.run(testing.allocator, &body, .geometric);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    const text = try step_write.write(testing.allocator, &.{&body});
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 1), count(text, "=B_SPLINE_SURFACE_WITH_KNOTS("));
    try testing.expect(count(text, ",1,1,((#") == 1);

    // The arc, its copy at the top, and the extrusion's generator: three rational curves
    var disc = try quarterDisc(&diag);
    defer disc.deinit();
    const sweep = @import("../construct/sweep.zig");
    var wedge = try sweep.extrude(testing.allocator, &disc, .{ 0, 0, 1 }, .{}, &diag);
    defer wedge.deinit();
    const wedge_text = try step_write.write(testing.allocator, &.{&wedge});
    defer testing.allocator.free(wedge_text);
    try testing.expectEqual(@as(usize, 3), count(wedge_text, "RATIONAL_B_SPLINE_CURVE("));
    try testing.expectEqual(@as(usize, 0), count(wedge_text, "=B_SPLINE_CURVE_WITH_KNOTS("));
}


test "step: the report counts what was written and bounds what a reader may find off" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer box.deinit();
    const written = try step_write.writeReported(testing.allocator, &.{&box});
    defer testing.allocator.free(written.text);
    const r = written.report;
    try testing.expectEqual(@as(u32, 1), r.solids);
    try testing.expectEqual(@as(u32, 1), r.shells);
    try testing.expectEqual(@as(u32, 6), r.faces);
    try testing.expectEqual(@as(u32, 12), r.edges);
    try testing.expectEqual(@as(u32, 8), r.vertices);
    try testing.expectEqual(@as(u32, 0), r.degenerate_edges);
    try testing.expectEqual(@as(u32, 0), r.bspline_curves);
    try testing.expectEqual(@as(u32, 0), r.bspline_surfaces);
    try testing.expectEqual(@as(u64, written.text.len), r.bytes);
    // Entities are numbered 1..entities, every one present
    try testing.expectEqual(@as(usize, r.entities), count(written.text, "\n#") + 1);
    // An exact box: the bound is the reader's rounding of its largest coordinate alone
    try testing.expect(r.error_bound > 0 and r.error_bound < 1e-13);
    try testing.expectEqual(64.0 * std.math.floatEps(f64) * 4.0, r.error_bound);
    // The header says the same
    try testing.expect(count(written.text, "'1 solids, 1 shells, 6 faces, 12 edges, 8 vertices, error bound ") == 1);
    // `write` is the text alone
    const text = try step_write.write(testing.allocator, &.{&box});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(written.text, text);
    // A sphere: its poles are degenerate edges, not written; a gap recorded on a vertex
    // joins the bound
    var sphere = try primitives.sphere(testing.allocator, tol, 3, &diag);
    defer sphere.deinit();
    sphere.vertex(types.VertexIndex.of(0)).gap = 1e-6;
    const spherical = try step_write.writeReported(testing.allocator, &.{&sphere});
    defer testing.allocator.free(spherical.text);
    try testing.expect(spherical.report.degenerate_edges > 0);
    try testing.expectEqual(spherical.report.faces, count(spherical.text, "=ADVANCED_FACE("));
    try testing.expect(spherical.report.error_bound >= 1e-6);
    try testing.expect(spherical.report.error_bound < 1.1e-6);
}
