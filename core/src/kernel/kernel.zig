const std = @import("std");
const geom = @import("geometry_handle.zig");

const manifold_driver = @import("engines/manifold/driver.zig").driver;
const brep_driver = @import("engines/brep/driver.zig").driver;

pub const BooleanOp = enum {
    union_op,
    difference_op,
    intersection_op,
};

// --- Creation Dispatchers (Default to Manifold for interactive VM evaluation) ---
pub inline fn cube(x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    return manifold_driver.cubeFn(x, y, z, center);
}
pub inline fn cylinder(r1: f64, r2: f64, height: f64, center: bool, segments: i32) ?geom.GeometryHandle {
    return manifold_driver.cylinderFn(r1, r2, height, center, segments);
}
pub inline fn sphere(radius: f64) ?geom.GeometryHandle {
    return manifold_driver.sphereFn(radius);
}
pub inline fn square(x: f64, y: f64, center: bool) ?geom.CrossSectionHandle {
    return manifold_driver.squareFn(x, y, center);
}
pub inline fn circle(radius: f64, segments: i32) ?geom.CrossSectionHandle {
    return manifold_driver.circleFn(radius, segments);
}
pub inline fn polygon(allocator: std.mem.Allocator, pts: [][2]f64) ?geom.CrossSectionHandle {
    return manifold_driver.polygonFn(allocator, pts);
}
pub inline fn polyhedron(allocator: std.mem.Allocator, points: []const [3]f64, faces: []const [3]u32) ?geom.GeometryHandle {
    return manifold_driver.polyhedronFn(allocator, points, faces);
}
pub inline fn polygonsEvenOdd(allocator: std.mem.Allocator, contours: []const []const [2]f64) ?geom.CrossSectionHandle {
    return manifold_driver.polygonsEvenOddFn(allocator, contours);
}

// --- Top-Level Static Dispatchers ---
pub inline fn translate(handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.translateFn(handle, x, y, z),
        .brep_native => return brep_driver.translateFn(handle, x, y, z),
    }
}
pub inline fn rotate(handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.rotateFn(handle, x, y, z),
        .brep_native => return brep_driver.rotateFn(handle, x, y, z),
    }
}
pub inline fn scale(handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.scaleFn(handle, x, y, z),
        .brep_native => return brep_driver.scaleFn(handle, x, y, z),
    }
}
pub inline fn mirror(handle: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.mirrorFn(handle, nx, ny, nz),
        .brep_native => return brep_driver.mirrorFn(handle, nx, ny, nz),
    }
}
pub inline fn transformMatrix(handle: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.transformMatrixFn(handle, mat),
        .brep_native => return brep_driver.transformMatrixFn(handle, mat),
    }
}
pub inline fn boolean(a: geom.GeometryHandle, b: geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle {
    switch (a.engine) {
        .manifold => return manifold_driver.booleanFn(a, b, op),
        .brep_native => return brep_driver.booleanFn(a, b, op),
    }
}
pub inline fn setMaterial(handle: geom.GeometryHandle, material_id: u32) ?geom.GeometryHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.setMaterialFn(handle, material_id),
        .brep_native => return brep_driver.setMaterialFn(handle, material_id),
    }
}

pub inline fn extrude(cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
    switch (cs.engine) {
        .manifold => return manifold_driver.extrudeFn(cs, height, slices, twist_degrees, scale_x, scale_y),
        .brep_native => return brep_driver.extrudeFn(cs, height, slices, twist_degrees, scale_x, scale_y),
    }
}

pub inline fn revolve(cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
    switch (cs.engine) {
        .manifold => return manifold_driver.revolveFn(cs, segments, revolve_degrees),
        .brep_native => return brep_driver.revolveFn(cs, segments, revolve_degrees),
    }
}

pub inline fn offset(cs: geom.CrossSectionHandle, delta: f64, join_type: u8) ?geom.CrossSectionHandle {
    switch (cs.engine) {
        .manifold => return manifold_driver.offsetFn(cs, delta, join_type),
        .brep_native => return brep_driver.offsetFn(cs, delta, join_type),
    }
}
pub inline fn crossSectionBoolean(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: BooleanOp) ?geom.CrossSectionHandle {
    switch (a.engine) {
        .manifold => return manifold_driver.crossSectionBooleanFn(a, b, op),
        .brep_native => return brep_driver.crossSectionBooleanFn(a, b, op),
    }
}
pub inline fn crossSectionTransform(cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
    switch (cs.engine) {
        .manifold => return manifold_driver.crossSectionTransformFn(cs, mat),
        .brep_native => return brep_driver.crossSectionTransformFn(cs, mat),
    }
}
pub inline fn hull(handle: geom.GeometryHandle) ?geom.GeometryHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.hullFn(handle),
        .brep_native => return brep_driver.hullFn(handle),
    }
}
pub inline fn minkowski(a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
    switch (a.engine) {
        .manifold => return manifold_driver.minkowskiFn(a, b),
        .brep_native => return brep_driver.minkowskiFn(a, b),
    }
}
pub inline fn trimByPlane(handle: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) ?geom.GeometryHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.trimByPlaneFn(handle, nx, ny, nz, offset_dist),
        .brep_native => return brep_driver.trimByPlaneFn(handle, nx, ny, nz, offset_dist),
    }
}
pub inline fn splitByPlane(handle: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) geom.SolidPair {
    switch (handle.engine) {
        .manifold => return manifold_driver.splitByPlaneFn(handle, nx, ny, nz, offset_dist),
        .brep_native => return brep_driver.splitByPlaneFn(handle, nx, ny, nz, offset_dist),
    }
}
pub inline fn slice(handle: geom.GeometryHandle, height: f64) ?geom.CrossSectionHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.sliceFn(handle, height),
        .brep_native => return brep_driver.sliceFn(handle, height),
    }
}
pub inline fn project(handle: geom.GeometryHandle) ?geom.CrossSectionHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.projectFn(handle),
        .brep_native => return brep_driver.projectFn(handle),
    }
}
pub inline fn genus(handle: geom.GeometryHandle) i32 {
    switch (handle.engine) {
        .manifold => return manifold_driver.genusFn(handle),
        .brep_native => return brep_driver.genusFn(handle),
    }
}
pub inline fn boundingBox(handle: geom.GeometryHandle) ?geom.BoundingBox {
    switch (handle.engine) {
        .manifold => return manifold_driver.boundingBoxFn(handle),
        .brep_native => return brep_driver.boundingBoxFn(handle),
    }
}
pub inline fn volume(handle: geom.GeometryHandle) f64 {
    std.debug.assert(@intFromPtr(handle.ptr) != 0);

    switch (handle.engine) {
        .manifold => return manifold_driver.volumeFn(handle),
        .brep_native => return brep_driver.volumeFn(handle),
    }
}
pub inline fn surfaceArea(handle: geom.GeometryHandle) f64 {
    switch (handle.engine) {
        .manifold => return manifold_driver.surfaceAreaFn(handle),
        .brep_native => return brep_driver.surfaceAreaFn(handle),
    }
}
pub inline fn queryFaces(handle: geom.GeometryHandle, filter: geom.FaceFilter) ?geom.FaceArray {
    switch (handle.engine) {
        .manifold => return manifold_driver.queryFacesFn(handle, filter),
        .brep_native => return brep_driver.queryFacesFn(handle, filter),
    }
}
pub inline fn containsPoint(handle: geom.GeometryHandle, pt: [3]f64) bool {
    switch (handle.engine) {
        .manifold => return manifold_driver.containsPointFn(handle, pt),
        .brep_native => return brep_driver.containsPointFn(handle, pt),
    }
}
pub inline fn minGap(a: geom.GeometryHandle, b: geom.GeometryHandle, sl: f64) f64 {
    switch (a.engine) {
        .manifold => return manifold_driver.minGapFn(a, b, sl),
        .brep_native => return brep_driver.minGapFn(a, b, sl),
    }
}
pub inline fn rayCast(alloc: std.mem.Allocator, handle: geom.GeometryHandle, o: [3]f64, e: [3]f64) ?[]geom.RayHit {
    switch (handle.engine) {
        .manifold => return manifold_driver.rayCastFn(alloc, handle, o, e),
        .brep_native => return brep_driver.rayCastFn(alloc, handle, o, e),
    }
}
pub inline fn getMesh(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh {
    switch (handle.engine) {
        .manifold => return manifold_driver.getMeshFn(allocator, handle),
        .brep_native => return brep_driver.getMeshFn(allocator, handle),
    }
}
pub fn destruct(handle: geom.GeometryHandle) void {
    switch (handle.engine) {
        .manifold => manifold_driver.destructFn(handle),
        .brep_native => brep_driver.destructFn(handle),
    }
}
pub inline fn destructCrossSection(handle: geom.CrossSectionHandle) void {
    switch (handle.engine) {
        .manifold => manifold_driver.destructCrossSectionFn(handle),
        .brep_native => brep_driver.destructCrossSectionFn(handle),
    }
}

// Keep the internal v-table struct definition intact for the drivers
pub const GeometryKernel = struct {
    cubeFn: *const fn (x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle,
    cylinderFn: *const fn (r1: f64, r2: f64, height: f64, center: bool, segments: i32) ?geom.GeometryHandle,
    sphereFn: *const fn (radius: f64) ?geom.GeometryHandle,
    booleanFn: *const fn (a: geom.GeometryHandle, b: geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle,
    translateFn: *const fn (a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle,
    rotateFn: *const fn (a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle,
    scaleFn: *const fn (a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle,
    transformMatrixFn: *const fn (a: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle,
    squareFn: *const fn (x: f64, y: f64, center: bool) ?geom.CrossSectionHandle,
    circleFn: *const fn (radius: f64, circular_segments: i32) ?geom.CrossSectionHandle,
    polyhedronFn: *const fn (allocator: std.mem.Allocator, points: []const [3]f64, faces: []const [3]u32) ?geom.GeometryHandle,
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
    polygonsEvenOddFn: *const fn (allocator: std.mem.Allocator, contours: []const []const [2]f64) ?geom.CrossSectionHandle,
    setMaterialFn: *const fn (a: geom.GeometryHandle, material_id: u32) ?geom.GeometryHandle,
    genusFn: *const fn (a: geom.GeometryHandle) i32,
    polygonFn: *const fn (allocator: std.mem.Allocator, pts: [][2]f64) ?geom.CrossSectionHandle,
    destructCrossSectionFn: *const fn (handle: geom.CrossSectionHandle) void,
    boundingBoxFn: *const fn (handle: geom.GeometryHandle) ?geom.BoundingBox,
    queryFacesFn: *const fn (handle: geom.GeometryHandle, filter: geom.FaceFilter) ?geom.FaceArray,
    volumeFn: *const fn (handle: geom.GeometryHandle) f64,
    surfaceAreaFn: *const fn (handle: geom.GeometryHandle) f64,
    getMeshFn: *const fn (allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh,
    containsPointFn: *const fn (a: geom.GeometryHandle, pt: [3]f64) bool,
    minGapFn: *const fn (a: geom.GeometryHandle, b: geom.GeometryHandle, search_length: f64) f64,
    rayCastFn: *const fn (allocator: std.mem.Allocator, a: geom.GeometryHandle, origin: [3]f64, end: [3]f64) ?[]geom.RayHit,
    destructFn: *const fn (handle: geom.GeometryHandle) void,
};
