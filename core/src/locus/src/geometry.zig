const std = @import("std");
const math = @import("math.zig");

pub const CurveType = enum(u8) {
    line,
    circle_arc,
    nurbs,
};

pub const SurfaceType = enum(u8) {
    plane,
    sphere,
    cylinder,
    cone,
    torus,
    nurbs,
};

pub const CurveId = packed struct {
    index: u24,
    curve_type: CurveType,
};

pub const SurfaceId = packed struct {
    index: u24,
    surface_type: SurfaceType,
};

pub const Line = struct {
    start: math.Vec3,
    end: math.Vec3,
};

pub const CircleArc = struct {
    center: math.Vec3,
    radius: f64,
    x_axis: math.Vec3,
    y_axis: math.Vec3,
};

pub const NurbsCurve = struct {
    degree: u32,
    knots: []const f64,
    control_points: []const math.Vec4, // Pre-weighted homogeneous coordinates (wx, wy, wz, w)
};

pub const Plane = struct {
    origin: math.Vec3,
    u_axis: math.Vec3,
    v_axis: math.Vec3,
};

pub const Sphere = struct {
    center: math.Vec3,
    radius: f64,
};

pub const Cylinder = struct {
    origin: math.Vec3,
    axis: math.Vec3,
    x_axis: math.Vec3,
    y_axis: math.Vec3,
    radius: f64,
};

pub const Cone = struct {
    origin: math.Vec3,
    axis: math.Vec3,
    x_axis: math.Vec3,
    y_axis: math.Vec3,
    radius: f64,
    half_angle: f64,
};

pub const Torus = struct {
    center: math.Vec3,
    axis: math.Vec3,
    x_axis: math.Vec3,
    y_axis: math.Vec3,
    major_radius: f64,
    minor_radius: f64,
};

pub const GeometryArena = struct {
    lines: std.ArrayListUnmanaged(Line) = .empty,
    circle_arcs: std.ArrayListUnmanaged(CircleArc) = .empty,
    nurbs_curves: std.ArrayListUnmanaged(NurbsCurve) = .empty,
    planes: std.ArrayListUnmanaged(Plane) = .empty,
    spheres: std.ArrayListUnmanaged(Sphere) = .empty,
    cylinders: std.ArrayListUnmanaged(Cylinder) = .empty,
    cones: std.ArrayListUnmanaged(Cone) = .empty,
    toruses: std.ArrayListUnmanaged(Torus) = .empty,

    pub fn init(allocator: std.mem.Allocator) GeometryArena {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *GeometryArena, allocator: std.mem.Allocator) void {
        self.lines.deinit(allocator);
        self.circle_arcs.deinit(allocator);
        self.nurbs_curves.deinit(allocator);
        self.planes.deinit(allocator);
        self.spheres.deinit(allocator);
        self.cylinders.deinit(allocator);
        self.cones.deinit(allocator);
        self.toruses.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *GeometryArena) void {
        self.lines.clearRetainingCapacity();
        self.circle_arcs.clearRetainingCapacity();
        self.nurbs_curves.clearRetainingCapacity();
        self.planes.clearRetainingCapacity();
        self.spheres.clearRetainingCapacity();
        self.cylinders.clearRetainingCapacity();
        self.cones.clearRetainingCapacity();
        self.toruses.clearRetainingCapacity();
    }

    pub fn surfaceProject(self: GeometryArena, id: SurfaceId, pt: math.Vec3) math.Vec2 {
        switch (id.surface_type) {
            .plane => {
                const p = self.planes.items[id.index];
                const v = math.sub(pt, p.origin);
                return .{ math.dot(v, p.u_axis), math.dot(v, p.v_axis) };
            },
            .sphere => {
                const s = self.spheres.items[id.index];
                const v = math.normalize(math.sub(pt, s.center));
                const u = 0.5 + std.math.atan2(v[1], v[0]) / (2.0 * std.math.pi);
                const v_val = 0.5 - std.math.asin(std.math.clamp(v[2], -1.0, 1.0)) / std.math.pi;
                return .{ u, v_val };
            },
            .cylinder => {
                const c = self.cylinders.items[id.index];
                const v = math.sub(pt, c.origin);
                const z_val = math.dot(v, c.axis);
                const proj = math.sub(v, math.scale(c.axis, z_val));
                const x_val = math.dot(proj, c.x_axis);
                const y_val = math.dot(proj, c.y_axis);
                const theta = std.math.atan2(y_val, x_val);
                return .{ theta, z_val };
            },
            .cone => {
                const c = self.cones.items[id.index];
                const v = math.sub(pt, c.origin);
                const z_val = math.dot(v, c.axis);
                const proj = math.sub(v, math.scale(c.axis, z_val));
                const x_val = math.dot(proj, c.x_axis);
                const y_val = math.dot(proj, c.y_axis);
                const u = std.math.atan2(y_val, x_val);
                const v_val = z_val / @cos(c.half_angle);
                return .{ u, v_val };
            },
            .torus => {
                const t = self.toruses.items[id.index];
                const v = math.sub(pt, t.center);
                const z_val = math.dot(v, t.axis);
                const proj = math.sub(v, math.scale(t.axis, z_val));
                const x_val = math.dot(proj, t.x_axis);
                const y_val = math.dot(proj, t.y_axis);
                const u = std.math.atan2(y_val, x_val);
                const proj_mag = math.mag(proj);
                const r_val = proj_mag - t.major_radius;
                const v_val = std.math.atan2(z_val, r_val);
                return .{ u, v_val };
            },
            .nurbs => return .{ 0, 0 },
        }
    }

    pub fn surfaceNormal(self: GeometryArena, id: SurfaceId, u: f64, v: f64) math.Vec3 {
        switch (id.surface_type) {
            .plane => {
                const p = self.planes.items[id.index];
                return math.normalize(math.cross(p.u_axis, p.v_axis));
            },
            .sphere => {
                // Requires exact 3D point evaluation context for spherical coordinate fallback
                return .{ 0, 0, 1 };
            },
            .cylinder => {
                const c = self.cylinders.items[id.index];
                const cos_u = @cos(u);
                const sin_u = @sin(u);
                return math.normalize(math.add(math.scale(c.x_axis, cos_u), math.scale(c.y_axis, sin_u)));
            },
            .cone => {
                const c = self.cones.items[id.index];
                const cos_u = @cos(u);
                const sin_u = @sin(u);
                const radial = math.add(math.scale(c.x_axis, cos_u), math.scale(c.y_axis, sin_u));
                const cos_ha = @cos(c.half_angle);
                const sin_ha = @sin(c.half_angle);
                return math.normalize(math.add(math.scale(radial, cos_ha), math.scale(c.axis, -sin_ha)));
            },
            .torus => {
                const t = self.toruses.items[id.index];
                const cos_u = @cos(u);
                const sin_u = @sin(u);
                const radial = math.add(math.scale(t.x_axis, cos_u), math.scale(t.y_axis, sin_u));
                const cos_v = @cos(v);
                const sin_v = @sin(v);
                return math.normalize(math.add(math.scale(radial, cos_v), math.scale(t.axis, sin_v)));
            },
            .nurbs => return .{ 0, 0, 1 },
        }
    }
};

/// Evaluates a 3D coordinate point along a NURBS curve at parameter T using Cox-de Boor.
pub fn evaluateNurbsCurve(curve: NurbsCurve, t: f64) math.Vec3 {
    const n = curve.control_points.len;
    const p = curve.degree;
    const knots = curve.knots;

    var span: usize = p;
    while (span < n and knots[span + 1] <= t) : (span += 1) {}
    if (t >= knots[n]) span = n - 1;

    var N = [_]f64{0} ** 20;
    N[0] = 1.0;
    var left = [_]f64{0} ** 20;
    var right = [_]f64{0} ** 20;

    for (1..p + 1) |j| {
        left[j] = t - knots[span + 1 - j];
        right[j] = knots[span + j] - t;
        var saved: f64 = 0.0;
        for (0..j) |r| {
            const temp = N[r] / (right[r + 1] + left[j - r]);
            N[r] = saved + right[r + 1] * temp;
            saved = left[j - r] * temp;
        }
        N[j] = saved;
    }

    var cw = math.Vec4{ 0, 0, 0, 0 };
    for (0..p + 1) |j| {
        const cp = curve.control_points[span - p + j];
        const basis = N[j];
        cw[0] += cp[0] * basis;
        cw[1] += cp[1] * basis;
        cw[2] += cp[2] * basis;
        cw[3] += cp[3] * basis;
    }

    if (cw[3] != 0.0) {
        return .{ cw[0] / cw[3], cw[1] / cw[3], cw[2] / cw[3] };
    }
    return .{ cw[0], cw[1], cw[2] };
}
