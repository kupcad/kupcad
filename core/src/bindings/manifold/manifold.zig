const std = @import("std");

pub const ManifoldObj = opaque {};

pub const OpType = enum(c_int) {
    add = 0,
    subtract = 1,
    intersect = 2,
};

// --- Real FFI Bindings ---
extern "C" fn manifold_alloc_manifold() ?*ManifoldObj;
extern "C" fn manifold_cube(mem: ?*ManifoldObj, x: f64, y: f64, z: f64, center: c_int) ?*ManifoldObj;
extern "C" fn manifold_cylinder(mem: ?*ManifoldObj, radius: f64, height: f64, center: c_int) ?*ManifoldObj;
extern "C" fn manifold_sphere(mem: ?*ManifoldObj, radius: f64) ?*ManifoldObj;
extern "C" fn manifold_boolean(mem: ?*ManifoldObj, a: ?*ManifoldObj, b: ?*ManifoldObj, op: OpType) ?*ManifoldObj;
extern "C" fn manifold_transform(mem: ?*ManifoldObj, obj: ?*ManifoldObj, matrix: *const [16]f64) ?*ManifoldObj;
extern "C" fn manifold_delete_manifold(m: ?*ManifoldObj) void;

pub fn cube(x: f64, y: f64, z: f64, center: bool) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_cube(mem, x, y, z, if (center) 1 else 0);
}

pub fn cylinder(radius: f64, height: f64, center: bool) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_cylinder(mem, radius, height, if (center) 1 else 0);
}

pub fn sphere(radius: f64) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_sphere(mem, radius);
}

pub fn boolean(a: ?*ManifoldObj, b: ?*ManifoldObj, op: OpType) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_boolean(mem, a, b, op);
}

pub fn transform(obj: ?*ManifoldObj, matrix: *const [16]f64) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_transform(mem, obj, matrix);
}

pub fn destruct(m: ?*ManifoldObj) void {
    manifold_delete_manifold(m);
}
