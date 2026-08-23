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
fn polyhedronImpl(allocator: std.mem.Allocator, pts: []const [3]f64, faces: []const [3]u32) ?geom.GeometryHandle {
    _ = allocator;
    _ = pts;
    _ = faces;
    return null;
}
fn polygonsEvenOddImpl(allocator: std.mem.Allocator, contours: []const []const [2]f64) ?geom.CrossSectionHandle {
    _ = allocator;
    _ = contours;
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
fn crossSectionBooleanImpl(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: kernel.BooleanOp) ?geom.CrossSectionHandle {
    _ = a;
    _ = b;
    _ = op;
    return null;
}
fn transformMatrixImpl(a: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
    _ = a;
    _ = mat;
    return null;
}
fn crossSectionTransformImpl(cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
    _ = cs;
    _ = mat;
    return null;
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
fn containsPointImpl(a: geom.GeometryHandle, pt: [3]f64) bool {
    _ = a;
    _ = pt;
    return false;
}
fn minGapImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, sl: f64) f64 {
    _ = a;
    _ = b;
    _ = sl;
    return 0.0;
}
fn minkowskiImpl(a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
    _ = a;
    _ = b;
    return null;
}
fn offsetImpl(cs: geom.CrossSectionHandle, delta: f64, join_type: u8) ?geom.CrossSectionHandle {
    _ = cs;
    _ = delta;
    _ = join_type;
    return null;
}
fn rayCastImpl(alloc: std.mem.Allocator, a: geom.GeometryHandle, o: [3]f64, e: [3]f64) ?[]geom.RayHit {
    _ = alloc;
    _ = a;
    _ = o;
    _ = e;
    return null;
}
fn polygonImpl(allocator: std.mem.Allocator, pts: [][2]f64) ?geom.CrossSectionHandle {
    _ = allocator;
    _ = pts;
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
    .polyhedronFn = polyhedronImpl,
    .polygonsEvenOddFn = polygonsEvenOddImpl,
    .extrudeFn = extrudeImpl,
    .revolveFn = revolveImpl,
    .sliceFn = sliceImpl,
    .projectFn = projectImpl,
    .mirrorFn = mirrorImpl,
    .hullFn = hullImpl,
    .trimByPlaneFn = trimByPlaneImpl,
    .splitByPlaneFn = splitByPlaneImpl,
    .crossSectionBooleanFn = crossSectionBooleanImpl,
    .genusFn = genusImpl,
    .transformMatrixFn = transformMatrixImpl,
    .minkowskiFn = minkowskiImpl,
    .offsetFn = offsetImpl,
    .crossSectionTransformFn = crossSectionTransformImpl,

    .boundingBoxFn = boundingBoxImpl,
    .queryFacesFn = queryFacesImpl,
    .volumeFn = volumeImpl,
    .surfaceAreaFn = surfaceAreaImpl,
    .getMeshFn = getMeshImpl,
    .containsPointFn = containsPointImpl,
    .minGapFn = minGapImpl,
    .rayCastFn = rayCastImpl,
    .polygonFn = polygonImpl,

    .destructFn = destructImpl,
    .destructCrossSectionFn = destructCrossSectionImpl,
};
