const std = @import("std");
const kernel = @import("../../kernel.zig");
const manifold = @import("../../../bindings/manifold/manifold.zig");

fn cubeImpl(x: f64, y: f64, z: f64, center: bool) ?*anyopaque {
    return @ptrCast(manifold.cube(x, y, z, center));
}

fn booleanImpl(a: ?*anyopaque, b: ?*anyopaque, op: kernel.BooleanOp) ?*anyopaque {
    const m1: *manifold.ManifoldObj = @ptrCast(@alignCast(a));
    const m2: *manifold.ManifoldObj = @ptrCast(@alignCast(b));

    const m_op = switch (op) {
        .union_op => manifold.OpType.add,
        .difference_op => manifold.OpType.subtract,
        .intersection_op => manifold.OpType.intersect,
    };

    return @ptrCast(manifold.boolean(m1, m2, m_op));
}

fn destructImpl(handle: ?*anyopaque) void {
    if (handle) |h| {
        manifold.destruct(@ptrCast(@alignCast(h)));
    }
}

pub const driver = kernel.GeometryKernel{
    .cubeFn = cubeImpl,
    .booleanFn = booleanImpl,
    .destructFn = destructImpl,
};
