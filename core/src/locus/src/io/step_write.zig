//! The STEP writer (AP214, docs/architecture.md §7.9): one `MANIFOLD_SOLID_BREP` per
//! outer shell of each solid body (a body of two pieces is two solids), its vertices and edges written once, every curve and surface as its own
//! STEP entity (a plane as `PLANE`, a circle as `CIRCLE`, …) in Part 42's parameterization,
//! which is Locus's own, and every number at full `f64` precision (the shortest text that
//! reads back to the same double, never rounded). The file's uncertainty is the first
//! body's `zone`. A left-handed frame (a mirrored body's) has no STEP form: its surface is
//! written right-handed and the face's sense turned, which is the same face. A B-spline
//! curve or surface is written with its knots run into values and multiplicities, rational
//! ones as the complex entity with their weights; a swept surface names its generator. A
//! sheet body has no solid to write and is refused.
//!
//! `writeReported` returns the text with a `Report`: what was written (solids, shells,
//! faces, edges, vertices, the degenerate edges STEP has no entity for, the free-form
//! curves and surfaces written as B-splines, entities, bytes) and an **exchange error
//! bound**, what a reader may find the geometry off by: the largest gap recorded on a
//! vertex or edge, plus the frames' departure from orthonormal, plus 64 ulp of the largest
//! coordinate (research/opengeometry.md §2). The counts and the bound go into the file's
//! `FILE_DESCRIPTION` too, so a reader can compare them with what it finds.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const nurbs = @import("../geometry/nurbs.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const Body = body_mod.Body;
const Vec3 = vec.Vec3;

pub const Error = error{
    OutOfMemory,
    /// No body, or a sheet body: STEP's solid form has no open shells.
    NotSolid,
    /// A NURBS, extrusion or revolution: M1 writes them.
    NotImplemented,
    /// A traversal did not close.
    Corrupt,
};

/// The entity ids of the header; bodies start after them.
const HEADER_ENTITIES: u32 = 16;
/// The rounding share of a coordinate the error bound allows a reader: 64 ulp.
const READER_ULPS: f64 = 64.0 * std.math.floatEps(f64);

/// What a STEP file holds and how far its geometry may be off (the module doc).
pub const Report = struct {
    solids: u32 = 0,
    shells: u32 = 0,
    faces: u32 = 0,
    edges: u32 = 0,
    vertices: u32 = 0,
    /// Poles and apices: points, which STEP's loops close over; not written.
    degenerate_edges: u32 = 0,
    bspline_curves: u32 = 0,
    bspline_surfaces: u32 = 0,
    entities: u32 = 0,
    bytes: u64 = 0,
    /// The largest gap, plus the frames' departure from orthonormal, plus 64 ulp of the
    /// largest coordinate, over every body.
    error_bound: f64 = 0,
};

/// A written file with its report.
pub const Written = struct { text: []u8, report: Report };

const Writer = struct {
    allocator: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    next: u32 = HEADER_ENTITIES,
    report: Report = .{},

    fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator, .out = .init(allocator) };
    }

    /// Writes `#id=<fmt>;` and returns the id.
    fn emit(self: *Writer, comptime fmt: []const u8, args: anytype) Error!u32 {
        self.next += 1;
        self.out.writer.print("#{d}=" ++ fmt ++ ";\n", .{self.next} ++ args) catch return error.OutOfMemory;
        return self.next;
    }

    fn point(self: *Writer, p: Vec3) Error!u32 {
        return self.emit("CARTESIAN_POINT('',({f},{f},{f}))", .{ real(p[0]), real(p[1]), real(p[2]) });
    }

    fn direction(self: *Writer, d: Vec3) Error!u32 {
        return self.emit("DIRECTION('',({f},{f},{f}))", .{ real(d[0]), real(d[1]), real(d[2]) });
    }

    /// `AXIS2_PLACEMENT_3D` at `origin` with axis `z` and reference direction `x`.
    fn placement(self: *Writer, origin: Vec3, z: Vec3, x: Vec3) Error!u32 {
        const o = try self.point(origin);
        const az = try self.direction(z);
        const ax = try self.direction(x);
        return self.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ o, az, ax });
    }
};

/// A number as STEP wants it: the shortest text that reads back exactly, with a decimal
/// point or exponent (a REAL literal must have one).
const Real = struct {
    value: f64,
    pub fn format(self: Real, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{self.value}) catch unreachable;
        try w.writeAll(text);
        if (std.mem.indexOfAny(u8, text, ".eE") == null) try w.writeAll(".");
    }
};

fn real(v: f64) Real {
    return .{ .value = v };
}

/// The STEP file of `bodies`, each a solid, the caller's to free.
pub fn write(allocator: std.mem.Allocator, bodies: []const *const Body) Error![]u8 {
    const written = try writeReported(allocator, bodies);
    return written.text;
}

/// The STEP file of `bodies`, each a solid, with its report; the text is the caller's to
/// free. The bodies' entities are written first and the header, which describes them,
/// composed after (an entity's id does not depend on its place in the file).
pub fn writeReported(allocator: std.mem.Allocator, bodies: []const *const Body) Error!Written {
    if (bodies.len == 0) return error.NotSolid;
    for (bodies) |b| if (b.kind != .solid or b.isEmpty()) return error.NotSolid;
    var w = Writer.init(allocator);
    defer w.out.deinit();
    // Every solid's id comes first, so the representation can list them: one per outer
    // shell of each body
    var n_solids: u32 = 0;
    for (bodies) |b| n_solids += @intCast(outerShells(b));
    const first_solid = w.next + 1;
    w.next += n_solids;
    var solid_id = first_solid;
    for (bodies) |b| {
        try writeBody(&w, b, solid_id);
        solid_id += @intCast(outerShells(b));
        w.report.error_bound = @max(w.report.error_bound, exchangeErrorBound(b));
    }
    w.report.entities = w.next;
    const r = &w.report;
    var file: std.Io.Writer.Allocating = .init(allocator);
    errdefer file.deinit();
    file.writer.print(
        \\ISO-10303-21;
        \\HEADER;
        \\FILE_DESCRIPTION(('KupCAD B-Rep export','{d} solids, {d} shells, {d} faces, {d} edges, {d} vertices, error bound {e}'),'2;1');
        \\FILE_NAME('kupcad_export.step','','','','','','');
        \\FILE_SCHEMA(('AUTOMOTIVE_DESIGN {{ 1 0 10303 214 1 1 1 1 }}'));
        \\ENDSEC;
        \\DATA;
        \\#1=APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2001,#2);
        \\#2=APPLICATION_CONTEXT('core data for automotive mechanical design processes');
        \\#3=SHAPE_DEFINITION_REPRESENTATION(#4,#10);
        \\#4=PRODUCT_DEFINITION_SHAPE('','',#5);
        \\#5=PRODUCT_DEFINITION('design','',#6,#9);
        \\#6=PRODUCT_DEFINITION_FORMATION('','',#7);
        \\#7=PRODUCT('KupCAD Part','KupCAD Part','',(#8));
        \\#8=PRODUCT_CONTEXT('',#2,'mechanical');
        \\#9=PRODUCT_DEFINITION_CONTEXT('part definition',#2,'design');
        \\#10=ADVANCED_BREP_SHAPE_REPRESENTATION('',(
    , .{ r.solids, r.shells, r.faces, r.edges, r.vertices, r.error_bound }) catch return error.OutOfMemory;
    for (0..n_solids) |i| {
        file.writer.print("{s}#{d}", .{ if (i > 0) "," else "", first_solid + @as(u32, @intCast(i)) }) catch return error.OutOfMemory;
    }
    file.writer.print(
        \\),#12);
        \\#12=(GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#13)) GLOBAL_UNIT_ASSIGNED_CONTEXT((#14,#15,#16)) REPRESENTATION_CONTEXT('Context #1','3D Context with UNITS and UNCERTAINTY'));
        \\#13=UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE({f}),#14,'distance_accuracy_value','confusion accuracy');
        \\#14=(LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.));
        \\#15=(NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.));
        \\#16=(NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT());
        \\
    , .{real(bodies[0].tol.zone)}) catch return error.OutOfMemory;
    file.writer.writeAll(w.out.written()) catch return error.OutOfMemory;
    file.writer.writeAll("ENDSEC;\nEND-ISO-10303-21;\n") catch return error.OutOfMemory;
    const text = file.toOwnedSlice() catch return error.OutOfMemory;
    w.report.bytes = text.len;
    return .{ .text = text, .report = w.report };
}

/// How far a reader may find the body's geometry off: the largest gap of a vertex or
/// edge, plus the largest departure of a surface's or circle's frame from orthonormal
/// (a reader rebuilds the frame from the directions as written), plus 64 ulp of the
/// largest coordinate (what it may round them by).
fn exchangeErrorBound(body: *const Body) f64 {
    var gap: f64 = 0;
    var magnitude: f64 = 0;
    for (body.vertices.items) |v| {
        if (v.tombstone) continue;
        gap = @max(gap, v.gap);
        for (body.geometry.point(v.point)) |x| magnitude = @max(magnitude, @abs(x));
    }
    for (body.edges.items) |e| {
        if (!e.flags.tombstone) gap = @max(gap, e.gap);
    }
    var skew: f64 = 0;
    const g = &body.geometry;
    for (g.planes.items) |s| skew = @max(skew, frameSkew(s.frame));
    for (g.cylinders.items) |s| skew = @max(skew, frameSkew(s.frame));
    for (g.cones.items) |s| skew = @max(skew, frameSkew(s.frame));
    for (g.spheres.items) |s| skew = @max(skew, frameSkew(s.frame));
    for (g.tori.items) |s| skew = @max(skew, frameSkew(s.frame));
    for (g.revolutions.items) |s| skew = @max(skew, frameSkew(s.frame));
    for (g.circles.items) |c| skew = @max(skew, axesSkew(c.x, c.y));
    for (g.ellipses.items) |e| skew = @max(skew, axesSkew(e.x, e.y));
    return gap + skew + READER_ULPS * magnitude;
}

/// How far a frame is from orthonormal: the worst of its axes' lengths off 1 and their
/// dot products off 0.
fn frameSkew(frame: geometry.Frame) f64 {
    return @max(axesSkew(frame.x, frame.z), @max(axesSkew(frame.x, frame.y), axesSkew(frame.y, frame.z)));
}

fn axesSkew(a: Vec3, b: Vec3) f64 {
    return @max(@abs(vec.dot(a, b)), @max(@abs(vec.length(a) - 1.0), @abs(vec.length(b) - 1.0)));
}

/// The outer shells of a body, each written as a solid.
fn outerShells(body: *const Body) usize {
    var n: usize = 0;
    for (body.shells.items) |s| n += @intFromBool(!s.tombstone and s.kind == .outer);
    return n;
}

/// Writes the body's shells; its outer ones as the solids `first_solid_id` onward.
fn writeBody(w: *Writer, body: *const Body, first_solid_id: u32) Error!void {
    const allocator = w.allocator;
    // Vertices once
    const vertex_ids = try allocator.alloc(u32, body.vertices.items.len);
    defer allocator.free(vertex_ids);
    for (body.vertices.items, 0..) |v, i| {
        if (v.tombstone) continue;
        const p = try w.point(body.geometry.point(v.point));
        vertex_ids[i] = try w.emit("VERTEX_POINT('',#{d})", .{p});
        w.report.vertices += 1;
    }
    // Edges once, each with its curve
    const edge_ids = try allocator.alloc(u32, body.edges.items.len);
    defer allocator.free(edge_ids);
    for (body.edges.items, 0..) |e, i| {
        // A degenerate edge (a pole, an apex) is a point: STEP has no entity for it and
        // readers close the loop over it (what OCCT writes)
        if (e.flags.tombstone) continue;
        if (e.flags.degenerate) {
            w.report.degenerate_edges += 1;
            continue;
        }
        const curve_id = try writeCurve(w, body.geometry.curve(e.curve));
        edge_ids[i] = try w.emit("EDGE_CURVE('',#{d},#{d},#{d},.T.)", .{ vertex_ids[@backingInt(e.start)], vertex_ids[@backingInt(e.end)], curve_id });
        w.report.edges += 1;
    }
    // Faces: their loops of oriented edges, their surface, their bounds
    var face_ids = std.ArrayList(u32).empty;
    defer face_ids.deinit(allocator);
    var shells = traverse.Shells.init(body);
    var solid_id = first_solid_id;
    while (try shells.next()) |s| {
        face_ids.clearRetainingCapacity();
        var faces = traverse.Faces.init(body, s);
        while (try faces.next()) |f| {
            const face = body.face(f);
            var bound_ids = std.ArrayList(u32).empty;
            defer bound_ids.deinit(allocator);
            var loops = traverse.Loops.init(body, f);
            var first = true;
            while (try loops.next()) |l| {
                var oriented = std.ArrayList(u32).empty;
                defer oriented.deinit(allocator);
                var coedges = traverse.Coedges.init(body, l);
                while (try coedges.next()) |c| {
                    const ce = body.coedge(c);
                    if (body.edge(ce.edge).flags.degenerate) continue;
                    try oriented.append(allocator, try w.emit("ORIENTED_EDGE('',*,*,#{d},.{s}.)", .{ edge_ids[@backingInt(ce.edge)], if (ce.same_sense) "T" else "F" }));
                }
                w.next += 1;
                const loop_id = w.next;
                w.out.writer.print("#{d}=EDGE_LOOP('',(", .{loop_id}) catch return error.OutOfMemory;
                for (oriented.items, 0..) |id, k| w.out.writer.print("{s}#{d}", .{ if (k > 0) "," else "", id }) catch return error.OutOfMemory;
                w.out.writer.writeAll("));\n") catch return error.OutOfMemory;
                try bound_ids.append(allocator, try w.emit("{s}('',#{d},.T.)", .{ if (first) "FACE_OUTER_BOUND" else "FACE_BOUND", loop_id }));
                first = false;
            }
            const surface = body.geometry.surface(face.surface);
            const written = try writeSurface(w, surface);
            // A left-handed frame is written right-handed: its normal turns, so the sense does
            const sense = face.same_sense != written.flipped;
            w.next += 1;
            const face_id = w.next;
            w.out.writer.print("#{d}=ADVANCED_FACE('',(", .{face_id}) catch return error.OutOfMemory;
            for (bound_ids.items, 0..) |id, k| w.out.writer.print("{s}#{d}", .{ if (k > 0) "," else "", id }) catch return error.OutOfMemory;
            w.out.writer.print("),#{d},.{s}.);\n", .{ written.id, if (sense) "T" else "F" }) catch return error.OutOfMemory;
            try face_ids.append(allocator, face_id);
            w.report.faces += 1;
        }
        w.next += 1;
        const shell_id = w.next;
        w.out.writer.print("#{d}=CLOSED_SHELL('',(", .{shell_id}) catch return error.OutOfMemory;
        for (face_ids.items, 0..) |id, k| w.out.writer.print("{s}#{d}", .{ if (k > 0) "," else "", id }) catch return error.OutOfMemory;
        w.out.writer.writeAll("));\n") catch return error.OutOfMemory;
        w.report.shells += 1;
        if (body.shell(s).kind != .outer) continue;
        w.out.writer.print("#{d}=MANIFOLD_SOLID_BREP('',#{d});\n", .{ solid_id, shell_id }) catch return error.OutOfMemory;
        solid_id += 1;
        w.report.solids += 1;
    }
    if (solid_id == first_solid_id) return error.NotSolid;
}

fn writeCurve(w: *Writer, c: curves.Curve) Error!u32 {
    switch (c) {
        .line => |l| {
            const o = try w.point(l.o);
            const d = try w.direction(l.d);
            const v = try w.emit("VECTOR('',#{d},1.)", .{d});
            return w.emit("LINE('',#{d},#{d})", .{ o, v });
        },
        .circle => |ci| {
            const p = try w.placement(ci.c, ci.normal(), ci.x);
            return w.emit("CIRCLE('',#{d},{f})", .{ p, real(ci.r) });
        },
        .ellipse => |e| {
            const p = try w.placement(e.c, e.normal(), e.x);
            return w.emit("ELLIPSE('',#{d},{f},{f})", .{ p, real(e.a), real(e.b) });
        },
        .nurbs => |n| {
            w.report.bspline_curves += 1;
            return writeBSplineCurve(w, n);
        },
    }
}

/// `B_SPLINE_CURVE_WITH_KNOTS`, or the rational complex entity when a weight is not 1:
/// the control points as Cartesian points, the knots run into distinct values with their
/// multiplicities (Part 42 wants the end multiplicities `p + 1`, which the records keep).
fn writeBSplineCurve(w: *Writer, n: nurbs.Curve) Error!u32 {
    const allocator = w.allocator;
    const point_ids = try allocator.alloc(u32, n.points.len);
    defer allocator.free(point_ids);
    for (n.points, point_ids) |q, *id| id.* = try w.point(vec.project4(q));
    var runs = try knotRuns(allocator, n.knots);
    defer runs.deinit(allocator);
    w.next += 1;
    const id = w.next;
    const out = &w.out.writer;
    if (isRational(n.points)) {
        out.print("#{d}=(BOUNDED_CURVE() B_SPLINE_CURVE({d},", .{ id, n.degree }) catch return error.OutOfMemory;
        try writeIds(out, point_ids);
        out.writeAll(",.UNSPECIFIED.,.F.,.F.) B_SPLINE_CURVE_WITH_KNOTS(") catch return error.OutOfMemory;
        try runs.write(out);
        out.writeAll(",.UNSPECIFIED.) CURVE() GEOMETRIC_REPRESENTATION_ITEM() RATIONAL_B_SPLINE_CURVE(") catch return error.OutOfMemory;
        try writeWeights(out, n.points);
        out.writeAll(") REPRESENTATION_ITEM(''));\n") catch return error.OutOfMemory;
    } else {
        out.print("#{d}=B_SPLINE_CURVE_WITH_KNOTS('',{d},", .{ id, n.degree }) catch return error.OutOfMemory;
        try writeIds(out, point_ids);
        out.writeAll(",.UNSPECIFIED.,.F.,.F.,") catch return error.OutOfMemory;
        try runs.write(out);
        out.writeAll(",.UNSPECIFIED.);\n") catch return error.OutOfMemory;
    }
    return id;
}

/// `B_SPLINE_SURFACE_WITH_KNOTS`, or the rational complex entity: the control points as a
/// list of lists, the outer along u (a row per `i`, varying `j`), as the records store
/// them with `u` fastest.
fn writeBSplineSurface(w: *Writer, n: nurbs.Surface) Error!u32 {
    const allocator = w.allocator;
    const point_ids = try allocator.alloc(u32, n.points.len);
    defer allocator.free(point_ids);
    for (n.points, point_ids) |q, *id| id.* = try w.point(vec.project4(q));
    var runs_u = try knotRuns(allocator, n.knots_u);
    defer runs_u.deinit(allocator);
    var runs_v = try knotRuns(allocator, n.knots_v);
    defer runs_v.deinit(allocator);
    w.next += 1;
    const id = w.next;
    const out = &w.out.writer;
    const rational = isRational(n.points);
    if (rational) {
        out.print("#{d}=(BOUNDED_SURFACE() B_SPLINE_SURFACE({d},{d},", .{ id, n.degree_u, n.degree_v }) catch return error.OutOfMemory;
    } else {
        out.print("#{d}=B_SPLINE_SURFACE_WITH_KNOTS('',{d},{d},", .{ id, n.degree_u, n.degree_v }) catch return error.OutOfMemory;
    }
    out.writeAll("(") catch return error.OutOfMemory;
    for (0..n.count_u) |i| {
        if (i > 0) out.writeAll(",") catch return error.OutOfMemory;
        out.writeAll("(") catch return error.OutOfMemory;
        for (0..n.count_v) |j| out.print("{s}#{d}", .{ if (j > 0) "," else "", point_ids[i + j * n.count_u] }) catch return error.OutOfMemory;
        out.writeAll(")") catch return error.OutOfMemory;
    }
    out.writeAll(")") catch return error.OutOfMemory;
    if (rational) {
        out.writeAll(",.UNSPECIFIED.,.F.,.F.,.F.) B_SPLINE_SURFACE_WITH_KNOTS(") catch return error.OutOfMemory;
        try runs_u.writeMultiplicities(out);
        out.writeAll(",") catch return error.OutOfMemory;
        try runs_v.writeMultiplicities(out);
        out.writeAll(",") catch return error.OutOfMemory;
        try runs_u.writeKnots(out);
        out.writeAll(",") catch return error.OutOfMemory;
        try runs_v.writeKnots(out);
        out.writeAll(",.UNSPECIFIED.) GEOMETRIC_REPRESENTATION_ITEM() RATIONAL_B_SPLINE_SURFACE((") catch return error.OutOfMemory;
        for (0..n.count_u) |i| {
            if (i > 0) out.writeAll(",") catch return error.OutOfMemory;
            out.writeAll("(") catch return error.OutOfMemory;
            for (0..n.count_v) |j| out.print("{s}{f}", .{ if (j > 0) "," else "", real(n.points[i + j * n.count_u][3]) }) catch return error.OutOfMemory;
            out.writeAll(")") catch return error.OutOfMemory;
        }
        out.writeAll(")) REPRESENTATION_ITEM('') SURFACE());\n") catch return error.OutOfMemory;
    } else {
        out.writeAll(",.UNSPECIFIED.,.F.,.F.,.F.,") catch return error.OutOfMemory;
        try runs_u.writeMultiplicities(out);
        out.writeAll(",") catch return error.OutOfMemory;
        try runs_v.writeMultiplicities(out);
        out.writeAll(",") catch return error.OutOfMemory;
        try runs_u.writeKnots(out);
        out.writeAll(",") catch return error.OutOfMemory;
        try runs_v.writeKnots(out);
        out.writeAll(",.UNSPECIFIED.);\n") catch return error.OutOfMemory;
    }
    return id;
}

/// Whether any control point's weight is not 1: then the curve or surface is written as
/// the rational complex entity, with the weights.
fn isRational(points: []const vec.Vec4) bool {
    for (points) |q| if (q[3] != 1.0) return true;
    return false;
}

fn writeIds(out: *std.Io.Writer, ids: []const u32) Error!void {
    out.writeAll("(") catch return error.OutOfMemory;
    for (ids, 0..) |id, k| out.print("{s}#{d}", .{ if (k > 0) "," else "", id }) catch return error.OutOfMemory;
    out.writeAll(")") catch return error.OutOfMemory;
}

fn writeWeights(out: *std.Io.Writer, points: []const vec.Vec4) Error!void {
    out.writeAll("(") catch return error.OutOfMemory;
    for (points, 0..) |q, k| out.print("{s}{f}", .{ if (k > 0) "," else "", real(q[3]) }) catch return error.OutOfMemory;
    out.writeAll(")") catch return error.OutOfMemory;
}

/// A knot vector run into its distinct values and their multiplicities, as Part 42
/// writes it.
const KnotRuns = struct {
    knots: std.ArrayList(f64) = .empty,
    multiplicities: std.ArrayList(u32) = .empty,

    fn deinit(self: *KnotRuns, allocator: std.mem.Allocator) void {
        self.knots.deinit(allocator);
        self.multiplicities.deinit(allocator);
    }

    /// `(multiplicities),(knots)`.
    fn write(self: *const KnotRuns, out: *std.Io.Writer) Error!void {
        try self.writeMultiplicities(out);
        out.writeAll(",") catch return error.OutOfMemory;
        try self.writeKnots(out);
    }

    fn writeMultiplicities(self: *const KnotRuns, out: *std.Io.Writer) Error!void {
        out.writeAll("(") catch return error.OutOfMemory;
        for (self.multiplicities.items, 0..) |m, k| out.print("{s}{d}", .{ if (k > 0) "," else "", m }) catch return error.OutOfMemory;
        out.writeAll(")") catch return error.OutOfMemory;
    }

    fn writeKnots(self: *const KnotRuns, out: *std.Io.Writer) Error!void {
        out.writeAll("(") catch return error.OutOfMemory;
        for (self.knots.items, 0..) |u, k| out.print("{s}{f}", .{ if (k > 0) "," else "", real(u) }) catch return error.OutOfMemory;
        out.writeAll(")") catch return error.OutOfMemory;
    }
};

fn knotRuns(allocator: std.mem.Allocator, knots: []const f64) Error!KnotRuns {
    var runs = KnotRuns{};
    errdefer runs.deinit(allocator);
    for (knots) |u| {
        if (runs.knots.items.len > 0 and runs.knots.items[runs.knots.items.len - 1] == u) {
            runs.multiplicities.items[runs.multiplicities.items.len - 1] += 1;
        } else {
            try runs.knots.append(allocator, u);
            try runs.multiplicities.append(allocator, 1);
        }
    }
    return runs;
}

const WrittenSurface = struct { id: u32, flipped: bool };

fn writeSurface(w: *Writer, s: surfaces.Surface) Error!WrittenSurface {
    switch (s) {
        .plane => |p| {
            const pl = try w.placement(p.frame.origin, p.frame.z, p.frame.x);
            return .{ .id = try w.emit("PLANE('',#{d})", .{pl}), .flipped = p.frame.sign() < 0 };
        },
        .cylinder => |c| {
            const pl = try w.placement(c.frame.origin, c.frame.z, c.frame.x);
            return .{ .id = try w.emit("CYLINDRICAL_SURFACE('',#{d},{f})", .{ pl, real(c.r) }), .flipped = c.frame.sign() < 0 };
        },
        .cone => |c| {
            // STEP's semi-angle is positive (OpenCascade reads a negative one as zero): a
            // cone narrowing along its axis is the same surface widening along the axis
            // reversed, the same radius where the frames' origins coincide; the placement's
            // y follows its axis and x, so the handedness, and `flipped`, stay the frame's
            const axis = if (c.half_angle < 0) vec.neg(c.frame.z) else c.frame.z;
            const pl = try w.placement(c.frame.origin, axis, c.frame.x);
            return .{ .id = try w.emit("CONICAL_SURFACE('',#{d},{f},{f})", .{ pl, real(c.r), real(@abs(c.half_angle)) }), .flipped = c.frame.sign() < 0 };
        },
        .sphere => |sp| {
            const pl = try w.placement(sp.frame.origin, sp.frame.z, sp.frame.x);
            return .{ .id = try w.emit("SPHERICAL_SURFACE('',#{d},{f})", .{ pl, real(sp.r) }), .flipped = sp.frame.sign() < 0 };
        },
        .torus => |t| {
            const pl = try w.placement(t.frame.origin, t.frame.z, t.frame.x);
            return .{ .id = try w.emit("TOROIDAL_SURFACE('',#{d},{f},{f})", .{ pl, real(t.major), real(t.minor) }), .flipped = t.frame.sign() < 0 };
        },
        .extrusion => |e| {
            // The generator curve swept along a unit vector
            const curve_id = try writeCurve(w, e.curve);
            const d = try w.direction(e.d);
            const v = try w.emit("VECTOR('',#{d},1.)", .{d});
            return .{ .id = try w.emit("SURFACE_OF_LINEAR_EXTRUSION('',#{d},#{d})", .{ curve_id, v }), .flipped = false };
        },
        .revolution => |r| {
            const curve_id = try writeCurve(w, r.curve);
            const o = try w.point(r.frame.origin);
            const z = try w.direction(r.frame.z);
            const axis = try w.emit("AXIS1_PLACEMENT('',#{d},#{d})", .{ o, z });
            return .{ .id = try w.emit("SURFACE_OF_REVOLUTION('',#{d},#{d})", .{ curve_id, axis }), .flipped = false };
        },
        .nurbs => |n| {
            w.report.bspline_surfaces += 1;
            return .{ .id = try writeBSplineSurface(w, n), .flipped = false };
        },
    }
}
