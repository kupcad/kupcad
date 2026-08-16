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
    translateFn: *const fn (a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle,
    rotateFn: *const fn (a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle,
    scaleFn: *const fn (a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle,
    transformMatrixFn: *const fn (a: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle,
    squareFn: *const fn (x: f64, y: f64, center: bool) ?geom.CrossSectionHandle,
    circleFn: *const fn (radius: f64, circular_segments: i32) ?geom.CrossSectionHandle,
    offsetFn: *const fn (cs: geom.CrossSectionHandle, delta: f64, join_type: u8) ?geom.CrossSectionHandle,
    crossSectionTransformFn: *const fn (cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle,
    extrudeFn: *const fn (cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle,
    revolveFn: *const fn (cs: geom.CrossSectionHandle, circular_segments: i32, revolve_degrees: f64) ?geom.GeometryHandle,
    sliceFn: *const fn (a: geom.GeometryHandle, height: f64) ?geom.CrossSectionHandle,
    projectFn: *const fn (a: geom.GeometryHandle) ?geom.CrossSectionHandle,
    mirrorFn: *const fn (a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle,
    hullFn: *const fn (a: geom.GeometryHandle) ?geom.GeometryHandle,
    minkowskiFn: *const fn (a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle,
    trimByPlaneFn: *const fn (a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) ?geom.GeometryHandle,
    splitByPlaneFn: *const fn (a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) geom.SolidPair,
    crossSectionBooleanFn: *const fn (a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: BooleanOp) ?geom.CrossSectionHandle,
    genusFn: *const fn (a: geom.GeometryHandle) i32,
    destructCrossSectionFn: *const fn (handle: geom.CrossSectionHandle) void,
    boundingBoxFn: *const fn (handle: geom.GeometryHandle) ?geom.BoundingBox,
    queryFacesFn: *const fn (handle: geom.GeometryHandle, filter: geom.FaceFilter) ?geom.FaceArray,
    volumeFn: *const fn (handle: geom.GeometryHandle) f64,
    surfaceAreaFn: *const fn (handle: geom.GeometryHandle) f64,
    getMeshFn: *const fn (allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh,
    destructFn: *const fn (handle: geom.GeometryHandle) void,

    pub inline fn translate(self: *const GeometryKernel, handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
        return self.translateFn(handle, x, y, z);
    }
    pub inline fn rotate(self: *const GeometryKernel, handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
        return self.rotateFn(handle, x, y, z);
    }
    pub inline fn scale(self: *const GeometryKernel, handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
        return self.scaleFn(handle, x, y, z);
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

    // Inline wrappers for Phase 2
    pub inline fn square(self: *const GeometryKernel, x: f64, y: f64, center: bool) ?geom.CrossSectionHandle {
        return self.squareFn(x, y, center);
    }
    pub inline fn circle(self: *const GeometryKernel, radius: f64, segments: i32) ?geom.CrossSectionHandle {
        return self.circleFn(radius, segments);
    }
    pub inline fn extrude(self: *const GeometryKernel, cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
        return self.extrudeFn(cs, height, slices, twist_degrees, scale_x, scale_y);
    }
    pub inline fn revolve(self: *const GeometryKernel, cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
        return self.revolveFn(cs, segments, revolve_degrees);
    }
    pub inline fn slice(self: *const GeometryKernel, a: geom.GeometryHandle, height: f64) ?geom.CrossSectionHandle {
        return self.sliceFn(a, height);
    }
    pub inline fn project(self: *const GeometryKernel, a: geom.GeometryHandle) ?geom.CrossSectionHandle {
        return self.projectFn(a);
    }
    pub inline fn mirror(self: *const GeometryKernel, a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle {
        return self.mirrorFn(a, nx, ny, nz);
    }

    pub inline fn hull(self: *const GeometryKernel, a: geom.GeometryHandle) ?geom.GeometryHandle {
        return self.hullFn(a);
    }

    pub inline fn minkowski(self: *const GeometryKernel, a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
        return self.minkowskiFn(a, b);
    }

    pub inline fn trimByPlane(self: *const GeometryKernel, a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) ?geom.GeometryHandle {
        return self.trimByPlaneFn(a, nx, ny, nz, offset_dist);
    }

    pub inline fn splitByPlane(self: *const GeometryKernel, a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) geom.SolidPair {
        return self.splitByPlaneFn(a, nx, ny, nz, offset_dist);
    }

    pub inline fn offset(self: *const GeometryKernel, cs: geom.CrossSectionHandle, delta: f64, join_type: u8) ?geom.CrossSectionHandle {
        return self.offsetFn(cs, delta, join_type);
    }

    pub inline fn crossSectionBoolean(self: *const GeometryKernel, a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: BooleanOp) ?geom.CrossSectionHandle {
        return self.crossSectionBooleanFn(a, b, op);
    }

    pub inline fn transformMatrix(self: *const GeometryKernel, handle: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
        return self.transformMatrixFn(handle, mat);
    }

    pub inline fn crossSectionTransform(self: *const GeometryKernel, cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
        return self.crossSectionTransformFn(cs, mat);
    }

    pub inline fn genus(self: *const GeometryKernel, a: geom.GeometryHandle) i32 {
        return self.genusFn(a);
    }

    pub inline fn boundingBox(self: *const GeometryKernel, handle: geom.GeometryHandle) ?geom.BoundingBox {
        return self.boundingBoxFn(handle);
    }

    pub inline fn queryFaces(self: *const GeometryKernel, handle: geom.GeometryHandle, filter: geom.FaceFilter) ?geom.FaceArray {
        return self.queryFacesFn(handle, filter);
    }
    pub inline fn volume(self: *const GeometryKernel, handle: geom.GeometryHandle) f64 {
        return self.volumeFn(handle);
    }
    pub inline fn surfaceArea(self: *const GeometryKernel, handle: geom.GeometryHandle) f64 {
        return self.surfaceAreaFn(handle);
    }
    pub inline fn getMesh(self: *const GeometryKernel, allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh {
        return self.getMeshFn(allocator, handle);
    }
    pub inline fn destruct(self: *const GeometryKernel, handle: geom.GeometryHandle) void {
        self.destructFn(handle);
    }
    pub inline fn destructCrossSection(self: *const GeometryKernel, handle: geom.CrossSectionHandle) void {
        self.destructCrossSectionFn(handle);
    }
};
