//! The geometry arena: one array per kind (docs/architecture.md §3), addressed by the
//! packed references of types.zig, with the NURBS knots and control points in pools so a
//! curve or surface record is a few integers and nothing in the arena owns memory of its
//! own. A reference resolves to a view (`curve`, `surface`, `pcurve`), valid until the
//! arena grows. Interning (spatial/intern.zig) sits over `add*` so equal geometry gets one
//! index; the arena itself never compares.

const std = @import("std");
const vec = @import("../math/vec.zig");
const types = @import("types.zig");
const curves = @import("curves.zig");
const pcurves = @import("pcurves.zig");
const surfaces = @import("surfaces.zig");
const nurbs = @import("nurbs.zig");
const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;
const CurveRef = types.CurveRef;
const SurfaceRef = types.SurfaceRef;
const PCurveRef = types.PCurveRef;
const PointIndex = types.PointIndex;

pub const Error = error{
    OutOfMemory,
    /// A kind's array reached `types.MAX_PER_KIND`, or the points `u32`.
    TooMany,
};

/// A run of a pool: `pool[start .. start + len]`.
pub const Range = struct { start: u32, len: u32 };

pub const NurbsCurveRec = struct { degree: u8, knots: Range, points: Range };
pub const Nurbs2Rec = struct { degree: u8, knots: Range, points: Range };
pub const NurbsSurfaceRec = struct { degree_u: u8, degree_v: u8, knots_u: Range, knots_v: Range, count_u: u32, count_v: u32, points: Range };
pub const ExtrusionRec = struct { curve: CurveRef, d: Vec3 };
pub const RevolutionRec = struct { curve: CurveRef, frame: types.Frame };

pub const Geometry = struct {
    points: std.ArrayList(Vec3) = .empty,

    lines: std.ArrayList(curves.Line) = .empty,
    circles: std.ArrayList(curves.Circle) = .empty,
    ellipses: std.ArrayList(curves.Ellipse) = .empty,
    nurbs_curves: std.ArrayList(NurbsCurveRec) = .empty,

    planes: std.ArrayList(surfaces.Plane) = .empty,
    cylinders: std.ArrayList(surfaces.Cylinder) = .empty,
    cones: std.ArrayList(surfaces.Cone) = .empty,
    spheres: std.ArrayList(surfaces.Sphere) = .empty,
    tori: std.ArrayList(surfaces.Torus) = .empty,
    extrusions: std.ArrayList(ExtrusionRec) = .empty,
    revolutions: std.ArrayList(RevolutionRec) = .empty,
    nurbs_surfaces: std.ArrayList(NurbsSurfaceRec) = .empty,

    lines2: std.ArrayList(pcurves.Line2) = .empty,
    circles2: std.ArrayList(pcurves.Circle2) = .empty,
    nurbs_pcurves: std.ArrayList(Nurbs2Rec) = .empty,

    /// Knots of every NURBS curve, pcurve and surface.
    knot_pool: std.ArrayList(f64) = .empty,
    /// Control points of every NURBS curve and surface.
    point4_pool: std.ArrayList(Vec4) = .empty,
    /// Control points of every NURBS pcurve.
    point3_pool: std.ArrayList(Vec3) = .empty,

    pub const empty: Geometry = .{};

    pub fn deinit(self: *Geometry, allocator: std.mem.Allocator) void {
        inline for (comptime std.meta.fieldNames(Geometry)) |name| @field(self, name).deinit(allocator);
        self.* = undefined;
    }

    /// A deep copy.
    pub fn clone(self: *const Geometry, allocator: std.mem.Allocator) Error!Geometry {
        var out: Geometry = .empty;
        errdefer out.deinit(allocator);
        inline for (comptime std.meta.fieldNames(Geometry)) |name| {
            try @field(out, name).appendSlice(allocator, @field(self, name).items);
        }
        return out;
    }

    // --- points ---

    pub fn addPoint(self: *Geometry, allocator: std.mem.Allocator, p: Vec3) Error!PointIndex {
        if (self.points.items.len >= std.math.maxInt(u32)) return error.TooMany;
        try self.points.append(allocator, p);
        return PointIndex.of(self.points.items.len - 1);
    }

    pub fn point(self: *const Geometry, index: PointIndex) Vec3 {
        return self.points.items[@backingInt(index)];
    }

    // --- curves ---

    pub fn addLine(self: *Geometry, allocator: std.mem.Allocator, line: curves.Line) Error!CurveRef {
        return addKind(CurveRef, .line, &self.lines, allocator, line);
    }

    pub fn addCircle(self: *Geometry, allocator: std.mem.Allocator, circle: curves.Circle) Error!CurveRef {
        return addKind(CurveRef, .circle, &self.circles, allocator, circle);
    }

    pub fn addEllipse(self: *Geometry, allocator: std.mem.Allocator, ellipse: curves.Ellipse) Error!CurveRef {
        return addKind(CurveRef, .ellipse, &self.ellipses, allocator, ellipse);
    }

    /// Copies `data` into the pools (the caller keeps ownership of `data`).
    pub fn addNurbsCurve(self: *Geometry, allocator: std.mem.Allocator, data: nurbs.Curve) Error!CurveRef {
        if (self.nurbs_curves.items.len >= types.MAX_PER_KIND) return error.TooMany;
        const knots = try self.pushKnots(allocator, data.knots);
        const points = try self.pushPoints4(allocator, data.points);
        try self.nurbs_curves.append(allocator, .{ .degree = data.degree, .knots = knots, .points = points });
        return CurveRef.of(.nurbs, self.nurbs_curves.items.len - 1);
    }

    pub fn curve(self: *const Geometry, ref: CurveRef) curves.Curve {
        const i = ref.index;
        return switch (ref.kind) {
            .line => .{ .line = self.lines.items[i] },
            .circle => .{ .circle = self.circles.items[i] },
            .ellipse => .{ .ellipse = self.ellipses.items[i] },
            .nurbs => .{ .nurbs = self.nurbsCurve(self.nurbs_curves.items[i]) },
        };
    }

    fn nurbsCurve(self: *const Geometry, rec: NurbsCurveRec) nurbs.Curve {
        return .{ .degree = rec.degree, .knots = self.knot_pool.items[rec.knots.start .. rec.knots.start + rec.knots.len], .points = self.point4_pool.items[rec.points.start .. rec.points.start + rec.points.len] };
    }

    /// A curve of the arena as owned data (a NURBS copied out, an analytic kind converted
    /// over `[t0, t1]`).
    pub fn curveToNurbs(self: *const Geometry, allocator: std.mem.Allocator, ref: CurveRef, t0: f64, t1: f64) nurbs.Error!nurbs.CurveData {
        return self.curve(ref).toNurbs(allocator, t0, t1);
    }

    // --- surfaces ---

    pub fn addPlane(self: *Geometry, allocator: std.mem.Allocator, plane: surfaces.Plane) Error!SurfaceRef {
        return addKind(SurfaceRef, .plane, &self.planes, allocator, plane);
    }

    pub fn addCylinder(self: *Geometry, allocator: std.mem.Allocator, cylinder: surfaces.Cylinder) Error!SurfaceRef {
        return addKind(SurfaceRef, .cylinder, &self.cylinders, allocator, cylinder);
    }

    pub fn addCone(self: *Geometry, allocator: std.mem.Allocator, cone: surfaces.Cone) Error!SurfaceRef {
        return addKind(SurfaceRef, .cone, &self.cones, allocator, cone);
    }

    pub fn addSphere(self: *Geometry, allocator: std.mem.Allocator, sphere: surfaces.Sphere) Error!SurfaceRef {
        return addKind(SurfaceRef, .sphere, &self.spheres, allocator, sphere);
    }

    pub fn addTorus(self: *Geometry, allocator: std.mem.Allocator, torus: surfaces.Torus) Error!SurfaceRef {
        return addKind(SurfaceRef, .torus, &self.tori, allocator, torus);
    }

    /// The extrusion of the arena's curve `generator` along unit `d`.
    pub fn addExtrusion(self: *Geometry, allocator: std.mem.Allocator, generator: CurveRef, d: Vec3) Error!SurfaceRef {
        return addKind(SurfaceRef, .extrusion, &self.extrusions, allocator, ExtrusionRec{ .curve = generator, .d = d });
    }

    /// The revolution of the arena's curve `generator` about the axis through `origin`
    /// along unit `axis`.
    pub fn addRevolution(self: *Geometry, allocator: std.mem.Allocator, generator: CurveRef, origin: Vec3, axis: Vec3) Error!SurfaceRef {
        return addKind(SurfaceRef, .revolution, &self.revolutions, allocator, RevolutionRec{ .curve = generator, .frame = types.Frame.fromAxis(origin, axis) });
    }

    pub fn addNurbsSurface(self: *Geometry, allocator: std.mem.Allocator, data: nurbs.Surface) Error!SurfaceRef {
        if (self.nurbs_surfaces.items.len >= types.MAX_PER_KIND) return error.TooMany;
        const knots_u = try self.pushKnots(allocator, data.knots_u);
        const knots_v = try self.pushKnots(allocator, data.knots_v);
        const points = try self.pushPoints4(allocator, data.points);
        try self.nurbs_surfaces.append(allocator, .{ .degree_u = data.degree_u, .degree_v = data.degree_v, .knots_u = knots_u, .knots_v = knots_v, .count_u = data.count_u, .count_v = data.count_v, .points = points });
        return SurfaceRef.of(.nurbs, self.nurbs_surfaces.items.len - 1);
    }

    pub fn surface(self: *const Geometry, ref: SurfaceRef) surfaces.Surface {
        const i = ref.index;
        return switch (ref.kind) {
            .plane => .{ .plane = self.planes.items[i] },
            .cylinder => .{ .cylinder = self.cylinders.items[i] },
            .cone => .{ .cone = self.cones.items[i] },
            .sphere => .{ .sphere = self.spheres.items[i] },
            .torus => .{ .torus = self.tori.items[i] },
            .extrusion => .{ .extrusion = .{ .curve = self.curve(self.extrusions.items[i].curve), .d = self.extrusions.items[i].d } },
            .revolution => .{ .revolution = .{ .curve = self.curve(self.revolutions.items[i].curve), .frame = self.revolutions.items[i].frame } },
            .nurbs => .{ .nurbs = self.nurbsSurface(self.nurbs_surfaces.items[i]) },
        };
    }

    fn nurbsSurface(self: *const Geometry, rec: NurbsSurfaceRec) nurbs.Surface {
        return .{
            .degree_u = rec.degree_u,
            .degree_v = rec.degree_v,
            .knots_u = self.knot_pool.items[rec.knots_u.start .. rec.knots_u.start + rec.knots_u.len],
            .knots_v = self.knot_pool.items[rec.knots_v.start .. rec.knots_v.start + rec.knots_v.len],
            .count_u = rec.count_u,
            .count_v = rec.count_v,
            .points = self.point4_pool.items[rec.points.start .. rec.points.start + rec.points.len],
        };
    }

    // --- pcurves ---

    pub fn addLine2(self: *Geometry, allocator: std.mem.Allocator, line: pcurves.Line2) Error!PCurveRef {
        return addKind(PCurveRef, .line2, &self.lines2, allocator, line);
    }

    pub fn addCircle2(self: *Geometry, allocator: std.mem.Allocator, circle: pcurves.Circle2) Error!PCurveRef {
        return addKind(PCurveRef, .circle2, &self.circles2, allocator, circle);
    }

    pub fn addNurbs2(self: *Geometry, allocator: std.mem.Allocator, data: nurbs.Curve2) Error!PCurveRef {
        if (self.nurbs_pcurves.items.len >= types.MAX_PER_KIND) return error.TooMany;
        const knots = try self.pushKnots(allocator, data.knots);
        const start = self.point3_pool.items.len;
        if (start + data.points.len > std.math.maxInt(u32)) return error.TooMany;
        try self.point3_pool.appendSlice(allocator, data.points);
        try self.nurbs_pcurves.append(allocator, .{ .degree = data.degree, .knots = knots, .points = .{ .start = @intCast(start), .len = @intCast(data.points.len) } });
        return PCurveRef.of(.nurbs2, self.nurbs_pcurves.items.len - 1);
    }

    pub fn pcurve(self: *const Geometry, ref: PCurveRef) pcurves.PCurve {
        const i = ref.index;
        return switch (ref.kind) {
            .line2 => .{ .line2 = self.lines2.items[i] },
            .circle2 => .{ .circle2 = self.circles2.items[i] },
            .nurbs2 => .{ .nurbs2 = blk: {
                const rec = self.nurbs_pcurves.items[i];
                break :blk .{ .degree = rec.degree, .knots = self.knot_pool.items[rec.knots.start .. rec.knots.start + rec.knots.len], .points = self.point3_pool.items[rec.points.start .. rec.points.start + rec.points.len] };
            } },
        };
    }

    // --- counts ---

    pub fn curveCount(self: *const Geometry) usize {
        return self.lines.items.len + self.circles.items.len + self.ellipses.items.len + self.nurbs_curves.items.len;
    }

    pub fn surfaceCount(self: *const Geometry) usize {
        return self.planes.items.len + self.cylinders.items.len + self.cones.items.len + self.spheres.items.len + self.tori.items.len +
            self.extrusions.items.len + self.revolutions.items.len + self.nurbs_surfaces.items.len;
    }

    fn pushKnots(self: *Geometry, allocator: std.mem.Allocator, knots: []const f64) Error!Range {
        const start = self.knot_pool.items.len;
        if (start + knots.len > std.math.maxInt(u32)) return error.TooMany;
        try self.knot_pool.appendSlice(allocator, knots);
        return .{ .start = @intCast(start), .len = @intCast(knots.len) };
    }

    fn pushPoints4(self: *Geometry, allocator: std.mem.Allocator, points: []const Vec4) Error!Range {
        const start = self.point4_pool.items.len;
        if (start + points.len > std.math.maxInt(u32)) return error.TooMany;
        try self.point4_pool.appendSlice(allocator, points);
        return .{ .start = @intCast(start), .len = @intCast(points.len) };
    }
};

fn addKind(comptime Ref: type, comptime kind: anytype, list: anytype, allocator: std.mem.Allocator, item: anytype) Error!Ref {
    if (list.items.len >= types.MAX_PER_KIND) return error.TooMany;
    try list.append(allocator, item);
    return Ref.of(kind, list.items.len - 1);
}
