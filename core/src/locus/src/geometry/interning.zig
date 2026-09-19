const std = @import("std");
const math = @import("../math.zig");
const math_env = @import("../math_env.zig");
const geom_types = @import("types.zig");
const geom_arena = @import("arena.zig");

pub const Interner = struct {
    /// Deduplicates 3D Point coordinates using spatial proximity checks.
    pub fn getOrInsertPoint(
        allocator: std.mem.Allocator,
        g: *geom_arena.GeometryArena,
        pt: math.Vec3,
        env: math_env.MathEnv,
    ) !geom_types.PointIndex {
        // Fast Linear Scan (Sufficient for localized primitive buffers)
        for (g.points.items, 0..) |existing, idx| {
            if (env.isCoincident(existing, pt)) {
                return @enumFromInt(@as(u32, @intCast(idx)));
            }
        }
        const new_idx = @as(geom_types.PointIndex, @enumFromInt(@as(u32, @intCast(g.points.items.len))));
        try g.points.append(allocator, pt);
        return new_idx;
    }

    /// Deduplicates 3D Line segments within tolerance.
    pub fn getOrInsertLine(
        allocator: std.mem.Allocator,
        g: *geom_arena.GeometryArena,
        line: geom_types.Line,
        env: math_env.MathEnv,
    ) !geom_types.CurveIndex {
        for (g.lines.items, 0..) |existing, idx| {
            if (env.isCoincident(existing.start, line.start) and env.isCoincident(existing.end, line.end)) {
                return @enumFromInt(@as(u24, @intCast(idx)));
            }
        }
        const new_idx = @as(geom_types.CurveIndex, @enumFromInt(@as(u24, @intCast(g.lines.items.len))));
        try g.lines.append(allocator, line);
        return new_idx;
    }

    /// Deduplicates 3D Planes within origin & angular tolerance.
    pub fn getOrInsertPlane(
        allocator: std.mem.Allocator,
        g: *geom_arena.GeometryArena,
        plane: geom_types.Plane,
        env: math_env.MathEnv,
    ) !geom_types.SurfaceIndex {
        for (g.planes.items, 0..) |existing, idx| {
            if (env.isCoincident(existing.origin, plane.origin) and
                env.isParallel(existing.u_axis, plane.u_axis) and
                env.isParallel(existing.v_axis, plane.v_axis))
            {
                return @enumFromInt(@as(u24, @intCast(idx)));
            }
        }
        const new_idx = @as(geom_types.SurfaceIndex, @enumFromInt(@as(u24, @intCast(g.planes.items.len))));
        try g.planes.append(allocator, plane);
        return new_idx;
    }
};
