const std = @import("std");
const geom = @import("geometry_handle.zig");

pub const BooleanOp = enum {
    union_op,
    difference_op,
    intersection_op,
};

pub const GeometryKernel = struct {
    cubeFn: *const fn (x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle,
    cylinderFn: *const fn (radius: f64, height: f64, center: bool) ?geom.GeometryHandle,
    sphereFn: *const fn (radius: f64) ?geom.GeometryHandle,
    booleanFn: *const fn (a: geom.GeometryHandle, b: geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle,
    transformFn: *const fn (a: geom.GeometryHandle, matrix: [16]f64) ?geom.GeometryHandle,
    boundingBoxFn: *const fn (handle: geom.GeometryHandle) ?geom.BoundingBox,
    queryFacesFn: *const fn (handle: geom.GeometryHandle, filter: geom.FaceFilter) ?geom.FaceArray,
    destructFn: *const fn (handle: geom.GeometryHandle) void,

    pub inline fn transform(self: *const GeometryKernel, handle: geom.GeometryHandle, matrix: [16]f64) ?geom.GeometryHandle {
        return self.transformFn(handle, matrix);
    }

    pub inline fn cube(self: *const GeometryKernel, x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
        return self.cubeFn(x, y, z, center);
    }

    pub inline fn cylinder(self: *const GeometryKernel, radius: f64, height: f64, center: bool) ?geom.GeometryHandle {
        return self.cylinderFn(radius, height, center);
    }

    pub inline fn sphere(self: *const GeometryKernel, radius: f64) ?geom.GeometryHandle {
        return self.sphereFn(radius);
    }

    pub inline fn boolean(self: *const GeometryKernel, a: geom.GeometryHandle, b: geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle {
        return self.booleanFn(a, b, op);
    }

    pub inline fn boundingBox(self: *const GeometryKernel, handle: geom.GeometryHandle) ?geom.BoundingBox {
        return self.boundingBoxFn(handle);
    }

    pub inline fn queryFaces(self: *const GeometryKernel, handle: geom.GeometryHandle, filter: geom.FaceFilter) ?geom.FaceArray {
        return self.queryFacesFn(handle, filter);
    }

    pub inline fn destruct(self: *const GeometryKernel, handle: geom.GeometryHandle) void {
        self.destructFn(handle);
    }
};
