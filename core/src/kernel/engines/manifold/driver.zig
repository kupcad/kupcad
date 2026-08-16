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

fn translateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(a.ptr));
    const ptr = manifold.translate(obj, x, y, z) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn rotateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(a.ptr));
    const ptr = manifold.rotate(obj, x, y, z) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn scaleImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(a.ptr));
    const ptr = manifold.scale(obj, x, y, z) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn queryFacesImpl(handle: geom.GeometryHandle, filter: geom.FaceFilter) ?geom.FaceArray {
    _ = handle;
    _ = filter;
    return null;
}

fn boundingBoxImpl(handle: geom.GeometryHandle) ?geom.BoundingBox {
    std.debug.assert(handle.engine == .manifold);
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(handle.ptr));
    const box = manifold.boundingBox(obj);
    return geom.BoundingBox{ .min = box.min, .max = box.max };
}

fn volumeImpl(handle: geom.GeometryHandle) f64 {
    std.debug.assert(handle.engine == .manifold);
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(handle.ptr));
    return manifold.volume(obj);
}

fn surfaceAreaImpl(handle: geom.GeometryHandle) f64 {
    std.debug.assert(handle.engine == .manifold);
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(handle.ptr));
    return manifold.surfaceArea(obj);
}

fn getMeshImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh {
    std.debug.assert(handle.engine == .manifold);
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(handle.ptr));

    const mesh_mem = manifold.allocMeshGL();
    defer manifold.deleteMeshGL(mesh_mem);

    const mesh = manifold.getMeshGL(mesh_mem, obj);
    if (mesh == null) return null;

    const num_prop = manifold.meshGLNumProp(mesh);
    const props_len = manifold.meshGLVertPropertiesLength(mesh);
    const tris_len = manifold.meshGLTriLength(mesh);

    const vert_props = allocator.alloc(f32, props_len) catch return null;
    _ = manifold.meshGLVertProperties(vert_props.ptr, mesh);

    const tri_verts = allocator.alloc(u32, tris_len) catch return null;
    _ = manifold.meshGLTriVerts(tri_verts.ptr, mesh);

    return geom.Mesh{
        .vert_props = vert_props,
        .tri_verts = tri_verts,
        .num_prop = num_prop,
    };
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

    .translateFn = translateImpl,
    .rotateFn = rotateImpl,
    .scaleFn = scaleImpl,

    .boundingBoxFn = boundingBoxImpl,
    .queryFacesFn = queryFacesImpl,
    .volumeFn = volumeImpl,
    .surfaceAreaFn = surfaceAreaImpl,

    .getMeshFn = getMeshImpl,

    .destructFn = destructImpl,
};
