const std = @import("std");

/// Opaque pointer to the C++ Manifold object
pub const ManifoldObj = opaque {};

pub const OpType = enum(c_int) {
    add = 0,
    subtract = 1,
    intersect = 2,
};

// --- Mock FFI Bindings ---
// (In production, replace the bodies with `extern "C"` declarations)

pub fn cube(x: f32, y: f32, z: f32, center: bool) *ManifoldObj {
    _ = x;
    _ = y;
    _ = z;
    _ = center;
    // Return a dummy pointer for testing
    return @ptrFromInt(0xDEADBEEF);
}

pub fn boolean(a: *ManifoldObj, b: *ManifoldObj, op: OpType) *ManifoldObj {
    _ = a;
    _ = b;
    _ = op;
    // Return a dummy pointer for testing
    return @ptrFromInt(0xCAFEF00D);
}

pub fn destruct(m: *ManifoldObj) void {
    _ = m;
}
