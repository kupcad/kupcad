const std = @import("std");
const math = @import("math.zig");
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;

// ==========================================
// 1. TYPED HANDLES (Strict DOD)
// ==========================================

pub const CurveType = enum(u8) {
    line = 0,
    circle_arc = 1,
    nurbs = 2,
};

/// A 32-bit integer for Curves. Top 8 bits = type, bottom 24 bits = array index.
pub const CurveId = packed struct(u32) {
    index: u24,
    curve_type: CurveType,
};

pub const SurfaceType = enum(u8) {
    plane = 0,
    sphere = 1,
    cylinder = 2,
    nurbs = 3,
};

/// A 32-bit integer for Surfaces. Top 8 bits = type, bottom 24 bits = array index.
pub const SurfaceId = packed struct(u32) {
    index: u24,
    surface_type: SurfaceType,
};

// ==========================================
// 2. CURVES (1D Parameter 't')
// ==========================================

pub const Line = struct {
    start: Vec3,
    end: Vec3,

    pub inline fn subs(self: Line, t: f64) Vec3 {
        return math.add(self.start, math.scale(math.sub(self.end, self.start), t));
    }
};

pub const CircleArc = struct {
    center: Vec3,
    radius: f64,
    x_axis: Vec3, // Normalized vector pointing to angle 0
    y_axis: Vec3, // Normalized vector pointing to angle 90

    pub inline fn subs(self: CircleArc, t: f64) Vec3 {
        const cos_t = @cos(t);
        const sin_t = @sin(t);
        const x_part = math.scale(self.x_axis, self.radius * cos_t);
        const y_part = math.scale(self.y_axis, self.radius * sin_t);
        return math.add(self.center, math.add(x_part, y_part));
    }
};

pub const NurbsCurve = struct {
    degree: u32,
    knots: []const f64,
    control_points: []const math.Vec4,

    pub inline fn subs(self: NurbsCurve, t: f64) Vec3 {
        return evaluateNurbsCurve(self, t);
    }
};

// ==========================================
// 3. SURFACES (2D Parameters 'u', 'v')
// ==========================================

pub const Plane = struct {
    origin: Vec3,
    u_axis: Vec3,
    v_axis: Vec3,

    pub inline fn subs(self: Plane, u: f64, v: f64) Vec3 {
        return math.add(self.origin, math.add(math.scale(self.u_axis, u), math.scale(self.v_axis, v)));
    }

    pub inline fn normal(self: Plane, u: f64, v: f64) Vec3 {
        _ = u;
        _ = v; // Planes have constant normals
        return math.normalize(math.cross(self.u_axis, self.v_axis));
    }

    pub inline fn projectPoint(self: Plane, pt: Vec3) Vec2 {
        const d = math.sub(pt, self.origin);
        return .{ math.dot(d, self.u_axis), math.dot(d, self.v_axis) };
    }
};

pub const Sphere = struct {
    center: Vec3,
    radius: f64,

    pub inline fn subs(self: Sphere, u: f64, v: f64) Vec3 {
        const nx = @sin(u) * @cos(v);
        const ny = @sin(u) * @sin(v);
        const nz = @cos(u);
        return math.add(self.center, math.scale(.{ nx, ny, nz }, self.radius));
    }

    pub inline fn normal(self: Sphere, u: f64, v: f64) Vec3 {
        _ = self;
        return .{ @sin(u) * @cos(v), @sin(u) * @sin(v), @cos(u) };
    }

    pub inline fn projectPoint(self: Sphere, pt: Vec3) Vec2 {
        const d = math.normalize(math.sub(pt, self.center));
        const u = std.math.atan2(d[1], d[0]); // Longitude
        const v = std.math.acos(d[2]); // Latitude (from Z axis)
        return .{ u, v };
    }
};

pub const Cylinder = struct {
    origin: Vec3,
    axis: Vec3,
    x_axis: Vec3,
    y_axis: Vec3,
    radius: f64,

    pub inline fn subs(self: Cylinder, u: f64, v: f64) Vec3 {
        const cos_u = @cos(u);
        const sin_u = @sin(u);
        const r_part = math.add(math.scale(self.x_axis, cos_u), math.scale(self.y_axis, sin_u));
        const pos = math.add(self.origin, math.scale(r_part, self.radius));
        return math.add(pos, math.scale(self.axis, v));
    }

    pub inline fn normal(self: Cylinder, u: f64, v: f64) Vec3 {
        _ = v;
        const cos_u = @cos(u);
        const sin_u = @sin(u);
        return math.normalize(math.add(math.scale(self.x_axis, cos_u), math.scale(self.y_axis, sin_u)));
    }

    pub inline fn projectPoint(self: Cylinder, pt: Vec3) Vec2 {
        const d = math.sub(pt, self.origin);
        const v = math.dot(d, self.axis); // Height along cylinder
        const dx = math.dot(d, self.x_axis);
        const dy = math.dot(d, self.y_axis);
        const u = std.math.atan2(dy, dx);
        return .{ u, v };
    }
};

// ==========================================
// 4. ARENA STORAGE (Centralized Dispatch)
// ==========================================

/// Holds the actual mathematical data.
/// Memory is perfectly contiguous per primitive type.
pub const GeometryArena = struct {
    allocator: std.mem.Allocator,

    // Curves
    lines: std.ArrayListUnmanaged(Line) = .empty,
    circle_arcs: std.ArrayListUnmanaged(CircleArc) = .empty,
    nurbs_curves: std.ArrayListUnmanaged(NurbsCurve) = .empty,

    // Surfaces
    planes: std.ArrayListUnmanaged(Plane) = .empty,
    spheres: std.ArrayListUnmanaged(Sphere) = .empty,
    cylinders: std.ArrayListUnmanaged(Cylinder) = .empty,
    // nurbs_surfaces: std.ArrayListUnmanaged(NurbsSurface) = .empty,

    pub fn init(allocator: std.mem.Allocator) GeometryArena {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GeometryArena) void {
        self.lines.deinit(self.allocator);
        self.circle_arcs.deinit(self.allocator);
        self.nurbs_curves.deinit(self.allocator);

        self.planes.deinit(self.allocator);
        self.spheres.deinit(self.allocator);
        self.cylinders.deinit(self.allocator);
    }

    // --- Curve Dispatchers ---
    pub inline fn curveSubs(self: *const GeometryArena, id: CurveId, t: f64) Vec3 {
        return switch (id.curve_type) {
            .line => self.lines.items[id.index].subs(t),
            .circle_arc => self.circle_arcs.items[id.index].subs(t),
            .nurbs => self.nurbs_curves.items[id.index].subs(t),
        };
    }

    // --- Surface Dispatchers ---
    pub inline fn surfaceSubs(self: *const GeometryArena, id: SurfaceId, u: f64, v: f64) Vec3 {
        return switch (id.surface_type) {
            .plane => self.planes.items[id.index].subs(u, v),
            .sphere => self.spheres.items[id.index].subs(u, v),
            .cylinder => self.cylinders.items[id.index].subs(u, v),
            .nurbs => unreachable,
        };
    }

    pub inline fn surfaceNormal(self: *const GeometryArena, id: SurfaceId, u: f64, v: f64) Vec3 {
        return switch (id.surface_type) {
            .plane => self.planes.items[id.index].normal(u, v),
            .sphere => self.spheres.items[id.index].normal(u, v),
            .cylinder => self.cylinders.items[id.index].normal(u, v),
            .nurbs => unreachable,
        };
    }

    pub inline fn surfaceProject(self: *const GeometryArena, id: SurfaceId, pt: Vec3) Vec2 {
        return switch (id.surface_type) {
            .plane => self.planes.items[id.index].projectPoint(pt),
            .sphere => self.spheres.items[id.index].projectPoint(pt),
            .cylinder => self.cylinders.items[id.index].projectPoint(pt),
            .nurbs => unreachable,
        };
    }
};

// ==========================================
// 5. MATH ALGORITHMS
// ==========================================

/// Evaluates the B-Spline basis functions for a given parameter `t`.
/// Returns the starting index of the control points and populates `out_basis`.
fn bsplineBasis(knots: []const f64, degree: u32, t: f64, out_basis: []f64) u32 {
    const n = @as(u32, @intCast(knots.len - 1));
    var idx: u32 = degree;

    // Find knot span
    while (idx < n - degree) : (idx += 1) {
        if (t >= knots[idx] and t < knots[idx + 1]) break;
    }
    if (t >= knots[n - degree]) idx = n - degree - 1;

    @memset(out_basis[0 .. degree + 1], 0.0);
    out_basis[degree] = 1.0;

    // Cox-de Boor recursion
    var left = [_]f64{0.0} ** 16; // Stack buffer for max degree 15
    var right = [_]f64{0.0} ** 16;

    for (1..degree + 1) |j| {
        left[j] = t - knots[idx + 1 - j];
        right[j] = knots[idx + j] - t;
        var saved: f64 = 0.0;

        for (0..j) |r| {
            const temp = out_basis[degree - j + 1 + r] / (right[r + 1] + left[j - r]);
            out_basis[degree - j + r] = saved + right[r + 1] * temp;
            saved = left[j - r] * temp;
        }
        out_basis[degree] = saved;
    }
    return idx - degree;
}

pub fn evaluateNurbsCurve(nurbs: NurbsCurve, t: f64) math.Vec3 {
    var basis = [_]f64{0.0} ** 16;
    const span_idx = bsplineBasis(nurbs.knots, nurbs.degree, t, &basis);

    var pt4 = math.Vec4{ 0, 0, 0, 0 };
    for (0..nurbs.degree + 1) |i| {
        const b = basis[i];
        const cp = nurbs.control_points[span_idx + i];
        pt4[0] += cp[0] * b;
        pt4[1] += cp[1] * b;
        pt4[2] += cp[2] * b;
        pt4[3] += cp[3] * b; // Weight
    }

    // Perspective divide
    if (pt4[3] < math.MATH_EPSILON) return .{ 0, 0, 0 };
    const inv_w = 1.0 / pt4[3];
    return .{ pt4[0] * inv_w, pt4[1] * inv_w, pt4[2] * inv_w };
}
