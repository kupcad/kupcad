const std = @import("std");
const kernel = @import("../../kernel.zig");
const geom = @import("../../geometry_handle.zig");

fn cubeImpl(x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    _ = x;
    _ = y;
    _ = z;
    _ = center;
    return null;
}
fn cylinderImpl(radius: f64, height: f64, center: bool) ?geom.GeometryHandle {
    _ = radius;
    _ = height;
    _ = center;
    return null;
}
fn sphereImpl(radius: f64) ?geom.GeometryHandle {
    _ = radius;
    return null;
}
fn booleanImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    _ = a;
    _ = b;
    _ = op;
    return null;
}
fn translateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    _ = a;
    _ = x;
    _ = y;
    _ = z;
    return null;
}
fn rotateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    _ = a;
    _ = x;
    _ = y;
    _ = z;
    return null;
}
fn scaleImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    _ = a;
    _ = x;
    _ = y;
    _ = z;
    return null;
}
fn squareImpl(x: f64, y: f64, center: bool) ?geom.CrossSectionHandle {
    _ = x;
    _ = y;
    _ = center;
    return null;
}
fn circleImpl(radius: f64, segments: i32) ?geom.CrossSectionHandle {
    _ = radius;
    _ = segments;
    return null;
}
fn extrudeImpl(cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
    _ = cs;
    _ = height;
    _ = slices;
    _ = twist_degrees;
    _ = scale_x;
    _ = scale_y;
    return null;
}
fn revolveImpl(cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
    _ = cs;
    _ = segments;
    _ = revolve_degrees;
    return null;
}
fn sliceImpl(a: geom.GeometryHandle, height: f64) ?geom.CrossSectionHandle {
    _ = a;
    _ = height;
    return null;
}
fn projectImpl(a: geom.GeometryHandle) ?geom.CrossSectionHandle {
    _ = a;
    return null;
}
fn mirrorImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle {
    _ = a;
    _ = nx;
    _ = ny;
    _ = nz;
    return null;
}
fn hullImpl(a: geom.GeometryHandle) ?geom.GeometryHandle {
    _ = a;
    return null;
}
fn trimByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset: f64) ?geom.GeometryHandle {
    _ = a;
    _ = nx;
    _ = ny;
    _ = nz;
    _ = offset;
    return null;
}
fn splitByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset: f64) geom.SolidPair {
    _ = a;
    _ = nx;
    _ = ny;
    _ = nz;
    _ = offset;
    return .{ .first = null, .second = null };
}
fn genusImpl(handle: geom.GeometryHandle) i32 {
    _ = handle;
    return 0;
}
fn boundingBoxImpl(handle: geom.GeometryHandle) ?geom.BoundingBox {
    _ = handle;
    return null;
}
fn queryFacesImpl(handle: geom.GeometryHandle, filter: geom.FaceFilter) ?geom.FaceArray {
    _ = handle;
    _ = filter;
    return null;
}
fn volumeImpl(handle: geom.GeometryHandle) f64 {
    _ = handle;
    return 0.0;
}
fn surfaceAreaImpl(handle: geom.GeometryHandle) f64 {
    _ = handle;
    return 0.0;
}
fn getMeshImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh {
    _ = allocator;
    _ = handle;
    return null;
}
fn destructImpl(handle: geom.GeometryHandle) void {
    _ = handle;
}
fn destructCrossSectionImpl(handle: geom.CrossSectionHandle) void {
    _ = handle;
}

pub const driver = kernel.GeometryKernel{
    .cubeFn = cubeImpl,
    .cylinderFn = cylinderImpl,
    .sphereFn = sphereImpl,
    .booleanFn = booleanImpl,
    .translateFn = translateImpl,
    .rotateFn = rotateImpl,
    .scaleFn = scaleImpl,

    .squareFn = squareImpl,
    .circleFn = circleImpl,
    .extrudeFn = extrudeImpl,
    .revolveFn = revolveImpl,
    .sliceFn = sliceImpl,
    .projectFn = projectImpl,
    .mirrorFn = mirrorImpl,
    .hullFn = hullImpl,
    .trimByPlaneFn = trimByPlaneImpl,
    .splitByPlaneFn = splitByPlaneImpl,
    .genusFn = genusImpl,

    .boundingBoxFn = boundingBoxImpl,
    .queryFacesFn = queryFacesImpl,
    .volumeFn = volumeImpl,
    .surfaceAreaFn = surfaceAreaImpl,
    .getMeshFn = getMeshImpl,
    .destructFn = destructImpl,
    .destructCrossSectionFn = destructCrossSectionImpl,
};
