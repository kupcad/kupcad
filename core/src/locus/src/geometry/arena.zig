const std = @import("std");
pub const math = @import("../math.zig");
pub const curves = @import("curves.zig");
pub const surfaces = @import("surfaces.zig");
pub const types = @import("types.zig");

pub const CurveType = types.CurveType;
pub const PCurveType = types.PCurveType;
pub const SurfaceType = types.SurfaceType;
pub const CurveId = types.CurveId;
pub const PCurveId = types.PCurveId;
pub const SurfaceId = types.SurfaceId;

pub const GeometryArena = struct {
    points: std.ArrayListUnmanaged(math.Vec3) = .empty,
    lines: std.ArrayListUnmanaged(curves.Line) = .empty,
    lines_2d: std.ArrayListUnmanaged(curves.Line2D) = .empty,
    circle_arcs: std.ArrayListUnmanaged(curves.CircleArc) = .empty,
    nurbs_curves: std.ArrayListUnmanaged(curves.NurbsCurve) = .empty,
    nurbs_pcurves: std.ArrayListUnmanaged(curves.NurbsCurve2D) = .empty,
    nurbs_surfaces: std.ArrayListUnmanaged(surfaces.NurbsSurface) = .empty,
    planes: std.ArrayListUnmanaged(surfaces.Plane) = .empty,
    spheres: std.ArrayListUnmanaged(surfaces.Sphere) = .empty,
    cylinders: std.ArrayListUnmanaged(surfaces.Cylinder) = .empty,
    cones: std.ArrayListUnmanaged(surfaces.Cone) = .empty,
    toruses: std.ArrayListUnmanaged(surfaces.Torus) = .empty,

    pub fn init() GeometryArena {
        return .{};
    }

    pub fn deinit(self: *GeometryArena, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
        self.lines.deinit(allocator);
        self.lines_2d.deinit(allocator);
        self.circle_arcs.deinit(allocator);

        for (self.nurbs_curves.items) |nc| {
            allocator.free(nc.knots);
            allocator.free(nc.control_points);
        }
        self.nurbs_curves.deinit(allocator);

        for (self.nurbs_pcurves.items) |nc| {
            allocator.free(nc.knots);
            allocator.free(nc.control_points);
        }
        self.nurbs_pcurves.deinit(allocator);

        for (self.nurbs_surfaces.items) |ns| {
            allocator.free(ns.knots_u);
            allocator.free(ns.knots_v);
            allocator.free(ns.control_points);
        }
        self.nurbs_surfaces.deinit(allocator);

        self.planes.deinit(allocator);
        self.spheres.deinit(allocator);
        self.cylinders.deinit(allocator);
        self.cones.deinit(allocator);
        self.toruses.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *GeometryArena, allocator: std.mem.Allocator) void {
        self.points.clearRetainingCapacity();
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

    pub fn surfaceProject(self: *const GeometryArena, handle: SurfaceId, pt: math.Vec3) math.Vec2 {
        switch (handle.surface_type) {
            .plane => {
                const p = self.planes.items[@intFromEnum(handle.index)];
                const v = math.sub(pt, p.origin);
                return .{ math.dot(v, p.u_axis), math.dot(v, p.v_axis) };
            },
            .cylinder => {
                const c = self.cylinders.items[@intFromEnum(handle.index)];
                const v = math.sub(pt, c.origin);
                const z_val = math.dot(v, c.axis);
                const proj = math.sub(v, math.scale(c.axis, z_val));
                const x_val = math.dot(proj, c.x_axis);
                const y_val = math.dot(proj, c.y_axis);
                return .{ std.math.atan2(y_val, x_val), z_val };
            },
            else => return .{ 0, 0 },
        }
    }
};
