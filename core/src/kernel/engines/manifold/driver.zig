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

fn squareImpl(x: f64, y: f64, center: bool) ?geom.CrossSectionHandle {
    const ptr = manifold.square(x, y, center) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn circleImpl(radius: f64, segments: i32) ?geom.CrossSectionHandle {
    const ptr = manifold.circle(radius, segments) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn extrudeImpl(cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
    std.debug.assert(cs.engine == .manifold);
    const ptr = manifold.extrude(@ptrCast(@alignCast(cs.ptr)), height, slices, twist_degrees, scale_x, scale_y) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn revolveImpl(cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
    std.debug.assert(cs.engine == .manifold);
    const ptr = manifold.revolve(@ptrCast(@alignCast(cs.ptr)), segments, revolve_degrees) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn sliceImpl(a: geom.GeometryHandle, height: f64) ?geom.CrossSectionHandle {
    std.debug.assert(a.engine == .manifold);
    const ptr = manifold.slice(@ptrCast(@alignCast(a.ptr)), height) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn projectImpl(a: geom.GeometryHandle) ?geom.CrossSectionHandle {
    std.debug.assert(a.engine == .manifold);
    const ptr = manifold.project(@ptrCast(@alignCast(a.ptr))) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn mirrorImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    const ptr = manifold.mirror(@ptrCast(@alignCast(a.ptr)), nx, ny, nz) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn hullImpl(a: geom.GeometryHandle) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    const ptr = manifold.hull(@ptrCast(@alignCast(a.ptr))) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn trimByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    const ptr = manifold.trimByPlane(@ptrCast(@alignCast(a.ptr)), nx, ny, nz, offset) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn splitByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset: f64) geom.SolidPair {
    std.debug.assert(a.engine == .manifold);
    const pair = manifold.splitByPlane(@ptrCast(@alignCast(a.ptr)), nx, ny, nz, offset);
    return geom.SolidPair{
        .first = if (pair[0] != null) geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(pair[0]) } else null,
        .second = if (pair[1] != null) geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(pair[1]) } else null,
    };
}

fn genusImpl(handle: geom.GeometryHandle) i32 {
    std.debug.assert(handle.engine == .manifold);
    return manifold.genus(@ptrCast(@alignCast(handle.ptr)));
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

fn destructCrossSectionImpl(handle: geom.CrossSectionHandle) void {
    std.debug.assert(handle.engine == .manifold);
    manifold.destructCrossSection(@ptrCast(@alignCast(handle.ptr)));
}

pub const driver = kernel.GeometryKernel{
    .cubeFn = cubeImpl,
    .cylinderFn = cylinderImpl,
    .sphereFn = sphereImpl,
    .booleanFn = booleanImpl,
    .translateFn = translateImpl,
    .rotateFn = rotateImpl,
    .scaleFn = scaleImpl,

    .squareFn = squareImpl,
    .circleFn = circleImpl,
    .extrudeFn = extrudeImpl,
    .revolveFn = revolveImpl,
    .sliceFn = sliceImpl,
    .projectFn = projectImpl,
    .mirrorFn = mirrorImpl,
    .hullFn = hullImpl,
    .trimByPlaneFn = trimByPlaneImpl,
    .splitByPlaneFn = splitByPlaneImpl,
    .genusFn = genusImpl,

    .boundingBoxFn = boundingBoxImpl,
    .queryFacesFn = queryFacesImpl,
    .volumeFn = volumeImpl,
    .surfaceAreaFn = surfaceAreaImpl,
    .getMeshFn = getMeshImpl,
    .destructFn = destructImpl,
    .destructCrossSectionFn = destructCrossSectionImpl,
};
