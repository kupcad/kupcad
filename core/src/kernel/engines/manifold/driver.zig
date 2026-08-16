const std = @import("std");
const kernel = @import("../../kernel.zig");
const geom = @import("../../geometry_handle.zig");
const manifold = @import("../../../bindings/manifold/manifold.zig");

fn cubeImpl(x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    const ptr = manifold.cube(x, y, z, center) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn cylinderImpl(radius: f64, height: f64, center: bool) ?geom.GeometryHandle {
    const ptr = manifold.cylinder(radius, height, center) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn sphereImpl(radius: f64) ?geom.GeometryHandle {
    const ptr = manifold.sphere(radius) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn booleanImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold and b.engine == .manifold);
    const m1: *manifold.ManifoldObj = @ptrCast(@alignCast(a.ptr));
    const m2: *manifold.ManifoldObj = @ptrCast(@alignCast(b.ptr));
    const m_op = switch (op) {
        .union_op => manifold.OpType.add,
        .difference_op => manifold.OpType.subtract,
        .intersection_op => manifold.OpType.intersect,
    };
    const ptr = manifold.boolean(m1, m2, m_op) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn transformImpl(a: geom.GeometryHandle, matrix: [16]f64) ?geom.GeometryHandle {
    _ = a;
    _ = matrix;
    // TODO: Manifold transform implementation
    return null;
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

fn destructImpl(handle: geom.GeometryHandle) void {
    std.debug.assert(handle.engine == .manifold);
    manifold.destruct(@ptrCast(@alignCast(handle.ptr)));
}

pub const driver = kernel.GeometryKernel{
    .cubeFn = cubeImpl,
    .cylinderFn = cylinderImpl,
    .sphereFn = sphereImpl,
    .booleanFn = booleanImpl,
    .transformFn = transformImpl,
    .boundingBoxFn = boundingBoxImpl,
    .queryFacesFn = queryFacesImpl,
    .destructFn = destructImpl,
};
