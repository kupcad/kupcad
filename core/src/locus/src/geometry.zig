const std = @import("std");
const math = @import("math.zig");

pub const CurveType = enum(u8) {
    line,
    circle_arc,
    nurbs,
};

pub const PCurveType = enum(u8) {
    line_2d,
    nurbs_2d,
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

pub const PCurveId = packed struct {
    index: u24,
    curve_type: PCurveType,
};

pub const SurfaceId = packed struct {
    index: u24,
    surface_type: SurfaceType,
};

pub const Line = struct {
    start: math.Vec3,
    end: math.Vec3,
};

pub const Line2D = struct {
    start: math.Vec2,
    end: math.Vec2,
};

pub const CircleArc = struct {
    center: math.Vec3,
    radius: f64,
    x_axis: math.Vec3,
    y_axis: math.Vec3,
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
    lines_2d: std.ArrayListUnmanaged(Line2D) = .empty,
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
        self.lines_2d.deinit(allocator);
        self.circle_arcs.deinit(allocator);
        // Free heap-allocated slices inside each NURBS curve before deallocating the list
        for (self.nurbs_curves.items) |nc| {
            allocator.free(nc.knots);
            allocator.free(nc.control_points);
        }
        self.nurbs_curves.deinit(allocator);
        self.planes.deinit(allocator);
        self.spheres.deinit(allocator);
        self.cylinders.deinit(allocator);
        self.cones.deinit(allocator);
        self.toruses.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *GeometryArena, allocator: std.mem.Allocator) void {
        self.lines.clearRetainingCapacity();
        self.lines_2d.clearRetainingCapacity();
        self.circle_arcs.clearRetainingCapacity();
        for (self.nurbs_curves.items) |nc| {
            allocator.free(nc.knots);
            allocator.free(nc.control_points);
        }
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

/// Evaluates the Cox-de Boor basis function N_{i,p}(u) recursively.
pub fn coxDeBoor(i: usize, p: usize, u: f64, knots: []const f64) f64 {
    if (p == 0) {
        // Special case: upper bound inclusion for the last valid knot span
        if (u == knots[knots.len - 1] and u == knots[i + 1] and knots[i] != knots[i + 1]) {
            return 1.0;
        }
        if (u >= knots[i] and u < knots[i + 1]) {
            return 1.0;
        }
        return 0.0;
    }

    const denom1 = knots[i + p] - knots[i];
    const term1 = if (denom1 > 1e-12) ((u - knots[i]) / denom1) * coxDeBoor(i, p - 1, u, knots) else 0.0;

    const denom2 = knots[i + p + 1] - knots[i + 1];
    const term2 = if (denom2 > 1e-12) ((knots[i + p + 1] - u) / denom2) * coxDeBoor(i + 1, p - 1, u, knots) else 0.0;

    return term1 + term2;
}

pub const NurbsCurve = struct {
    degree: usize,
    knots: []const f64,
    // Control points are stored as 4D homogeneous coordinates: { x*w, y*w, z*w, w }
    control_points: []const math.Vec4,

    /// Evaluates the curve exactly at parameter u.
    pub fn evaluate(self: NurbsCurve, u: f64) math.Vec3 {
        var pt = math.Vec4{ 0, 0, 0, 0 };
        for (self.control_points, 0..) |cp, i| {
            const nip = coxDeBoor(i, self.degree, u, self.knots);
            pt[0] += nip * cp[0];
            pt[1] += nip * cp[1];
            pt[2] += nip * cp[2];
            pt[3] += nip * cp[3]; // Weight accumulation
        }

        if (pt[3] > 1e-12) {
            return .{ pt[0] / pt[3], pt[1] / pt[3], pt[2] / pt[3] };
        }
        return .{ pt[0], pt[1], pt[2] };
    }
};

pub const NurbsSurface = struct {
    degree_u: usize,
    degree_v: usize,
    knots_u: []const f64,
    knots_v: []const f64,
    num_cp_u: usize,
    num_cp_v: usize,
    // Stored as a flat array: row-major (u changes fastest)
    control_points: []const math.Vec4,

    /// Evaluates the surface exactly at parametric coordinates (u, v).
    pub fn evaluate(self: NurbsSurface, u: f64, v: f64) math.Vec3 {
        var pt = math.Vec4{ 0, 0, 0, 0 };

        for (0..self.num_cp_v) |j| {
            const njq = coxDeBoor(j, self.degree_v, v, self.knots_v);
            if (njq < 1e-12) continue; // Optimization: skip empty V spans

            for (0..self.num_cp_u) |i| {
                const nip = coxDeBoor(i, self.degree_u, u, self.knots_u);
                if (nip < 1e-12) continue;

                const basis = nip * njq;
                const idx = j * self.num_cp_u + i;
                const cp = self.control_points[idx];

                pt[0] += basis * cp[0];
                pt[1] += basis * cp[1];
                pt[2] += basis * cp[2];
                pt[3] += basis * cp[3];
            }
        }

        if (pt[3] > 1e-12) {
            return .{ pt[0] / pt[3], pt[1] / pt[3], pt[2] / pt[3] };
        }
        return .{ pt[0], pt[1], pt[2] };
    }
};
