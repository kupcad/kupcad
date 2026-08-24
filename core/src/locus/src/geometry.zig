const std = @import("std");
const math = @import("math.zig");
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;

// ==========================================
// 1. CURVES (1D Parameter 't')
// ==========================================

pub const Line = struct {
    start: Vec3,
    end: Vec3,
};

pub const CircleArc = struct {
    center: Vec3,
    radius: f64,
    x_axis: Vec3, // Normalized vector pointing to angle 0
    y_axis: Vec3, // Normalized vector pointing to angle 90
};

pub const Curve = union(enum) {
    line: Line,
    circle_arc: CircleArc,
    // nurbs: NurbsCurve, // To be added later

    pub inline fn subs(self: Curve, t: f64) Vec3 {
        return switch (self) {
            .line => |l| math.add(l.start, math.scale(math.sub(l.end, l.start), t)),
            .circle_arc => |c| {
                const cos_t = @cos(t);
                const sin_t = @sin(t);
                const x_part = math.scale(c.x_axis, c.radius * cos_t);
                const y_part = math.scale(c.y_axis, c.radius * sin_t);
                return math.add(c.center, math.add(x_part, y_part));
            },
        };
    }
};

// ==========================================
// 2. SURFACES (2D Parameters 'u', 'v')
// ==========================================

pub const Plane = struct {
    origin: Vec3,
    u_axis: Vec3,
    v_axis: Vec3,
};

pub const Sphere = struct {
    center: Vec3,
    radius: f64,
};

pub const Cylinder = struct {
    origin: Vec3,
    axis: Vec3, // Z direction
    x_axis: Vec3, // Reference for u=0
    y_axis: Vec3, // Reference for u=pi/2
    radius: f64,
};

pub const Surface = union(enum) {
    plane: Plane,
    sphere: Sphere,
    cylinder: Cylinder,
    // torus: Torus,
    // nurbs: NurbsSurface,

    /// Evaluates the 3D coordinate at parameters (u, v)
    pub inline fn subs(self: Surface, u: f64, v: f64) Vec3 {
        return switch (self) {
            .plane => |p| math.add(p.origin, math.add(math.scale(p.u_axis, u), math.scale(p.v_axis, v))),
            .sphere => |s| {
                const nx = @sin(u) * @cos(v);
                const ny = @sin(u) * @sin(v);
                const nz = @cos(u);
                return math.add(s.center, math.scale(.{ nx, ny, nz }, s.radius));
            },
            .cylinder => |c| {
                // u is angle around axis, v is height along axis
                const cos_u = @cos(u);
                const sin_u = @sin(u);
                const r_part = math.add(math.scale(c.x_axis, cos_u), math.scale(c.y_axis, sin_u));
                const pos = math.add(c.origin, math.scale(r_part, c.radius));
                return math.add(pos, math.scale(c.axis, v));
            },
        };
    }

    /// Evaluates the 3D surface normal at parameters (u, v)
    pub inline fn normal(self: Surface, u: f64, v: f64) Vec3 {
        return switch (self) {
            .plane => |p| math.normalize(math.cross(p.u_axis, p.v_axis)),
            .sphere => |_| {
                return .{ @sin(u) * @cos(v), @sin(u) * @sin(v), @cos(u) };
            },
            .cylinder => |c| {
                const cos_u = @cos(u);
                const sin_u = @sin(u);
                return math.normalize(math.add(math.scale(c.x_axis, cos_u), math.scale(c.y_axis, sin_u)));
            },
        };
    }
};

// ==========================================
// 3. ARENA STORAGE
// ==========================================
/// Holds the actual mathematical data.
/// topology.zig holds indices pointing into these arrays!
pub const GeometryArena = struct {
    allocator: std.mem.Allocator,
    curves: std.ArrayListUnmanaged(Curve) = .empty,
    surfaces: std.ArrayListUnmanaged(Surface) = .empty,

    pub fn init(allocator: std.mem.Allocator) GeometryArena {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GeometryArena) void {
        self.curves.deinit(self.allocator);
        self.surfaces.deinit(self.allocator);
    }
};
