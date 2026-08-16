const std = @import("std");

pub const ManifoldObj = opaque {};
pub const ManifoldBox = opaque {};

pub const OpType = enum(c_int) {
    add = 0,
    subtract = 1,
    intersect = 2,
};

// C API Vector struct returned by value
pub const ManifoldVec3 = extern struct {
    x: f64,
    y: f64,
    z: f64,
};

extern "C" fn manifold_alloc_manifold() ?*ManifoldObj;
extern "C" fn manifold_delete_manifold(m: ?*ManifoldObj) void;

extern "C" fn manifold_alloc_box() ?*ManifoldBox;
extern "C" fn manifold_delete_box(b: ?*ManifoldBox) void;

// Natively enforcing 64-bit precision for the C-ABI boundaries
extern "C" fn manifold_cube(mem: ?*ManifoldObj, x: f64, y: f64, z: f64, center: c_int) ?*ManifoldObj;
extern "C" fn manifold_cylinder(mem: ?*ManifoldObj, height: f64, radiusLow: f64, radiusHigh: f64, circularSegments: c_int, center: c_int) ?*ManifoldObj;
extern "C" fn manifold_sphere(mem: ?*ManifoldObj, radius: f64, circularSegments: c_int) ?*ManifoldObj;
extern "C" fn manifold_boolean(mem: ?*ManifoldObj, a: ?*ManifoldObj, b: ?*ManifoldObj, op: OpType) ?*ManifoldObj;

extern "C" fn manifold_translate(mem: ?*ManifoldObj, m: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj;
extern "C" fn manifold_rotate(mem: ?*ManifoldObj, m: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj;
extern "C" fn manifold_scale(mem: ?*ManifoldObj, m: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj;

extern "C" fn manifold_bounding_box(mem: ?*ManifoldBox, m: ?*ManifoldObj) ?*ManifoldBox;
extern "C" fn manifold_box_min(b: ?*ManifoldBox) ManifoldVec3;
extern "C" fn manifold_box_max(b: ?*ManifoldBox) ManifoldVec3;

extern "C" fn manifold_volume(m: ?*ManifoldObj) f64;
extern "C" fn manifold_surface_area(m: ?*ManifoldObj) f64;

pub fn cube(x: f64, y: f64, z: f64, center: bool) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_cube(mem, x, y, z, if (center) 1 else 0);
}

pub fn cylinder(radius: f64, height: f64, center: bool) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_cylinder(mem, height, radius, radius, 0, if (center) 1 else 0);
}

pub fn sphere(radius: f64) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_sphere(mem, radius, 0);
}

pub fn boolean(a: ?*ManifoldObj, b: ?*ManifoldObj, op: OpType) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_boolean(mem, a, b, op);
}

pub fn translate(obj: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_translate(mem, obj, x, y, z);
}

pub fn rotate(obj: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_rotate(mem, obj, x, y, z);
}

pub fn scale(obj: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj {
    const mem = manifold_alloc_manifold();
    return manifold_scale(mem, obj, x, y, z);
}

pub fn boundingBox(obj: ?*ManifoldObj) struct { min: [3]f64, max: [3]f64 } {
    const box_mem = manifold_alloc_box();
    defer manifold_delete_box(box_mem);

    const box_ptr = manifold_bounding_box(box_mem, obj);
    if (box_ptr == null) return .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } };

    const min_v = manifold_box_min(box_ptr);
    const max_v = manifold_box_max(box_ptr);

    return .{
        .min = .{ min_v.x, min_v.y, min_v.z },
        .max = .{ max_v.x, max_v.y, max_v.z },
    };
}

pub fn volume(obj: ?*ManifoldObj) f64 {
    return manifold_volume(obj);
}

pub fn surfaceArea(obj: ?*ManifoldObj) f64 {
    return manifold_surface_area(obj);
}

pub fn destruct(m: ?*ManifoldObj) void {
    if (m != null) {
        manifold_delete_manifold(m);
    }
}
