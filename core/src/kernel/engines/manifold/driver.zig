const std = @import("std");
const kernel = @import("../../kernel.zig");
const geom = @import("../../geometry_handle.zig");
const manifold = @import("../../../bindings/manifold/manifold.zig");

// --- Primitives Generation ---

fn cubeImpl(x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    const ptr = manifold.cube(x, y, z, center) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn cylinderImpl(radius: f64, height: f64, center: bool, segments: i32) ?geom.GeometryHandle {
    const ptr = manifold.cylinder(radius, height, center, segments) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn sphereImpl(radius: f64) ?geom.GeometryHandle {
    const ptr = manifold.sphere(radius) orelse return null;
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

fn polygonImpl(allocator: std.mem.Allocator, pts: [][2]f64) ?geom.CrossSectionHandle {
    const m_pts = allocator.alloc(manifold.ManifoldVec2, pts.len) catch return null;
    defer allocator.free(m_pts);
    for (pts, 0..) |p, i| m_pts[i] = .{ .x = p[0], .y = p[1] };
    const ptr = manifold.polygon(m_pts) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn polygonsEvenOddImpl(allocator: std.mem.Allocator, contours: []const []const [2]f64) ?geom.CrossSectionHandle {
    // Convert [2]f64 contours to ManifoldVec2 contours
    var m_contours = allocator.alloc([]manifold.ManifoldVec2, contours.len) catch return null;
    defer {
        for (m_contours) |c| allocator.free(c);
        allocator.free(m_contours);
    }

    for (contours, 0..) |contour, i| {
        var m_pts = allocator.alloc(manifold.ManifoldVec2, contour.len) catch return null;
        for (contour, 0..) |p, j| m_pts[j] = .{ .x = p[0], .y = p[1] };
        m_contours[i] = m_pts;
    }

    // Call the high-level wrapper
    const ptr = manifold.crossSectionEvenOddPolygons(allocator, m_contours) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

// --- 3D CSG Booleans & Operations ---

fn booleanImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold and b.engine == .manifold);
    const a_valid = @intFromPtr(a.ptr) != 0;
    const b_valid = @intFromPtr(b.ptr) != 0;

    // Defensive fallback: prevent CSG pipeline poisoning if one handle is invalid
    if (!a_valid and !b_valid) return null;
    if (!a_valid) return b;
    if (!b_valid) return a;

    const m1: *manifold.ManifoldObj = @ptrCast(@alignCast(a.ptr));
    const m2: *manifold.ManifoldObj = @ptrCast(@alignCast(b.ptr));
    const m_op = switch (op) {
        .union_op => manifold.OpType.add,
        .difference_op => manifold.OpType.subtract,
        .intersection_op => manifold.OpType.intersect,
    };
    const ptr = manifold.boolean(m1, m2, m_op) orelse return a; // Fallback to base solid on C++ CSG failure
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn crossSectionBooleanImpl(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: kernel.BooleanOp) ?geom.CrossSectionHandle {
    std.debug.assert(a.engine == .manifold and b.engine == .manifold);
    const a_valid = @intFromPtr(a.ptr) != 0;
    const b_valid = @intFromPtr(b.ptr) != 0;

    if (!a_valid and !b_valid) return null;
    if (!a_valid) return b;
    if (!b_valid) return a;

    const m_op = switch (op) {
        .union_op => manifold.OpType.add,
        .difference_op => manifold.OpType.subtract,
        .intersection_op => manifold.OpType.intersect,
    };
    const ptr = manifold.crossSectionBoolean(@ptrCast(@alignCast(a.ptr)), @ptrCast(@alignCast(b.ptr)), m_op) orelse return a;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn minkowskiImpl(a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold and b.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    if (@intFromPtr(b.ptr) == 0) return a;
    // C++ Manifold fallback: If 3D mesh Minkowski fails, return `a` un-minkowskied instead of poisoning the DAG!
    const ptr = manifold.minkowskiSum(@ptrCast(@alignCast(a.ptr)), @ptrCast(@alignCast(b.ptr))) orelse return a;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

// --- 3D Rigid Transformations ---

fn translateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(a.ptr));
    const ptr = manifold.translate(obj, x, y, z) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn rotateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(a.ptr));
    const ptr = manifold.rotate(obj, x, y, z) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn scaleImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(a.ptr));
    const ptr = manifold.scale(obj, x, y, z) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn mirrorImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    const ptr = manifold.mirror(@ptrCast(@alignCast(a.ptr)), nx, ny, nz) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn hullImpl(a: geom.GeometryHandle) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    const ptr = manifold.hull(@ptrCast(@alignCast(a.ptr))) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn transformMatrixImpl(a: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    const ptr = manifold.transform(@ptrCast(@alignCast(a.ptr)), mat[0], mat[1], mat[2], mat[3], mat[4], mat[5], mat[6], mat[7], mat[8], mat[9], mat[10], mat[11]) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

// --- 2D Profile & Sweeps ---

fn offsetImpl(cs: geom.CrossSectionHandle, delta: f64, join_type: u8) ?geom.CrossSectionHandle {
    std.debug.assert(cs.engine == .manifold);
    if (@intFromPtr(cs.ptr) == 0) return null;
    const jt: manifold.JoinType = switch (join_type) {
        0 => .square,
        2 => .miter,
        3 => .bevel,
        else => .round,
    };
    const ptr = manifold.offset(@ptrCast(@alignCast(cs.ptr)), delta, jt, 2.0, 0) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn polyhedronImpl(allocator: std.mem.Allocator, points: []const [3]f64, faces: []const [3]u32) ?geom.GeometryHandle {
    // Flatten and convert f64 points to f32 for Manifold MeshGL
    var vert_props = allocator.alloc(f32, points.len * 3) catch return null;
    defer allocator.free(vert_props);
    for (points, 0..) |p, i| {
        vert_props[i * 3 + 0] = @floatCast(p[0]);
        vert_props[i * 3 + 1] = @floatCast(p[1]);
        vert_props[i * 3 + 2] = @floatCast(p[2]);
    }

    // Flatten u32 faces
    var tri_verts = allocator.alloc(u32, faces.len * 3) catch return null;
    defer allocator.free(tri_verts);
    for (faces, 0..) |f, i| {
        tri_verts[i * 3 + 0] = f[0];
        tri_verts[i * 3 + 1] = f[1];
        tri_verts[i * 3 + 2] = f[2];
    }

    const ptr = manifold.polyhedron(vert_props, tri_verts) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn crossSectionTransformImpl(cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
    std.debug.assert(cs.engine == .manifold);
    if (@intFromPtr(cs.ptr) == 0) return null;
    const ptr = manifold.crossSectionTransform(@ptrCast(@alignCast(cs.ptr)), mat[0], mat[1], mat[2], mat[3], mat[4], mat[5]) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn extrudeImpl(cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
    std.debug.assert(cs.engine == .manifold);
    if (@intFromPtr(cs.ptr) == 0) return null;
    const ptr = manifold.extrude(@ptrCast(@alignCast(cs.ptr)), height, slices, twist_degrees, scale_x, scale_y) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn revolveImpl(cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
    std.debug.assert(cs.engine == .manifold);
    if (@intFromPtr(cs.ptr) == 0) return null;
    const ptr = manifold.revolve(@ptrCast(@alignCast(cs.ptr)), segments, revolve_degrees) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

// --- Planar Cuts & Slicing ---

fn trimByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    const ptr = manifold.trimByPlane(@ptrCast(@alignCast(a.ptr)), nx, ny, nz, offset_dist) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn splitByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) geom.SolidPair {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return geom.SolidPair{ .first = null, .second = null };
    const pair = manifold.splitByPlane(@ptrCast(@alignCast(a.ptr)), nx, ny, nz, offset_dist);
    return geom.SolidPair{
        .first = if (pair[0] != null) geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(pair[0]) } else null,
        .second = if (pair[1] != null) geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(pair[1]) } else null,
    };
}

fn sliceImpl(a: geom.GeometryHandle, height: f64) ?geom.CrossSectionHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    const ptr = manifold.slice(@ptrCast(@alignCast(a.ptr)), height) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn projectImpl(a: geom.GeometryHandle) ?geom.CrossSectionHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    const ptr = manifold.project(@ptrCast(@alignCast(a.ptr))) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

// --- Mass Properties & Spatial Diagnostics ---

fn genusImpl(handle: geom.GeometryHandle) i32 {
    std.debug.assert(handle.engine == .manifold);
    if (@intFromPtr(handle.ptr) == 0) return 0;
    return manifold.genus(@ptrCast(@alignCast(handle.ptr)));
}

fn queryFacesImpl(handle: geom.GeometryHandle, filter: geom.FaceFilter) ?geom.FaceArray {
    _ = handle;
    _ = filter;
    return null;
}

fn boundingBoxImpl(handle: geom.GeometryHandle) ?geom.BoundingBox {
    std.debug.assert(handle.engine == .manifold);
    if (@intFromPtr(handle.ptr) == 0) return null;
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(handle.ptr));
    const box = manifold.boundingBox(obj);
    return geom.BoundingBox{ .min = box.min, .max = box.max };
}

fn volumeImpl(handle: geom.GeometryHandle) f64 {
    std.debug.assert(handle.engine == .manifold);
    if (@intFromPtr(handle.ptr) == 0) return 0.0;
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(handle.ptr));
    return manifold.volume(obj);
}

fn surfaceAreaImpl(handle: geom.GeometryHandle) f64 {
    std.debug.assert(handle.engine == .manifold);
    if (@intFromPtr(handle.ptr) == 0) return 0.0;
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(handle.ptr));
    return manifold.surfaceArea(obj);
}

fn containsPointImpl(a: geom.GeometryHandle, pt: [3]f64) bool {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return false;
    return manifold.containsPoint(@ptrCast(@alignCast(a.ptr)), pt[0], pt[1], pt[2]);
}

fn minGapImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, search_length: f64) f64 {
    std.debug.assert(a.engine == .manifold and b.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0 or @intFromPtr(b.ptr) == 0) return 0.0;
    return manifold.minGap(@ptrCast(@alignCast(a.ptr)), @ptrCast(@alignCast(b.ptr)), search_length);
}

fn rayCastImpl(allocator: std.mem.Allocator, a: geom.GeometryHandle, origin: [3]f64, end: [3]f64) ?[]geom.RayHit {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    return manifold.rayCast(allocator, @ptrCast(@alignCast(a.ptr)), origin[0], origin[1], origin[2], end[0], end[1], end[2]);
}

fn getMeshImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh {
    std.debug.assert(handle.engine == .manifold);
    if (@intFromPtr(handle.ptr) == 0) return null;
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

// --- Destructors ---

fn destructImpl(handle: geom.GeometryHandle) void {
    std.debug.assert(handle.engine == .manifold);
    if (@intFromPtr(handle.ptr) != 0) {
        manifold.destruct(@ptrCast(@alignCast(handle.ptr)));
    }
}

fn destructCrossSectionImpl(handle: geom.CrossSectionHandle) void {
    std.debug.assert(handle.engine == .manifold);
    if (@intFromPtr(handle.ptr) != 0) {
        manifold.destructCrossSection(@ptrCast(@alignCast(handle.ptr)));
    }
}

// --- Static Dispatch Table ---

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
    .polyhedronFn = polyhedronImpl,
    .polygonsEvenOddFn = polygonsEvenOddImpl,
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
