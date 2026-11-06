//! The primitives (docs/architecture.md §7.1): a box, a cylinder as two half-faces and two
//! caps (D7), the planar sketch faces (a square, an exact circle, a polygon, polygons
//! filled by the even-odd rule) as sheet bodies on `z = 0`, and a polyhedron from
//! triangles. Each builds its faces explicitly with analytic surfaces and exact edges, sews
//! them, and returns a body that passes the checker; the outer loops run counter-clockwise
//! seen from outside (the face to the left of each coedge), holes clockwise.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const check = @import("../topology/check.zig");
const Interner = @import("../spatial/intern.zig").Interner;
const sew = @import("sew.zig");
const Body = body_mod.Body;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Frame = geometry.Frame;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;
const TWO_PI = geometry.TWO_PI;
const PI = std.math.pi;

/// Where a body is built: the body, its interner, and the diagnostics.
const Builder = struct {
    allocator: std.mem.Allocator,
    body: Body,
    interner: Interner,
    diag: *Diagnostics,

    fn init(allocator: std.mem.Allocator, tol: Tolerance, kind: body_mod.Kind, diag: *Diagnostics) Error!Builder {
        try diagnostics.input.tolerance(diag, tol);
        var body = Body.init(allocator, tol);
        body.kind = kind;
        return .{ .allocator = allocator, .body = body, .interner = Interner.init(tol), .diag = diag };
    }

    /// Frees the interner alone: the body is the result, or freed by the caller's errdefer
    /// (after which `body.allocator` is gone, so the builder keeps its own).
    fn deinit(self: *Builder) void {
        self.interner.deinit(self.allocator);
    }

    /// The arena's, the interner's and the sewer's errors as the operation's.
    fn fail(self: *Builder, err: anyerror) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TooMany => self.diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "entities" }),
            error.OutOfRange => self.diag.fail(error.InvalidInput, .{ .code = .too_large_for_tolerance, .label = "a coordinate" }),
            error.NotManifold => self.diag.fail(error.NotValid, .{ .code = .edge_coedge_count, .label = "an edge" }),
            else => unreachable,
        };
    }

    fn vertex(self: *Builder, p: Vec3) Error!types.VertexIndex {
        const point = self.interner.point(self.body.allocator, &self.body.geometry, p) catch |e| return self.fail(e);
        return self.body.addVertex(.{ .point = point }) catch |e| return self.fail(e);
    }

    fn line(self: *Builder, a: Vec3, b: Vec3) Error!geometry.CurveRef {
        const l = curves.Line.through(a, b) orelse return self.diag.fail(error.Degenerate, .{ .code = .edge_too_short, .label = "an edge" });
        return self.interner.line(self.body.allocator, &self.body.geometry, l) catch |e| return self.fail(e);
    }

    fn plane(self: *Builder, frame: Frame) Error!geometry.SurfaceRef {
        return self.interner.plane(self.body.allocator, &self.body.geometry, .{ .frame = frame }) catch |e| return self.fail(e);
    }

    /// The straight edge from vertex `a` to `b`, in a loop's direction. The line is
    /// interned, so it may run the other way: the edge's own range follows the line, and
    /// `forward` says which way the loop runs it.
    fn straight(self: *Builder, a: types.VertexIndex, b: types.VertexIndex) Error!sew.EdgeSpec {
        const pa = self.body.point(a);
        const pb = self.body.point(b);
        const ref = try self.line(pa, pb);
        const l = self.body.geometry.curve(ref).line;
        const ta = l.project(pa);
        const tb = l.project(pb);
        return .{ .start = a, .end = b, .curve = ref, .t0 = @min(ta, tb), .t1 = @max(ta, tb), .forward = ta < tb };
    }

    /// The body, checked (level 1), or the checker's first finding as `error.NotValid`.
    fn finish(self: *Builder, faces: []const sew.FaceSpec, kind: types.ShellKind) Error!Body {
        _ = sew.sew(&self.body, faces, kind) catch |e| return self.fail(e);
        var report = check.run(self.body.allocator, &self.body, .geometric) catch return error.OutOfMemory;
        defer report.deinit(self.body.allocator);
        if (report.first()) |f| return self.diag.fail(error.NotValid, f);
        return self.body;
    }
};

/// A box of `x` by `y` by `z` from the origin along each axis, or about the origin when
/// `center`. Six planar faces with outward normals, twelve edges, eight vertices.
pub fn box(allocator: std.mem.Allocator, tol: Tolerance, x: f64, y: f64, z: f64, center: bool, diag: *Diagnostics) Error!Body {
    try diagnostics.input.positive(diag, "x", x);
    try diagnostics.input.positive(diag, "y", y);
    try diagnostics.input.positive(diag, "z", z);
    var b = try Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const o = if (center) Vec3{ -x / 2.0, -y / 2.0, -z / 2.0 } else vec.ZERO3;
    const corners = [8]Vec3{
        o,                         .{ o[0] + x, o[1], o[2] },     .{ o[0] + x, o[1] + y, o[2] },     .{ o[0], o[1] + y, o[2] },
        .{ o[0], o[1], o[2] + z }, .{ o[0] + x, o[1], o[2] + z }, .{ o[0] + x, o[1] + y, o[2] + z }, .{ o[0], o[1] + y, o[2] + z },
    };
    var v: [8]types.VertexIndex = undefined;
    for (corners, 0..) |p, i| v[i] = try b.vertex(p);
    // Each face: its corners counter-clockwise about the outward normal, and the frame
    // (origin at the first corner, x along the first edge, z outward)
    const quads = [6][4]u8{ .{ 0, 3, 2, 1 }, .{ 4, 5, 6, 7 }, .{ 0, 1, 5, 4 }, .{ 1, 2, 6, 5 }, .{ 2, 3, 7, 6 }, .{ 3, 0, 4, 7 } };
    const normals = [6]Vec3{ vec.neg(vec.Z3), vec.Z3, vec.neg(vec.Y3), vec.X3, vec.Y3, vec.neg(vec.X3) };
    var specs: [6]sew.FaceSpec = undefined;
    var edges: [6][4]sew.EdgeSpec = undefined;
    var loops: [6][1]sew.LoopSpec = undefined;
    for (quads, 0..) |q, f| {
        const first_edge = vec.normalized(vec.sub(corners[q[1]], corners[q[0]])).?;
        const frame = Frame.init(corners[q[0]], first_edge, normals[f]);
        var uv = geometry.Box2.empty;
        for (q) |k| {
            const l = frame.toLocal(corners[k]);
            uv.grow(.{ l[0], l[1] });
        }
        for (0..4) |k| edges[f][k] = try b.straight(v[q[k]], v[q[(k + 1) % 4]]);
        loops[f] = .{.{ .edges = &edges[f] }};
        specs[f] = .{ .surface = try b.plane(frame), .loops = &loops[f], .uv_box = uv };
    }
    return b.finish(&specs, .outer);
}

/// A cylinder of radius `r` and `height` along `z` from the origin, or about it when
/// `center`: two half-faces on one cylindrical surface split at `u = 0` and `u = π` (D7),
/// two planar caps, two seam edges, four arcs, four vertices.
pub fn cylinder(allocator: std.mem.Allocator, tol: Tolerance, r: f64, height: f64, center: bool, diag: *Diagnostics) Error!Body {
    try diagnostics.input.positive(diag, "radius", r);
    try diagnostics.input.positive(diag, "height", height);
    var b = try Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const z0: f64 = if (center) -height / 2.0 else 0;
    const z1 = z0 + height;
    const g = &b.body.geometry;
    // Vertices at angles 0 and π on each cap
    const v0 = try b.vertex(.{ r, 0, z0 });
    const v1 = try b.vertex(.{ -r, 0, z0 });
    const v2 = try b.vertex(.{ r, 0, z1 });
    const v3 = try b.vertex(.{ -r, 0, z1 });
    // The surface and the curves
    const side = b.interner.cylinder(allocator, g, .{ .frame = Frame.init(.{ 0, 0, z0 }, vec.X3, vec.Z3), .r = r }) catch |e| return b.fail(e);
    const bottom_circle = b.interner.circle(allocator, g, .{ .c = .{ 0, 0, z0 }, .x = vec.X3, .y = vec.Y3, .r = r }) catch |e| return b.fail(e);
    const top_circle = b.interner.circle(allocator, g, .{ .c = .{ 0, 0, z1 }, .x = vec.X3, .y = vec.Y3, .r = r }) catch |e| return b.fail(e);
    const seam0 = try b.line(.{ r, 0, z0 }, .{ r, 0, z1 });
    const seam1 = try b.line(.{ -r, 0, z0 }, .{ -r, 0, z1 });
    // Pcurves on the side: arcs are horizontal lines, seams vertical ones, in (u, v)
    const pc_bottom = g.addLine2(allocator, .{ .o = .{ 0, 0 }, .d = .{ 1, 0 } }) catch |e| return b.fail(e);
    const pc_top = g.addLine2(allocator, .{ .o = .{ 0, height }, .d = .{ 1, 0 } }) catch |e| return b.fail(e);
    const pc_seam0 = g.addLine2(allocator, .{ .o = .{ 0, 0 }, .d = .{ 0, 1 } }) catch |e| return b.fail(e);
    const pc_seam_pi = g.addLine2(allocator, .{ .o = .{ PI, 0 }, .d = .{ 0, 1 } }) catch |e| return b.fail(e);
    const pc_seam_2pi = g.addLine2(allocator, .{ .o = .{ TWO_PI, 0 }, .d = .{ 0, 1 } }) catch |e| return b.fail(e);
    const seam_flags: types.EdgeFlags = .{ .seam = true };
    // Face A: u in [0, π]; counter-clockwise in UV (the normal is outward)
    const a_edges = [4]sew.EdgeSpec{
        .{ .start = v0, .end = v1, .curve = bottom_circle, .t0 = 0, .t1 = PI, .pcurve = pc_bottom },
        .{ .start = v1, .end = v3, .curve = seam1, .t0 = 0, .t1 = height, .pcurve = pc_seam_pi, .flags = seam_flags, .regularity = .g1 },
        .{ .start = v3, .end = v2, .curve = top_circle, .t0 = 0, .t1 = PI, .forward = false, .pcurve = pc_top },
        .{ .start = v2, .end = v0, .curve = seam0, .t0 = 0, .t1 = height, .forward = false, .pcurve = pc_seam0, .flags = seam_flags, .regularity = .g1 },
    };
    // Face B: u in [π, 2π]
    const b_edges = [4]sew.EdgeSpec{
        .{ .start = v1, .end = v0, .curve = bottom_circle, .t0 = PI, .t1 = TWO_PI, .pcurve = pc_bottom },
        .{ .start = v0, .end = v2, .curve = seam0, .t0 = 0, .t1 = height, .pcurve = pc_seam_2pi, .flags = seam_flags, .regularity = .g1 },
        .{ .start = v2, .end = v3, .curve = top_circle, .t0 = PI, .t1 = TWO_PI, .forward = false, .pcurve = pc_top },
        .{ .start = v3, .end = v1, .curve = seam1, .t0 = 0, .t1 = height, .forward = false, .pcurve = pc_seam_pi, .flags = seam_flags, .regularity = .g1 },
    };
    // The bottom cap, normal −z: clockwise seen from above, so the arcs run backwards
    const bottom_edges = [2]sew.EdgeSpec{
        .{ .start = v0, .end = v1, .curve = bottom_circle, .t0 = PI, .t1 = TWO_PI, .forward = false },
        .{ .start = v1, .end = v0, .curve = bottom_circle, .t0 = 0, .t1 = PI, .forward = false },
    };
    // The top cap, normal +z: counter-clockwise seen from above
    const top_edges = [2]sew.EdgeSpec{
        .{ .start = v2, .end = v3, .curve = top_circle, .t0 = 0, .t1 = PI },
        .{ .start = v3, .end = v2, .curve = top_circle, .t0 = PI, .t1 = TWO_PI },
    };
    const bottom_plane = try b.plane(Frame.init(.{ 0, 0, z0 }, vec.X3, vec.neg(vec.Z3)));
    const top_plane = try b.plane(Frame.init(.{ 0, 0, z1 }, vec.X3, vec.Z3));
    const cap_box = geometry.Box2{ .min = .{ -r, -r }, .max = .{ r, r } };
    const specs = [4]sew.FaceSpec{
        .{ .surface = side, .loops = &.{.{ .edges = &a_edges }}, .uv_box = .{ .min = .{ 0, 0 }, .max = .{ PI, height } } },
        .{ .surface = side, .loops = &.{.{ .edges = &b_edges }}, .uv_box = .{ .min = .{ PI, 0 }, .max = .{ TWO_PI, height } } },
        .{ .surface = bottom_plane, .loops = &.{.{ .edges = &bottom_edges }}, .uv_box = cap_box },
        .{ .surface = top_plane, .loops = &.{.{ .edges = &top_edges }}, .uv_box = cap_box },
    };
    return b.finish(&specs, .outer);
}

/// A sheet body of one planar face on `z = 0` bounded by the polygon `points` (counter-
/// clockwise; a clockwise outline is turned around), with no holes.
pub fn polygon(allocator: std.mem.Allocator, tol: Tolerance, points: []const Vec2, diag: *Diagnostics) Error!Body {
    const outline = [_][]const Vec2{points};
    return polygonsEvenOdd(allocator, tol, &outline, diag);
}

/// A rectangle of `x` by `y` from the origin, or about it when `center`.
pub fn square(allocator: std.mem.Allocator, tol: Tolerance, x: f64, y: f64, center: bool, diag: *Diagnostics) Error!Body {
    try diagnostics.input.positive(diag, "x", x);
    try diagnostics.input.positive(diag, "y", y);
    const ox: f64 = if (center) -x / 2.0 else 0;
    const oy: f64 = if (center) -y / 2.0 else 0;
    const points = [4]Vec2{ .{ ox, oy }, .{ ox + x, oy }, .{ ox + x, oy + y }, .{ ox, oy + y } };
    return polygon(allocator, tol, &points, diag);
}

/// A sheet body of one planar face on `z = 0`: the exact disc of radius `r` about the
/// origin, bounded by two half-circle edges meeting at `(±r, 0)`.
pub fn circle(allocator: std.mem.Allocator, tol: Tolerance, r: f64, diag: *Diagnostics) Error!Body {
    try diagnostics.input.positive(diag, "radius", r);
    var b = try Builder.init(allocator, tol, .sheet, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const v0 = try b.vertex(.{ r, 0, 0 });
    const v1 = try b.vertex(.{ -r, 0, 0 });
    const c = b.interner.circle(allocator, &b.body.geometry, .{ .c = vec.ZERO3, .x = vec.X3, .y = vec.Y3, .r = r }) catch |e| return b.fail(e);
    const edges = [2]sew.EdgeSpec{
        .{ .start = v0, .end = v1, .curve = c, .t0 = 0, .t1 = PI },
        .{ .start = v1, .end = v0, .curve = c, .t0 = PI, .t1 = TWO_PI },
    };
    const plane = try b.plane(Frame.world);
    const specs = [1]sew.FaceSpec{.{ .surface = plane, .loops = &.{.{ .edges = &edges }}, .uv_box = .{ .min = .{ -r, -r }, .max = .{ r, r } } }};
    return b.finish(&specs, .sheet);
}

/// A sheet body of one planar face on `z = 0` filled by the even-odd rule: the first
/// contour is the outline (turned counter-clockwise), the rest are holes in it (turned
/// clockwise). Contours that cross, or holes outside the outline, are not resolved here:
/// that is the overlay engine's (M2). A contour of fewer than three points, or with a
/// repeated point, is refused.
pub fn polygonsEvenOdd(allocator: std.mem.Allocator, tol: Tolerance, contours: []const []const Vec2, diag: *Diagnostics) Error!Body {
    try diagnostics.input.nonEmpty(diag, "contours", contours.len);
    for (contours) |c| {
        if (c.len < 3) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "a contour", .measured = @floatFromInt(c.len), .threshold = 3 });
        for (c) |p| {
            try diagnostics.input.finite(diag, "a point", p[0]);
            try diagnostics.input.finite(diag, "a point", p[1]);
        }
    }
    var b = try Builder.init(allocator, tol, .sheet, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    var edge_lists = std.ArrayList([]sew.EdgeSpec).empty;
    defer {
        for (edge_lists.items) |l| allocator.free(l);
        edge_lists.deinit(allocator);
    }
    var loops = std.ArrayList(sew.LoopSpec).empty;
    defer loops.deinit(allocator);
    var uv = geometry.Box2.empty;
    for (contours, 0..) |contour, ci| {
        // Counter-clockwise for the outline, clockwise for a hole
        const ccw = signedArea(contour) > 0;
        const want_ccw = ci == 0;
        var vertices = try allocator.alloc(types.VertexIndex, contour.len);
        defer allocator.free(vertices);
        for (0..contour.len) |i| {
            const k = if (ccw == want_ccw) i else contour.len - 1 - i;
            vertices[i] = try b.vertex(.{ contour[k][0], contour[k][1], 0 });
            uv.grow(contour[k]);
        }
        const edges = try allocator.alloc(sew.EdgeSpec, contour.len);
        {
            // Ours to free until `edge_lists` holds it
            errdefer allocator.free(edges);
            for (0..contour.len) |i| {
                if (vertices[i] == vertices[(i + 1) % contour.len]) return diag.fail(error.Degenerate, .{ .code = .edge_too_short, .label = "a contour's edge", .entity = .of(.vertex, @backingInt(vertices[i])) });
                edges[i] = try b.straight(vertices[i], vertices[(i + 1) % contour.len]);
            }
            try loops.ensureUnusedCapacity(allocator, 1);
            try edge_lists.append(allocator, edges);
        }
        loops.appendAssumeCapacity(.{ .edges = edges });
    }
    const plane = try b.plane(Frame.world);
    const specs = [1]sew.FaceSpec{.{ .surface = plane, .loops = loops.items, .uv_box = uv }};
    return b.finish(&specs, .sheet);
}

/// Twice the signed area of a polygon: positive when counter-clockwise (exact in sign for
/// the usual cases; a polygon this close to zero area is refused by the checker anyway).
pub fn signedArea(points: []const Vec2) f64 {
    var area: f64 = 0;
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % points.len];
        area += p[0] * q[1] - q[0] * p[1];
    }
    return area;
}

/// A solid from triangles over `points` (each triangle's corners counter-clockwise seen
/// from outside), coplanar triangles sharing one plane record: a closed triangulated
/// polyhedron. Triangles that don't close a shell are `error.NotValid`.
pub fn polyhedron(allocator: std.mem.Allocator, tol: Tolerance, points: []const Vec3, triangles: []const [3]u32, diag: *Diagnostics) Error!Body {
    try diagnostics.input.nonEmpty(diag, "points", points.len);
    try diagnostics.input.nonEmpty(diag, "triangles", triangles.len);
    for (triangles) |t| for (t) |i| {
        if (i >= points.len) return diag.fail(error.InvalidInput, .{ .code = .index_out_of_range, .label = "a triangle's corner", .measured = @floatFromInt(i), .threshold = @floatFromInt(points.len) });
    };
    for (points) |p| for (p) |c| try diagnostics.input.finite(diag, "a point", c);
    var b = try Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    // Every point becomes a vertex (welded); the hull's unused points are the caller's to drop
    const vertices = try allocator.alloc(types.VertexIndex, points.len);
    defer allocator.free(vertices);
    for (points, 0..) |p, i| vertices[i] = try b.vertex(p);
    const edges = try allocator.alloc([3]sew.EdgeSpec, triangles.len);
    defer allocator.free(edges);
    const loops = try allocator.alloc([1]sew.LoopSpec, triangles.len);
    defer allocator.free(loops);
    const specs = try allocator.alloc(sew.FaceSpec, triangles.len);
    defer allocator.free(specs);
    for (triangles, 0..) |t, f| {
        const p0 = points[t[0]];
        const p1 = points[t[1]];
        const p2 = points[t[2]];
        const n = vec.normalized(vec.cross(vec.sub(p1, p0), vec.sub(p2, p0))) orelse return diag.fail(error.Degenerate, .{ .code = .face_without_loop, .label = "a flat triangle", .measured = @floatFromInt(f) });
        const x = vec.normalized(vec.sub(p1, p0)) orelse return diag.fail(error.Degenerate, .{ .code = .edge_too_short, .label = "a triangle's edge", .measured = @floatFromInt(f) });
        const frame = Frame.init(p0, x, n);
        var uv = geometry.Box2.empty;
        for (t) |k| {
            const l = frame.toLocal(points[k]);
            uv.grow(.{ l[0], l[1] });
        }
        for (0..3) |k| {
            if (vertices[t[k]] == vertices[t[(k + 1) % 3]]) return diag.fail(error.Degenerate, .{ .code = .edge_too_short, .label = "a triangle's edge", .measured = @floatFromInt(f) });
            edges[f][k] = try b.straight(vertices[t[k]], vertices[t[(k + 1) % 3]]);
        }
        loops[f] = .{.{ .edges = &edges[f] }};
        specs[f] = .{ .surface = try b.plane(frame), .loops = &loops[f], .uv_box = uv };
    }
    // The plane a face was given has its own x; the UV box must be in that plane's frame
    for (specs) |*spec| {
        const frame = b.body.geometry.planes.items[spec.surface.index].frame;
        var uv = geometry.Box2.empty;
        for (spec.loops[0].edges) |e| {
            const l = frame.toLocal(b.body.point(e.start));
            uv.grow(.{ l[0], l[1] });
        }
        spec.uv_box = uv;
    }
    return b.finish(specs, .outer);
}
