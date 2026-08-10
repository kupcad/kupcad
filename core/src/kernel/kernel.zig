const std = @import("std");

pub const BooleanOp = enum {
    union_op,
    difference_op,
    intersection_op,
};

/// The GeometryKernel interface uses a Data-Oriented VTable approach.
/// It passes opaque handles (`?*anyopaque`) so it works flawlessly with
/// C-pointers from Manifold (C++) and B-REp
pub const GeometryKernel = struct {
    cubeFn: *const fn (x: f64, y: f64, z: f64, center: bool) ?*anyopaque,
    booleanFn: *const fn (a: ?*anyopaque, b: ?*anyopaque, op: BooleanOp) ?*anyopaque,
    destructFn: *const fn (handle: ?*anyopaque) void,

    pub inline fn cube(self: *const GeometryKernel, x: f64, y: f64, z: f64, center: bool) ?*anyopaque {
        return self.cubeFn(x, y, z, center);
    }

    pub inline fn boolean(self: *const GeometryKernel, a: ?*anyopaque, b: ?*anyopaque, op: BooleanOp) ?*anyopaque {
        return self.booleanFn(a, b, op);
    }

    pub inline fn destruct(self: *const GeometryKernel, handle: ?*anyopaque) void {
        self.destructFn(handle);
    }
};
