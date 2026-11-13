//! The primitives (docs/architecture.md §7.1): a box, a cylinder as two half-faces and two
//! caps (D7), a sphere as two hemispheres with degenerate pole edges, a cone as two
//! half-faces with a degenerate apex edge where a radius is 0, a torus as four faces, the
//! planar sketch faces (a square, an exact circle, a polygon, polygons filled by the
//! even-odd rule) as sheet bodies on `z = 0`, and a polyhedron from triangles. Each builds its faces explicitly with analytic surfaces and exact edges, sews
//! them, and returns a body that passes the checker; the outer loops run counter-clockwise
//! seen from outside (the face to the left of each coedge), holes clockwise.

const std = @import("std");
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
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
const sketch_boolean = @import("../sketch/boolean.zig");
const overlay = @import("../sketch/overlay.zig");
const Body = body_mod.Body;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Frame = geometry.Frame;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;
const TWO_PI = geometry.TWO_PI;
const PI = std.math.pi;

/// A generator line as an edge from one point to another: see `Builder.generator`.
pub const Generator = struct { curve: geometry.CurveRef, t0: f64, t1: f64, forward: bool, pcurve: geometry.PCurveRef };

const HALF_PI = std.math.pi / 2.0;
pub const DEGENERATE: types.EdgeFlags = .{ .degenerate = true };
pub const SEAM: types.EdgeFlags = .{ .seam = true };

/// Where a body is built (the sweeps build with it too): the body, its interner, and the
/// diagnostics.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    body: Body,
    interner: Interner,
    diag: *Diagnostics,

    pub fn init(allocator: std.mem.Allocator, tol: Tolerance, kind: body_mod.Kind, diag: *Diagnostics) Error!Builder {
        try diagnostics.input.tolerance(diag, tol);
        var body = Body.init(allocator, tol);
        body.kind = kind;
        return .{ .allocator = allocator, .body = body, .interner = Interner.init(tol), .diag = diag };
    }

    /// Frees the interner alone: the body is the result, or freed by the caller's errdefer
    /// (after which `body.allocator` is gone, so the builder keeps its own).
    pub fn deinit(self: *Builder) void {
        self.interner.deinit(self.allocator);
    }

    /// The arena's, the interner's and the sewer's errors as the operation's.
    pub fn fail(self: *Builder, err: anyerror) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TooMany => self.diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "entities" }),
            error.OutOfRange => self.diag.fail(error.InvalidInput, .{ .code = .too_large_for_tolerance, .label = "a coordinate" }),
            error.NotManifold => self.diag.fail(error.NotValid, .{ .code = .edge_coedge_count, .label = "an edge" }),
            error.AtTolerance => self.diag.fail(error.Degenerate, .{ .code = .at_tolerance, .label = "a point, curve or surface the zone from a kept one to within rounding: the same record or not, either could be computed", .measured = self.interner.refused.?.measured, .threshold = self.interner.refused.?.limit }),
            else => unreachable,
        };
    }

    pub fn vertex(self: *Builder, p: Vec3) Error!types.VertexIndex {
        return self.vertexAt(try self.point(p));
    }

    /// The interned point at `p`: one record for every point within the zone of it.
    pub fn point(self: *Builder, p: Vec3) Error!geometry.PointIndex {
        return self.interner.point(self.body.allocator, &self.body.geometry, p) catch |e| return self.fail(e);
    }

    pub fn vertexAt(self: *Builder, at: geometry.PointIndex) Error!types.VertexIndex {
        return self.body.addVertex(.{ .point = at }) catch |e| return self.fail(e);
    }

    pub fn line(self: *Builder, a: Vec3, b: Vec3) Error!geometry.CurveRef {
        const l = curves.Line.through(a, b) orelse return self.diag.fail(error.Degenerate, .{ .code = .edge_too_short, .label = "an edge" });
        return self.interner.line(self.body.allocator, &self.body.geometry, l, a, b) catch |e| return self.fail(e);
    }

    pub fn plane(self: *Builder, frame: Frame) Error!geometry.SurfaceRef {
        return self.interner.plane(self.body.allocator, &self.body.geometry, .{ .frame = frame }) catch |e| return self.fail(e);
    }

    /// A planar face's surface and sense: the plane of `frame` interned, which may be a
    /// record of the same plane facing the other way (the interner keeps one per plane),
    /// and whether the face, facing along `frame.z`, faces the record's way. A face that
    /// took the record's normal for its own was inside out when a coplanar face facing the
    /// other way had made the record first (two sides of a sweep on one line, a groove's
    /// walls; `polyhedron` and the sweeps, 2026-11-12).
    pub fn facingPlane(self: *Builder, frame: Frame) Error!Facing {
        const surface = try self.plane(frame);
        const record = self.body.geometry.planes.items[surface.index];
        return .{ .surface = surface, .same_sense = vec.dot(record.frame.z, frame.z) > 0 };
    }

    pub const Facing = struct { surface: geometry.SurfaceRef, same_sense: bool };

    /// The straight edge from vertex `a` to `b`, in a loop's direction. The line is
    /// interned, so it may run the other way: the edge's own range follows the line, and
    /// `forward` says which way the loop runs it.
    pub fn straight(self: *Builder, a: types.VertexIndex, b: types.VertexIndex) Error!sew.EdgeSpec {
        const pa = self.body.point(a);
        const pb = self.body.point(b);
        const ref = try self.line(pa, pb);
        const l = self.body.geometry.curve(ref).line;
        const ta = l.project(pa);
        const tb = l.project(pb);
        return .{ .start = a, .end = b, .curve = ref, .t0 = @min(ta, tb), .t1 = @max(ta, tb), .forward = ta < tb };
    }

    /// The line from `a` to `b` interned, as the curve, range and direction of an edge from
    /// `a` to `b`, with its pcurve `(u, v)` on a surface whose `v` is the distance along the
    /// line from `a` (a cone's or an extrusion's generator).
    pub fn generator(self: *Builder, a: Vec3, b: Vec3, u: f64) Error!Generator {
        const ref = try self.line(a, b);
        const l = self.body.geometry.curve(ref).line;
        const ta = l.project(a);
        const tb = l.project(b);
        // v(t) = s·(t − ta), s the line's direction relative to a → b
        const sign: f64 = if (tb > ta) 1 else -1;
        const pcurve = self.body.geometry.addLine2(self.allocator, .{ .o = .{ u, -ta * sign }, .d = .{ 0, sign } }) catch |e| return self.fail(e);
        return .{ .curve = ref, .t0 = @min(ta, tb), .t1 = @max(ta, tb), .forward = tb > ta, .pcurve = pcurve };
    }

    /// A zero-radius circle at `p`: the curve of a degenerate edge (a pole, an apex), whose
    /// parameter is the `u` of its pcurve.
    pub fn pointCurve(self: *Builder, p: Vec3) Error!geometry.CurveRef {
        return self.interner.circle(self.allocator, &self.body.geometry, .{ .c = p, .x = vec.X3, .y = vec.Y3, .r = 0 }) catch |e| return self.fail(e);
    }

    pub fn pcurveLine(self: *Builder, o: Vec2, d: Vec2) Error!geometry.PCurveRef {
        return self.body.geometry.addLine2(self.allocator, .{ .o = o, .d = d }) catch |e| return self.fail(e);
    }

    /// The body, checked, or the checker's first finding as `error.NotValid`: a solid to
    /// level 1; a sheet to level 2 as well, whose hole rule is what tells a sketch of
    /// several outlines (a word's letters) from one with holes, which the even-odd builder
    /// cannot until the 2D kernel nests them.
    pub fn finish(self: *Builder, faces: []const sew.FaceSpec, kind: types.ShellKind) Error!Body {
        _ = sew.sew(&self.body, faces, kind) catch |e| return self.fail(e);
        const level: check.Level = if (kind == .sheet) .global else .geometric;
        var report = check.run(self.body.allocator, &self.body, level) catch return error.OutOfMemory;
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

/// A sphere of radius `r` about the origin: two hemispheres `u ∈ [0, π]` and `[π, 2π]` over
/// `v ∈ [−π/2, π/2]` (D7), the meridian through `(r, 0, 0)` one great circle used in two
/// halves as the seams, and a degenerate edge at each pole in each face.
pub fn sphere(allocator: std.mem.Allocator, tol: Tolerance, r: f64, diag: *Diagnostics) Error!Body {
    try diagnostics.input.positive(diag, "radius", r);
    var b = try Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const g = &b.body.geometry;
    const south = try b.vertex(.{ 0, 0, -r });
    const north = try b.vertex(.{ 0, 0, r });
    const surface = b.interner.sphere(allocator, g, .{ .frame = Frame.world, .r = r }) catch |e| return b.fail(e);
    // The meridian in the xz-plane, parameter θ: θ = v on the half at u = 0 (south to
    // north through (r, 0, 0)), θ = π − v on the half at u = π (north to south)
    const meridian = b.interner.circle(allocator, g, .{ .c = vec.ZERO3, .x = vec.X3, .y = vec.Z3, .r = r }) catch |e| return b.fail(e);
    const pole_s = try b.pointCurve(.{ 0, 0, -r });
    const pole_n = try b.pointCurve(.{ 0, 0, r });
    const pc_south = try b.pcurveLine(.{ 0, -HALF_PI }, .{ 1, 0 });
    const pc_north = try b.pcurveLine(.{ 0, HALF_PI }, .{ 1, 0 });
    const pc_m0 = try b.pcurveLine(.{ 0, 0 }, .{ 0, 1 });
    const pc_mpi = try b.pcurveLine(.{ PI, PI }, .{ 0, -1 });
    const pc_m2pi = try b.pcurveLine(.{ TWO_PI, 0 }, .{ 0, 1 });
    // Face A: u in [0, π], counter-clockwise in UV: the south pole, up the seam at u = π,
    // the north pole backwards, down the seam at u = 0
    const a_edges = [4]sew.EdgeSpec{
        .{ .start = south, .end = south, .curve = pole_s, .t0 = 0, .t1 = PI, .pcurve = pc_south, .flags = DEGENERATE },
        .{ .start = south, .end = north, .curve = meridian, .t0 = HALF_PI, .t1 = 3.0 * HALF_PI, .forward = false, .pcurve = pc_mpi, .flags = SEAM, .regularity = .g1 },
        .{ .start = north, .end = north, .curve = pole_n, .t0 = 0, .t1 = PI, .forward = false, .pcurve = pc_north, .flags = DEGENERATE },
        .{ .start = north, .end = south, .curve = meridian, .t0 = -HALF_PI, .t1 = HALF_PI, .forward = false, .pcurve = pc_m0, .flags = SEAM, .regularity = .g1 },
    };
    // Face B: u in [π, 2π]
    const b_edges = [4]sew.EdgeSpec{
        .{ .start = south, .end = south, .curve = pole_s, .t0 = PI, .t1 = TWO_PI, .pcurve = pc_south, .flags = DEGENERATE },
        .{ .start = south, .end = north, .curve = meridian, .t0 = -HALF_PI, .t1 = HALF_PI, .pcurve = pc_m2pi, .flags = SEAM, .regularity = .g1 },
        .{ .start = north, .end = north, .curve = pole_n, .t0 = PI, .t1 = TWO_PI, .forward = false, .pcurve = pc_north, .flags = DEGENERATE },
        .{ .start = north, .end = south, .curve = meridian, .t0 = HALF_PI, .t1 = 3.0 * HALF_PI, .pcurve = pc_mpi, .flags = SEAM, .regularity = .g1 },
    };
    const specs = [2]sew.FaceSpec{
        .{ .surface = surface, .loops = &.{.{ .edges = &a_edges }}, .uv_box = .{ .min = .{ 0, -HALF_PI }, .max = .{ PI, HALF_PI } } },
        .{ .surface = surface, .loops = &.{.{ .edges = &b_edges }}, .uv_box = .{ .min = .{ PI, -HALF_PI }, .max = .{ TWO_PI, HALF_PI } } },
    };
    return b.finish(&specs, .outer);
}

/// A cone from radius `r1` at the bottom to `r2` at the top (one of them may be 0: an
/// apex), `height` along `z` from the origin or about it when `center`: two half-faces of
/// one conical surface split at `u = 0` and `u = π` (D7), two generator seams, a planar
/// cap at each end that has a radius, and a degenerate edge in each face at an apex.
/// Equal radii give the cylinder.
pub fn cone(allocator: std.mem.Allocator, tol: Tolerance, r1: f64, r2: f64, height: f64, center: bool, diag: *Diagnostics) Error!Body {
    try diagnostics.input.finite(diag, "r1", r1);
    try diagnostics.input.finite(diag, "r2", r2);
    if (r1 < 0) return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "r1", .measured = r1 });
    if (r2 < 0) return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "r2", .measured = r2 });
    try diagnostics.input.positive(diag, "the larger radius", @max(r1, r2));
    try diagnostics.input.positive(diag, "height", height);
    if (r1 == r2) return cylinder(allocator, tol, r1, height, center, diag);
    var b = try Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const z0: f64 = if (center) -height / 2.0 else 0;
    const z1 = z0 + height;
    const g = &b.body.geometry;
    // The surface: v is the distance along a generator from the bottom, where the radius
    // is r1; the half-angle is negative for a cone that narrows upward
    const half_angle = trig.atan2(r2 - r1, height);
    const v_top = height / @cos(half_angle);
    const surface = b.interner.cone(allocator, g, .{ .frame = Frame.init(.{ 0, 0, z0 }, vec.X3, vec.Z3), .r = r1, .half_angle = half_angle }) catch |e| return b.fail(e);
    // The ends: a circle with two vertices, or an apex
    const bottom_0 = try b.vertex(.{ r1, 0, z0 });
    const bottom_pi = if (r1 > 0) try b.vertex(.{ -r1, 0, z0 }) else bottom_0;
    const top_0 = try b.vertex(.{ r2, 0, z1 });
    const top_pi = if (r2 > 0) try b.vertex(.{ -r2, 0, z1 }) else top_0;
    const bottom_curve = if (r1 > 0) b.interner.circle(allocator, g, .{ .c = .{ 0, 0, z0 }, .x = vec.X3, .y = vec.Y3, .r = r1 }) catch |e| return b.fail(e) else try b.pointCurve(.{ 0, 0, z0 });
    const top_curve = if (r2 > 0) b.interner.circle(allocator, g, .{ .c = .{ 0, 0, z1 }, .x = vec.X3, .y = vec.Y3, .r = r2 }) catch |e| return b.fail(e) else try b.pointCurve(.{ 0, 0, z1 });
    const bottom_flags: types.EdgeFlags = if (r1 > 0) .{} else DEGENERATE;
    const top_flags: types.EdgeFlags = if (r2 > 0) .{} else DEGENERATE;
    const pc_bottom = try b.pcurveLine(.{ 0, 0 }, .{ 1, 0 });
    const pc_top = try b.pcurveLine(.{ 0, v_top }, .{ 1, 0 });
    // The generators at u = 0 (with its pcurve at 0 for face A and at 2π for face B) and π
    const gen_0 = try b.generator(.{ r1, 0, z0 }, .{ r2, 0, z1 }, 0);
    const gen_2pi = try b.generator(.{ r1, 0, z0 }, .{ r2, 0, z1 }, TWO_PI);
    const gen_pi = try b.generator(.{ -r1, 0, z0 }, .{ -r2, 0, z1 }, PI);
    // Face A: u in [0, π], counter-clockwise in UV
    const a_edges = [4]sew.EdgeSpec{
        .{ .start = bottom_0, .end = bottom_pi, .curve = bottom_curve, .t0 = 0, .t1 = PI, .pcurve = pc_bottom, .flags = bottom_flags },
        .{ .start = bottom_pi, .end = top_pi, .curve = gen_pi.curve, .t0 = gen_pi.t0, .t1 = gen_pi.t1, .forward = gen_pi.forward, .pcurve = gen_pi.pcurve, .flags = SEAM, .regularity = .g1 },
        .{ .start = top_pi, .end = top_0, .curve = top_curve, .t0 = 0, .t1 = PI, .forward = false, .pcurve = pc_top, .flags = top_flags },
        .{ .start = top_0, .end = bottom_0, .curve = gen_0.curve, .t0 = gen_0.t0, .t1 = gen_0.t1, .forward = !gen_0.forward, .pcurve = gen_0.pcurve, .flags = SEAM, .regularity = .g1 },
    };
    // Face B: u in [π, 2π]
    const b_edges = [4]sew.EdgeSpec{
        .{ .start = bottom_pi, .end = bottom_0, .curve = bottom_curve, .t0 = PI, .t1 = TWO_PI, .pcurve = pc_bottom, .flags = bottom_flags },
        .{ .start = bottom_0, .end = top_0, .curve = gen_2pi.curve, .t0 = gen_2pi.t0, .t1 = gen_2pi.t1, .forward = gen_2pi.forward, .pcurve = gen_2pi.pcurve, .flags = SEAM, .regularity = .g1 },
        .{ .start = top_0, .end = top_pi, .curve = top_curve, .t0 = PI, .t1 = TWO_PI, .forward = false, .pcurve = pc_top, .flags = top_flags },
        .{ .start = top_pi, .end = bottom_pi, .curve = gen_pi.curve, .t0 = gen_pi.t0, .t1 = gen_pi.t1, .forward = !gen_pi.forward, .pcurve = gen_pi.pcurve, .flags = SEAM, .regularity = .g1 },
    };
    // The caps, as the cylinder's: the bottom clockwise seen from above, the top counter-
    // clockwise
    const bottom_edges = [2]sew.EdgeSpec{
        .{ .start = bottom_0, .end = bottom_pi, .curve = bottom_curve, .t0 = PI, .t1 = TWO_PI, .forward = false },
        .{ .start = bottom_pi, .end = bottom_0, .curve = bottom_curve, .t0 = 0, .t1 = PI, .forward = false },
    };
    const top_edges = [2]sew.EdgeSpec{
        .{ .start = top_0, .end = top_pi, .curve = top_curve, .t0 = 0, .t1 = PI },
        .{ .start = top_pi, .end = top_0, .curve = top_curve, .t0 = PI, .t1 = TWO_PI },
    };
    var specs: [4]sew.FaceSpec = undefined;
    var n: usize = 0;
    specs[n] = .{ .surface = surface, .loops = &.{.{ .edges = &a_edges }}, .uv_box = .{ .min = .{ 0, 0 }, .max = .{ PI, v_top } } };
    n += 1;
    specs[n] = .{ .surface = surface, .loops = &.{.{ .edges = &b_edges }}, .uv_box = .{ .min = .{ PI, 0 }, .max = .{ TWO_PI, v_top } } };
    n += 1;
    if (r1 > 0) {
        specs[n] = .{ .surface = try b.plane(Frame.init(.{ 0, 0, z0 }, vec.X3, vec.neg(vec.Z3))), .loops = &.{.{ .edges = &bottom_edges }}, .uv_box = .{ .min = .{ -r1, -r1 }, .max = .{ r1, r1 } } };
        n += 1;
    }
    if (r2 > 0) {
        specs[n] = .{ .surface = try b.plane(Frame.init(.{ 0, 0, z1 }, vec.X3, vec.Z3)), .loops = &.{.{ .edges = &top_edges }}, .uv_box = .{ .min = .{ -r2, -r2 }, .max = .{ r2, r2 } } };
        n += 1;
    }
    return b.finish(specs[0..n], .outer);
}

/// A ring torus about `z` through the origin: the tube of radius `minor` about the circle
/// of radius `major`, as four faces, `u` (about the axis) and `v` (about the tube) each
/// split at 0 and π (D7). The tube must be thinner than the ring.
pub fn torus(allocator: std.mem.Allocator, tol: Tolerance, major: f64, minor: f64, diag: *Diagnostics) Error!Body {
    try diagnostics.input.positive(diag, "major radius", major);
    try diagnostics.input.positive(diag, "minor radius", minor);
    if (!(minor < major)) return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "the ring's width (major − minor)", .measured = major - minor });
    var b = try Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const g = &b.body.geometry;
    const surface = b.interner.torus(allocator, g, .{ .frame = Frame.world, .major = major, .minor = minor }) catch |e| return b.fail(e);
    // The vertices at (u, v) in {0, π}²; the circles along u at v = 0 (outer) and v = π
    // (inner), and along v (the tube) at u = 0 and u = π, each with its own parameter
    const corner = [2][2]types.VertexIndex{
        .{ try b.vertex(.{ major + minor, 0, 0 }), try b.vertex(.{ major - minor, 0, 0 }) },
        .{ try b.vertex(.{ -(major + minor), 0, 0 }), try b.vertex(.{ -(major - minor), 0, 0 }) },
    };
    const outer = b.interner.circle(allocator, g, .{ .c = vec.ZERO3, .x = vec.X3, .y = vec.Y3, .r = major + minor }) catch |e| return b.fail(e);
    const inner = b.interner.circle(allocator, g, .{ .c = vec.ZERO3, .x = vec.X3, .y = vec.Y3, .r = major - minor }) catch |e| return b.fail(e);
    const tube_0 = b.interner.circle(allocator, g, .{ .c = .{ major, 0, 0 }, .x = vec.X3, .y = vec.Z3, .r = minor }) catch |e| return b.fail(e);
    const tube_pi = b.interner.circle(allocator, g, .{ .c = .{ -major, 0, 0 }, .x = vec.neg(vec.X3), .y = vec.Z3, .r = minor }) catch |e| return b.fail(e);
    const along_u = [2]geometry.CurveRef{ outer, inner };
    const along_v = [2]geometry.CurveRef{ tube_0, tube_pi };
    // Pcurves: a line at v = 0, π, 2π along u, and at u = 0, π, 2π along v
    var pc_u: [3]geometry.PCurveRef = undefined;
    var pc_v: [3]geometry.PCurveRef = undefined;
    for (0..3) |k| {
        const at = @as(f64, @floatFromInt(k)) * PI;
        pc_u[k] = try b.pcurveLine(.{ 0, at }, .{ 1, 0 });
        pc_v[k] = try b.pcurveLine(.{ at, 0 }, .{ 0, 1 });
    }
    // Each face (i, j) covers u in [iπ, (i+1)π], v in [jπ, (j+1)π]: counter-clockwise in
    // UV, along u at the low v, along v at the high u, back along u at the high v, back
    // along v at the low u
    var edges: [4][4]sew.EdgeSpec = undefined;
    var loops: [4][1]sew.LoopSpec = undefined;
    var specs: [4]sew.FaceSpec = undefined;
    for (0..2) |i| for (0..2) |j| {
        const f = i * 2 + j;
        const u_low = @as(f64, @floatFromInt(i)) * PI;
        const v_low = @as(f64, @floatFromInt(j)) * PI;
        edges[f] = .{
            .{ .start = corner[i][j], .end = corner[1 - i][j], .curve = along_u[j], .t0 = u_low, .t1 = u_low + PI, .pcurve = pc_u[j] },
            .{ .start = corner[1 - i][j], .end = corner[1 - i][1 - j], .curve = along_v[1 - i], .t0 = v_low, .t1 = v_low + PI, .pcurve = pc_v[i + 1] },
            .{ .start = corner[1 - i][1 - j], .end = corner[i][1 - j], .curve = along_u[1 - j], .t0 = u_low, .t1 = u_low + PI, .forward = false, .pcurve = pc_u[j + 1] },
            .{ .start = corner[i][1 - j], .end = corner[i][j], .curve = along_v[i], .t0 = v_low, .t1 = v_low + PI, .forward = false, .pcurve = pc_v[i] },
        };
        loops[f] = .{.{ .edges = &edges[f] }};
        specs[f] = .{ .surface = surface, .loops = &loops[f], .uv_box = .{ .min = .{ u_low, v_low }, .max = .{ u_low + PI, v_low + PI } } };
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

/// A sheet body on `z = 0` of the region the polygons `contours` fill by the even-odd
/// rule, whichever way each runs: an outline inside another is a hole, one inside the
/// hole an island, outlines apart are faces of their own, and a self-crossing outline
/// fills both its lobes (the overlay engine's fill). A contour of fewer than three points
/// is refused; a point repeating the one before it is that corner once.
pub fn polygonsEvenOdd(allocator: std.mem.Allocator, tol: Tolerance, contours: []const []const Vec2, diag: *Diagnostics) Error!Body {
    try diagnostics.input.nonEmpty(diag, "contours", contours.len);
    for (contours) |c| {
        if (c.len < 3) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "a contour", .measured = @floatFromInt(c.len), .threshold = 3 });
        for (c) |p| {
            try diagnostics.input.finite(diag, "a point", p[0]);
            try diagnostics.input.finite(diag, "a point", p[1]);
        }
    }
    var sheet = try sketch_boolean.evenOdd(allocator, tol, contours, diag);
    errdefer sheet.deinit();
    // A region of no area is no polygon (a contour along a line, or outlines cancelling)
    if (sheet.isEmpty()) return diag.fail(error.Degenerate, .{ .code = .empty_input, .label = "the polygon's area" });
    return sheet;
}

/// An edge of an outline for `outlines`: from `a` to `b`, straight, or along the circle of
/// `arc` (its centre and radius; counter-clockwise about the centre when `ccw`).
pub const OutlineEdge = overlay.InputEdge;
pub const OutlineArc = overlay.Arc;

/// A sheet body on `z = 0` filled by the even-odd rule from closed outlines of lines and
/// arcs: a closed path, a rectangle with rounded corners, a polygon with eased corners,
/// exact. An outline's edges run head to tail, each ending within the zone of where the
/// next starts, and an arc's ends lie on its circle within the zone; a full circle is two
/// arcs. Which way an outline runs does not matter (the even-odd rule: an outline inside
/// another is a hole, a self-crossing one fills both lobes). Refused with a finding when
/// an edge is unchained, an arc's end is off its circle, a radius is not positive, or the
/// outlines enclose no area.
pub fn outlines(allocator: std.mem.Allocator, tol: Tolerance, contours: []const []const OutlineEdge, diag: *Diagnostics) Error!Body {
    try diagnostics.input.nonEmpty(diag, "outlines", contours.len);
    for (contours) |c| {
        try diagnostics.input.nonEmpty(diag, "an outline", c.len);
        for (c, 0..) |e, i| {
            for ([_]f64{ e.a[0], e.a[1], e.b[0], e.b[1] }) |x| try diagnostics.input.finite(diag, "a point", x);
            if (e.arc) |arc| {
                try diagnostics.input.finite(diag, "an arc's centre", arc.c[0]);
                try diagnostics.input.finite(diag, "an arc's centre", arc.c[1]);
                try diagnostics.input.positive(diag, "an arc's radius", arc.r);
                for ([_]Vec2{ e.a, e.b }) |p| {
                    const off = @abs(vec.distance2(p, arc.c) - arc.r);
                    if (off > tol.zone) return diag.fail(error.InvalidInput, .{ .code = .vertex_off_curve, .entity = .of(.edge, i), .label = "an arc's end off its circle", .measured = off, .threshold = tol.zone });
                }
            }
            const gap = vec.distance2(e.b, c[(i + 1) % c.len].a);
            if (gap > tol.zone) return diag.fail(error.InvalidInput, .{ .code = .loop_not_connected, .entity = .of(.edge, i), .label = "an outline's edge ends off the next one's start", .measured = gap, .threshold = tol.zone });
        }
    }
    var sheet = try sketch_boolean.evenOddEdges(allocator, tol, contours, diag);
    errdefer sheet.deinit();
    if (sheet.isEmpty()) return diag.fail(error.Degenerate, .{ .code = .empty_input, .label = "the outlines' area" });
    return sheet;
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
/// from outside), coplanar triangles sharing one plane record, a triangle facing against
/// the record's normal taking the opposite sense (two parts touching across a plane): a
/// closed triangulated polyhedron. Triangles that don't close a shell are
/// `error.NotValid`.
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
        // The plane record is shared whichever way a coplanar triangle faces
        const facing = try b.facingPlane(frame);
        specs[f] = .{ .surface = facing.surface, .same_sense = facing.same_sense, .loops = &loops[f], .uv_box = uv };
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
