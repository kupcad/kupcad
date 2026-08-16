const std = @import("std");
const kernel = @import("../../kernel.zig");
const geom = @import("../../geometry_handle.zig");
const topology = @import("topology.zig");

fn cubeImpl(x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    _ = x;
    _ = y;
    _ = z;
    _ = center;
    std.log.info("Native B-Rep Driver: Constructing exact topological Cube...", .{});
    return null;
}

fn cylinderImpl(radius: f64, height: f64, center: bool) ?geom.GeometryHandle {
    _ = radius;
    _ = height;
    _ = center;
    std.log.info("Native B-Rep Driver: Constructing exact topological Cylinder...", .{});
    return null;
}

fn sphereImpl(radius: f64) ?geom.GeometryHandle {
    _ = radius;
    std.log.info("Native B-Rep Driver: Constructing exact topological Sphere...", .{});
    return null;
}

fn booleanImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    _ = a;
    _ = b;
    _ = op;
    std.debug.assert(a.engine == .brep_native and b.engine == .brep_native);
    std.log.info("Native B-Rep Driver: Executing topological Boolean...", .{});
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

fn boundingBoxImpl(handle: geom.GeometryHandle) ?geom.BoundingBox {
    std.debug.assert(handle.engine == .brep_native);
    _ = handle;
    return null;
}

fn queryFacesImpl(handle: geom.GeometryHandle, filter: geom.FaceFilter) ?geom.FaceArray {
    std.debug.assert(handle.engine == .brep_native);
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
    std.debug.assert(handle.engine == .brep_native);
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

    .getMeshFn = getMeshImpl,

    .boundingBoxFn = boundingBoxImpl,
    .queryFacesFn = queryFacesImpl,
    .volumeFn = volumeImpl,
    .surfaceAreaFn = surfaceAreaImpl,
    .destructFn = destructImpl,
};
