const std = @import("std");
const geom = @import("geometry_handle.zig");
const manifold_driver = @import("engines/manifold/driver.zig").driver;
const brep_driver = @import("engines/brep/driver.zig").driver;

pub const BooleanOp = enum {
    union_op,
    difference_op,
    intersection_op,
};

// --- Comptime Kernel Dispatcher ---
fn ReturnType(comptime T: type) type {
    switch (@typeInfo(T)) {
        .pointer => |ptr| return ReturnType(ptr.child),
        .@"fn" => |func| return func.return_type.?,
        else => @compileError("Expected function or function pointer"),
    }
}

inline fn dispatch(comptime fn_name: []const u8, handle: anytype, args: anytype) ReturnType(@TypeOf(@field(manifold_driver, fn_name))) {
    switch (handle.engine) {
        .manifold => return @call(.auto, @field(manifold_driver, fn_name), .{handle} ++ args),
        .brep_native => return @call(.auto, @field(brep_driver, fn_name), .{handle} ++ args),
    }
}

// --- Dynamic Creation Dispatchers ---
pub inline fn cube(engine: geom.EngineType, x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    switch (engine) {
        .manifold => return manifold_driver.cubeFn(x, y, z, center),
        .brep_native => return brep_driver.cubeFn(x, y, z, center),
    }
}
pub inline fn cylinder(engine: geom.EngineType, r1: f64, r2: f64, height: f64, center: bool, segments: i32) ?geom.GeometryHandle {
    switch (engine) {
        .manifold => return manifold_driver.cylinderFn(r1, r2, height, center, segments),
        .brep_native => return brep_driver.cylinderFn(r1, r2, height, center, segments),
    }
}
pub inline fn sphere(engine: geom.EngineType, radius: f64) ?geom.GeometryHandle {
    switch (engine) {
        .manifold => return manifold_driver.sphereFn(radius),
        .brep_native => return brep_driver.sphereFn(radius),
    }
}
pub inline fn square(engine: geom.EngineType, x: f64, y: f64, center: bool) ?geom.CrossSectionHandle {
    switch (engine) {
        .manifold => return manifold_driver.squareFn(x, y, center),
        .brep_native => return brep_driver.squareFn(x, y, center),
    }
}
pub inline fn circle(engine: geom.EngineType, radius: f64, segments: i32) ?geom.CrossSectionHandle {
    switch (engine) {
        .manifold => return manifold_driver.circleFn(radius, segments),
        .brep_native => return brep_driver.circleFn(radius, segments),
    }
}
pub inline fn polygon(engine: geom.EngineType, allocator: std.mem.Allocator, pts: [][2]f64) ?geom.CrossSectionHandle {
    switch (engine) {
        .manifold => return manifold_driver.polygonFn(allocator, pts),
        .brep_native => return brep_driver.polygonFn(allocator, pts),
    }
}
pub inline fn polyhedron(engine: geom.EngineType, allocator: std.mem.Allocator, points: []const [3]f64, faces: []const [3]u32) ?geom.GeometryHandle {
    switch (engine) {
        .manifold => return manifold_driver.polyhedronFn(allocator, points, faces),
        .brep_native => return brep_driver.polyhedronFn(allocator, points, faces),
    }
}
pub inline fn polygonsEvenOdd(engine: geom.EngineType, allocator: std.mem.Allocator, contours: []const []const [2]f64) ?geom.CrossSectionHandle {
    switch (engine) {
        .manifold => return manifold_driver.polygonsEvenOddFn(allocator, contours),
        .brep_native => return brep_driver.polygonsEvenOddFn(allocator, contours),
    }
}

// --- Top-Level Static Dispatchers ---
pub inline fn translate(handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    return dispatch("translateFn", handle, .{ x, y, z });
}
pub inline fn rotate(handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    return dispatch("rotateFn", handle, .{ x, y, z });
}
pub inline fn scale(handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    return dispatch("scaleFn", handle, .{ x, y, z });
}
pub inline fn mirror(handle: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle {
    return dispatch("mirrorFn", handle, .{ nx, ny, nz });
}
pub inline fn transformMatrix(handle: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
    return dispatch("transformMatrixFn", handle, .{mat});
}
pub inline fn boolean(a: geom.GeometryHandle, b: geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle {
    return dispatch("booleanFn", a, .{ b, op });
}
pub inline fn setMaterial(handle: geom.GeometryHandle, material_id: u32) ?geom.GeometryHandle {
    return dispatch("setMaterialFn", handle, .{material_id});
}
pub inline fn extrude(cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
    return dispatch("extrudeFn", cs, .{ height, slices, twist_degrees, scale_x, scale_y });
}
pub inline fn revolve(cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
    return dispatch("revolveFn", cs, .{ segments, revolve_degrees });
}
pub inline fn offset(cs: geom.CrossSectionHandle, delta: f64, join_type: u8) ?geom.CrossSectionHandle {
    return dispatch("offsetFn", cs, .{ delta, join_type });
}
pub inline fn crossSectionBoolean(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: BooleanOp) ?geom.CrossSectionHandle {
    return dispatch("crossSectionBooleanFn", a, .{ b, op });
}
pub inline fn crossSectionTransform(cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
    return dispatch("crossSectionTransformFn", cs, .{mat});
}
pub inline fn hull(handle: geom.GeometryHandle) ?geom.GeometryHandle {
    return dispatch("hullFn", handle, .{});
}
pub inline fn minkowski(a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
    return dispatch("minkowskiFn", a, .{b});
}
pub inline fn trimByPlane(handle: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) ?geom.GeometryHandle {
    return dispatch("trimByPlaneFn", handle, .{ nx, ny, nz, offset_dist });
}
pub inline fn splitByPlane(handle: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) geom.SolidPair {
    return dispatch("splitByPlaneFn", handle, .{ nx, ny, nz, offset_dist });
}
pub inline fn slice(handle: geom.GeometryHandle, height: f64) ?geom.CrossSectionHandle {
    return dispatch("sliceFn", handle, .{height});
}
pub inline fn project(handle: geom.GeometryHandle) ?geom.CrossSectionHandle {
    return dispatch("projectFn", handle, .{});
}
pub inline fn genus(handle: geom.GeometryHandle) i32 {
    return dispatch("genusFn", handle, .{});
}
pub inline fn boundingBox(handle: geom.GeometryHandle) ?geom.BoundingBox {
    return dispatch("boundingBoxFn", handle, .{});
}
pub inline fn volume(handle: geom.GeometryHandle) f64 {
    return dispatch("volumeFn", handle, .{});
}
pub inline fn surfaceArea(handle: geom.GeometryHandle) f64 {
    return dispatch("surfaceAreaFn", handle, .{});
}
pub inline fn containsPoint(handle: geom.GeometryHandle, pt: [3]f64) bool {
    return dispatch("containsPointFn", handle, .{pt});
}
pub inline fn minGap(a: geom.GeometryHandle, b: geom.GeometryHandle, sl: f64) f64 {
    return dispatch("minGapFn", a, .{ b, sl });
}
pub fn destruct(handle: geom.GeometryHandle) void {
    dispatch("destructFn", handle, .{});
}
pub inline fn destructCrossSection(handle: geom.CrossSectionHandle) void {
    dispatch("destructCrossSectionFn", handle, .{});
}

pub inline fn batchBoolean(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle {
    if (objs.len == 0) return null;
    if (objs.len == 1) return objs[0];

    switch (objs[0].engine) {
        .manifold => return manifold_driver.batchBooleanFn(allocator, objs, op),
        .brep_native => return brep_driver.batchBooleanFn(allocator, objs, op),
    }
}

pub inline fn simplify(handle: geom.GeometryHandle, tolerance: f64) geom.GeometryHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.simplifyFn(handle, tolerance) orelse handle,
        .brep_native => return brep_driver.simplifyFn(handle, tolerance) orelse handle,
    }
}

pub inline fn queryFaces(allocator: std.mem.Allocator, handle: geom.GeometryHandle, direction: [3]f64, tolerance: f64) ?[]geom.FaceHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.queryFacesFn(allocator, handle, direction, tolerance),
        .brep_native => return brep_driver.queryFacesFn(allocator, handle, direction, tolerance),
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

pub const GeometryKernel = struct {
    cubeFn: *const fn (x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle,
    cylinderFn: *const fn (r1: f64, r2: f64, height: f64, center: bool, segments: i32) ?geom.GeometryHandle,
    sphereFn: *const fn (radius: f64) ?geom.GeometryHandle,
    booleanFn: *const fn (a: geom.GeometryHandle, b: geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle,
    batchBooleanFn: *const fn (allocator: std.mem.Allocator, objs: []const geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle,
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
    boundingBoxFn: *const fn (handle: geom.GeometryHandle) ?geom.BoundingBox,
    queryFacesFn: *const fn (allocator: std.mem.Allocator, handle: geom.GeometryHandle, direction: [3]f64, tolerance: f64) ?[]geom.FaceHandle,
    volumeFn: *const fn (handle: geom.GeometryHandle) f64,
    surfaceAreaFn: *const fn (handle: geom.GeometryHandle) f64,
    getMeshFn: *const fn (allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh,
    containsPointFn: *const fn (a: geom.GeometryHandle, pt: [3]f64) bool,
    minGapFn: *const fn (a: geom.GeometryHandle, b: geom.GeometryHandle, sl: f64) f64,
    rayCastFn: *const fn (allocator: std.mem.Allocator, a: geom.GeometryHandle, origin: [3]f64, end: [3]f64) ?[]geom.RayHit,
    simplifyFn: *const fn (a: geom.GeometryHandle, tolerance: f64) ?geom.GeometryHandle,
    destructFn: *const fn (handle: geom.GeometryHandle) void,
    destructCrossSectionFn: *const fn (handle: geom.CrossSectionHandle) void,
};
