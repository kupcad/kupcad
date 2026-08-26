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

pub const GeometryArena = struct {
    lines: std.ArrayListUnmanaged(Line) = .empty,
    circle_arcs: std.ArrayListUnmanaged(CircleArc) = .empty,
    nurbs_curves: std.ArrayListUnmanaged(NurbsCurve) = .empty,
    planes: std.ArrayListUnmanaged(Plane) = .empty,
    spheres: std.ArrayListUnmanaged(Sphere) = .empty,
    cylinders: std.ArrayListUnmanaged(Cylinder) = .empty,

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
    }

    pub fn clearRetainingCapacity(self: *GeometryArena) void {
        self.lines.clearRetainingCapacity();
        self.circle_arcs.clearRetainingCapacity();
        self.nurbs_curves.clearRetainingCapacity();
        self.planes.clearRetainingCapacity();
        self.spheres.clearRetainingCapacity();
        self.cylinders.clearRetainingCapacity();
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
            .nurbs => return .{ 0, 0 },
        }
    }

    pub fn surfaceNormal(self: GeometryArena, id: SurfaceId, u: f64, v: f64) math.Vec3 {
        _ = u;
        _ = v;
        switch (id.surface_type) {
            .plane => {
                const p = self.planes.items[id.index];
                return math.normalize(math.cross(p.u_axis, p.v_axis));
            },
            .sphere => {
                const s = self.spheres.items[id.index];
                _ = s;
                return .{ 0, 0, 1 };
            },
            .cylinder => {
                const c = self.cylinders.items[id.index];
                return c.x_axis;
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
