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
        self.planes.deinit(allocator);
        self.spheres.deinit(allocator);
        self.cylinders.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *GeometryArena) void {
        self.lines.clearRetainingCapacity();
        self.circle_arcs.clearRetainingCapacity();
        self.planes.clearRetainingCapacity();
        self.spheres.clearRetainingCapacity();
        self.cylinders.clearRetainingCapacity();
    }

    /// Projects a 3D point onto a surface's 2D UV coordinate system.
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

    /// Computes the 3D surface normal at a given UV coordinate.
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

    /// Evaluates 3D coordinates from 2D UV parameter values.
    pub fn surfaceSubs(self: GeometryArena, id: SurfaceId, u: f64, v: f64) math.Vec3 {
        switch (id.surface_type) {
            .plane => {
                const p = self.planes.items[id.index];
                return math.add(p.origin, math.add(math.scale(p.u_axis, u), math.scale(p.v_axis, v)));
            },
            .sphere => {
                const s = self.spheres.items[id.index];
                const theta = u * 2.0 * std.math.pi;
                const phi = (v - 0.5) * std.math.pi;
                const dir = math.Vec3{
                    @cos(phi) * @cos(theta),
                    @cos(phi) * @sin(theta),
                    @sin(phi),
                };
                return math.add(s.center, math.scale(dir, s.radius));
            },
            .cylinder => {
                const c = self.cylinders.items[id.index];
                const radial = math.add(math.scale(c.x_axis, @cos(u) * c.radius), math.scale(c.y_axis, @sin(u) * c.radius));
                return math.add(c.origin, math.add(radial, math.scale(c.axis, v)));
            },
            .nurbs => return .{ 0, 0, 0 },
        }
    }
};
