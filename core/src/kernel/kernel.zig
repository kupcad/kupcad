const std = @import("std");
const geom = @import("geometry_handle.zig");

pub const BooleanOp = enum {
    union_op,
    difference_op,
    intersection_op,
};

pub const GeometryKernel = struct {
    cubeFn: *const fn (x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle,
    booleanFn: *const fn (a: geom.GeometryHandle, b: geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle,
    transformFn: *const fn (a: geom.GeometryHandle, matrix: [16]f64) ?geom.GeometryHandle,
    destructFn: *const fn (handle: geom.GeometryHandle) void,

    pub inline fn cube(self: *const GeometryKernel, x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
        return self.cubeFn(x, y, z, center);
    }

    pub inline fn boolean(self: *const GeometryKernel, a: geom.GeometryHandle, b: geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle {
        return self.booleanFn(a, b, op);
    }

    pub inline fn destruct(self: *const GeometryKernel, handle: geom.GeometryHandle) void {
        self.destructFn(handle);
    }
};
