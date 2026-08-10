const std = @import("std");
const kernel = @import("../../kernel.zig");
const geom = @import("../../geometry_handle.zig");
const manifold = @import("../../../bindings/manifold/manifold.zig");

fn cubeImpl(x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    const ptr = manifold.cube(x, y, z, center) orelse return null;
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

fn destructImpl(handle: geom.GeometryHandle) void {
    std.debug.assert(handle.engine == .manifold);
    manifold.destruct(@ptrCast(@alignCast(handle.ptr)));
}

pub const driver = kernel.GeometryKernel{
    .cubeFn = cubeImpl,
    .booleanFn = booleanImpl,
    .destructFn = destructImpl,
};
