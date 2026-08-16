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

fn trimByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    const ptr = manifold.trimByPlane(@ptrCast(@alignCast(a.ptr)), nx, ny, nz, offset_dist) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn splitByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) geom.SolidPair {
    std.debug.assert(a.engine == .manifold);
    const pair = manifold.splitByPlane(@ptrCast(@alignCast(a.ptr)), nx, ny, nz, offset_dist);
    return geom.SolidPair{
        .first = if (pair[0] != null) geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(pair[0]) } else null,
        .second = if (pair[1] != null) geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(pair[1]) } else null,
    };
}

fn crossSectionBooleanImpl(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: kernel.BooleanOp) ?geom.CrossSectionHandle {
    std.debug.assert(a.engine == .manifold and b.engine == .manifold);
    const m_op = switch (op) {
        .union_op => manifold.OpType.add,
        .difference_op => manifold.OpType.subtract,
        .intersection_op => manifold.OpType.intersect,
    };
    const ptr = manifold.crossSectionBoolean(@ptrCast(@alignCast(a.ptr)), @ptrCast(@alignCast(b.ptr)), m_op) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn transformMatrixImpl(a: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    const ptr = manifold.transform(@ptrCast(@alignCast(a.ptr)), mat[0], mat[1], mat[2], mat[3], mat[4], mat[5], mat[6], mat[7], mat[8], mat[9], mat[10], mat[11]) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn crossSectionTransformImpl(cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
    std.debug.assert(cs.engine == .manifold);
    const ptr = manifold.crossSectionTransform(@ptrCast(@alignCast(cs.ptr)), mat[0], mat[1], mat[2], mat[3], mat[4], mat[5]) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
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

fn minkowskiImpl(a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold and b.engine == .manifold);
    const ptr = manifold.minkowskiSum(@ptrCast(@alignCast(a.ptr)), @ptrCast(@alignCast(b.ptr))) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn offsetImpl(cs: geom.CrossSectionHandle, delta: f64, join_type: u8) ?geom.CrossSectionHandle {
    std.debug.assert(cs.engine == .manifold);
    const jt: manifold.JoinType = switch (join_type) {
        0 => .square,
        2 => .miter,
        3 => .bevel,
        else => .round,
    };
    const ptr = manifold.offset(@ptrCast(@alignCast(cs.ptr)), delta, jt, 2.0, 0) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
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

fn containsPointImpl(a: geom.GeometryHandle, pt: [3]f64) bool {
    std.debug.assert(a.engine == .manifold);
    return manifold.containsPoint(@ptrCast(@alignCast(a.ptr)), pt[0], pt[1], pt[2]);
}

fn minGapImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, search_length: f64) f64 {
    std.debug.assert(a.engine == .manifold and b.engine == .manifold);
    return manifold.minGap(@ptrCast(@alignCast(a.ptr)), @ptrCast(@alignCast(b.ptr)), search_length);
}

fn rayCastImpl(allocator: std.mem.Allocator, a: geom.GeometryHandle, origin: [3]f64, end: [3]f64) ?[]geom.RayHit {
    std.debug.assert(a.engine == .manifold);
    return manifold.rayCast(allocator, @ptrCast(@alignCast(a.ptr)), origin[0], origin[1], origin[2], end[0], end[1], end[2]);
}

fn polygonImpl(allocator: std.mem.Allocator, pts: [][2]f64) ?geom.CrossSectionHandle {
    const m_pts = allocator.alloc(manifold.ManifoldVec2, pts.len) catch return null;
    defer allocator.free(m_pts);
    for (pts, 0..) |p, i| m_pts[i] = .{ .x = p[0], .y = p[1] };
    const ptr = manifold.polygon(m_pts) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
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
    .crossSectionBooleanFn = crossSectionBooleanImpl,
    .genusFn = genusImpl,
    .minkowskiFn = minkowskiImpl,
    .offsetFn = offsetImpl,
    .transformMatrixFn = transformMatrixImpl,
    .crossSectionTransformFn = crossSectionTransformImpl,

    .boundingBoxFn = boundingBoxImpl,
    .queryFacesFn = queryFacesImpl,
    .volumeFn = volumeImpl,
    .surfaceAreaFn = surfaceAreaImpl,
    .getMeshFn = getMeshImpl,
    .containsPointFn = containsPointImpl,
    .minGapFn = minGapImpl,
    .rayCastFn = rayCastImpl,
    .polygonFn = polygonImpl,

    .destructFn = destructImpl,
    .destructCrossSectionFn = destructCrossSectionImpl,
};
