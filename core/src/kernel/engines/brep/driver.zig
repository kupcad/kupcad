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

fn booleanImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    _ = a;
    _ = b;
    _ = op;
    std.debug.assert(a.engine == .brep_native and b.engine == .brep_native);
    std.log.info("Native B-Rep Driver: Executing topological Boolean...", .{});
    return null;
}

fn transformImpl(a: geom.GeometryHandle, matrix: [16]f64) ?geom.GeometryHandle {
    _ = a;
    _ = matrix;
    return null;
}

fn destructImpl(handle: geom.GeometryHandle) void {
    std.debug.assert(handle.engine == .brep_native);
    _ = handle;
}

fn boundingBoxImpl(handle: geom.GeometryHandle) ?geom.BoundingBox {
    std.debug.assert(handle.engine == .brep_native);
    return null;
}

fn queryFacesImpl(handle: geom.GeometryHandle, filter: geom.FaceFilter) ?geom.FaceArray {
    std.debug.assert(handle.engine == .brep_native);
    _ = filter;
    return null;
}

pub const driver = kernel.GeometryKernel{
    .cubeFn = cubeImpl,
    .booleanFn = booleanImpl,
    .transformFn = transformImpl,
    .boundingBoxFn = boundingBoxImpl,
    .queryFacesFn = queryFacesImpl,
    .destructFn = destructImpl,
};
