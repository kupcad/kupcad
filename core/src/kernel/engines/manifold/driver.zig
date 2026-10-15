const std = @import("std");
const kernel = @import("../../kernel.zig");
const geom = @import("../../geometry_handle.zig");
const planar = @import("../../planar.zig");
const manifold = @import("../../../bindings/manifold.zig");

/// Thickness of the profile sheets loft hulls together (must be well below any real height).
const LOFT_SHEET_THICKNESS = 1e-3;

pub fn vecDot(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn vecNormalize(v: [3]f64) [3]f64 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len == 0.0) return .{ 0.0, 0.0, 0.0 };
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

pub fn computeNormal(v0: [3]f64, v1: [3]f64, v2: [3]f64) [3]f64 {
    const ax = v1[0] - v0[0];
    const ay = v1[1] - v0[1];
    const az = v1[2] - v0[2];

    const bx = v2[0] - v0[0];
    const by = v2[1] - v0[1];
    const bz = v2[2] - v0[2];

    const cross = [3]f64{
        ay * bz - az * by,
        az * bx - ax * bz,
        ax * by - ay * bx,
    };
    return vecNormalize(cross);
}

pub fn computeCentroid(v0: [3]f64, v1: [3]f64, v2: [3]f64) [3]f64 {
    return .{
        (v0[0] + v1[0] + v2[0]) / 3.0,
        (v0[1] + v1[1] + v2[1]) / 3.0,
        (v0[2] + v1[2] + v2[2]) / 3.0,
    };
}

fn materialPropFunc(new_prop: [*]f64, pos: manifold.ManifoldVec3, old_prop: [*]const f64, ctx: ?*anyopaque) callconv(.c) void {
    _ = pos;
    _ = old_prop;
    const mat_id: u32 = @intCast(@intFromPtr(ctx));
    new_prop[0] = @floatFromInt(mat_id);
}

// --- Primitives Generation ---

fn cubeImpl(x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    const ptr = manifold.cube(x, y, z, center) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn cylinderImpl(r1: f64, r2: f64, height: f64, center: bool, segments: i32) ?geom.GeometryHandle {
    const ptr = manifold.cylinder(r1, r2, height, center, segments) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn sphereImpl(radius: f64, segments: i32) ?geom.GeometryHandle {
    const ptr = manifold.sphere(radius, segments) orelse return null;
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
    // Start every slot empty so the deferred free is safe if a later allocation fails.
    @memset(m_contours, &.{});
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
    // Real check (not an assert): release builds must never reinterpret a B-Rep pointer as a Manifold.
    if (a.engine != .manifold or b.engine != .manifold) return null;
    const a_valid = @intFromPtr(a.ptr) != 0;
    const b_valid = @intFromPtr(b.ptr) != 0;

    // A failed operation is reported as null, never replaced by a copy of an operand:
    // `empty - b` is not `b`, and a silently skipped boolean is wrong geometry.
    if (!a_valid or !b_valid) return null;

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

fn batchBooleanImpl(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    if (objs.len == 0) return null;
    var m_objs = allocator.alloc(?*manifold.ManifoldObj, objs.len) catch return null;
    defer allocator.free(m_objs);

    for (objs, 0..) |obj, i| {
        if (obj.engine != .manifold) return null;
        m_objs[i] = @ptrCast(@alignCast(obj.ptr));
    }

    const m_op = switch (op) {
        .union_op => manifold.OpType.add,
        .difference_op => manifold.OpType.subtract,
        .intersection_op => manifold.OpType.intersect,
    };

    const ptr = manifold.batchBoolean(m_objs, m_op) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn crossSectionBooleanImpl(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: kernel.BooleanOp) ?geom.CrossSectionHandle {
    if (a.engine != .manifold or b.engine != .manifold) return null;
    const a_valid = @intFromPtr(a.ptr) != 0;
    const b_valid = @intFromPtr(b.ptr) != 0;

    if (!a_valid or !b_valid) return null;

    const m_op = switch (op) {
        .union_op => manifold.OpType.add,
        .difference_op => manifold.OpType.subtract,
        .intersection_op => manifold.OpType.intersect,
    };
    const ptr = manifold.crossSectionBoolean(@ptrCast(@alignCast(a.ptr)), @ptrCast(@alignCast(b.ptr)), m_op) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

/// Read from the sketch itself. Both this and the bounds used to extrude a throwaway
/// solid on every call and measure that.
fn crossSectionAreaImpl(handle: geom.CrossSectionHandle) f64 {
    if (@intFromPtr(handle.ptr) == 0) return 0.0;
    return manifold.crossSectionArea(@ptrCast(@alignCast(handle.ptr)));
}

/// The contours of a cross section, read in place through manifoldc (no copies).
const Contours = struct {
    polys: *manifold.ManifoldPolygons,

    fn of(handle: geom.CrossSectionHandle) ?Contours {
        const cs: *manifold.ManifoldCrossSection = @ptrCast(@alignCast(handle.ptr));
        return .{ .polys = manifold.crossSectionToPolygons(cs) orelse return null };
    }

    fn deinit(self: Contours) void {
        manifold.deletePolygons(self.polys);
    }

    fn count(self: Contours) usize {
        return manifold.polygonsLength(self.polys);
    }

    fn len(self: Contours, contour: usize) usize {
        return manifold.polygonsSimpleLength(self.polys, contour);
    }

    fn point(self: Contours, contour: usize, i: usize) [2]f64 {
        const p = manifold.polygonsGetPoint(self.polys, contour, i);
        return .{ p.x, p.y };
    }
};

fn crossSectionContainsPointImpl(handle: geom.CrossSectionHandle, pt: [2]f64, tolerance: f64) ?bool {
    if (@intFromPtr(handle.ptr) == 0) return false;
    const contours = Contours.of(handle) orelse return null;
    defer contours.deinit();

    var region = planar.RegionTest.init(pt, tolerance);
    for (0..contours.count()) |ci| {
        const n = contours.len(ci);
        if (n < 2) continue;
        var prev = contours.point(ci, n - 1);
        for (0..n) |i| {
            const cur = contours.point(ci, i);
            region.addEdge(prev, cur);
            prev = cur;
        }
    }
    return region.contains();
}

fn crossSectionIsConvexImpl(handle: geom.CrossSectionHandle) ?bool {
    if (@intFromPtr(handle.ptr) == 0) return null;
    const contours = Contours.of(handle) orelse return null;
    defer contours.deinit();
    if (contours.count() != 1) return false; // holes or several outlines
    return planar.isConvexRing(ContourRing{ .contours = contours, .index = 0 });
}

/// One contour of a `Contours`, as a ring for planar.isConvexRing.
const ContourRing = struct {
    contours: Contours,
    index: usize,
    pub fn len(self: ContourRing) usize {
        return self.contours.len(self.index);
    }
    pub fn at(self: ContourRing, i: usize) [2]f64 {
        return self.contours.point(self.index, i);
    }
};

fn crossSectionNumVertsImpl(handle: geom.CrossSectionHandle) usize {
    if (@intFromPtr(handle.ptr) == 0) return 0;
    return manifold.crossSectionNumVert(@ptrCast(@alignCast(handle.ptr)));
}

fn crossSectionBoundsImpl(handle: geom.CrossSectionHandle) geom.Rect2D {
    if (@intFromPtr(handle.ptr) == 0) return .{ .min = .{ 0.0, 0.0 }, .max = .{ 0.0, 0.0 } };
    const b = manifold.crossSectionBounds(@ptrCast(@alignCast(handle.ptr)));
    return .{ .min = .{ b.min.x, b.min.y }, .max = .{ b.max.x, b.max.y } };
}

fn minkowskiImpl(a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
    if (a.engine != .manifold or b.engine != .manifold) return null;
    if (@intFromPtr(a.ptr) == 0 or @intFromPtr(b.ptr) == 0) return null;
    const ptr = manifold.minkowskiSum(@ptrCast(@alignCast(a.ptr)), @ptrCast(@alignCast(b.ptr))) orelse return null;
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

fn batchHullImpl(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle) ?geom.GeometryHandle {
    if (objs.len == 0) return null;
    var m_objs = allocator.alloc(?*manifold.ManifoldObj, objs.len) catch return null;
    defer allocator.free(m_objs);

    for (objs, 0..) |obj, i| {
        if (obj.engine != .manifold) return null;
        m_objs[i] = @ptrCast(@alignCast(obj.ptr));
    }

    const ptr = manifold.batchHull(m_objs) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn loftImpl(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, height: f64) ?geom.GeometryHandle {
    if (a.engine != .manifold or b.engine != .manifold) return null;
    if (@intFromPtr(a.ptr) == 0 or @intFromPtr(b.ptr) == 0) return null;

    // The loft is the hull of two thin sheets, which is exact for convex profiles (the
    // evaluator rejects others). The top sheet sits just below `height` so the solid spans
    // exactly [0, height].
    const m_a = manifold.extrude(@ptrCast(@alignCast(a.ptr)), LOFT_SHEET_THICKNESS, 0, 0.0, 1.0, 1.0) orelse return null;
    defer manifold.destruct(m_a);

    const m_b_flat = manifold.extrude(@ptrCast(@alignCast(b.ptr)), LOFT_SHEET_THICKNESS, 0, 0.0, 1.0, 1.0) orelse return null;
    defer manifold.destruct(m_b_flat);

    const m_b = manifold.translate(m_b_flat, 0.0, 0.0, height - LOFT_SHEET_THICKNESS) orelse return null;
    defer manifold.destruct(m_b);

    // Pass the objects as a standard Zig slice to the public batchHull wrapper
    const objs = [_]?*manifold.ManifoldObj{ m_a, m_b };
    const hull_ptr = manifold.batchHull(&objs) orelse return null;

    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(hull_ptr) };
}

fn decomposeImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?[]geom.GeometryHandle {
    if (@intFromPtr(handle.ptr) == 0) return null;

    const vec = manifold.decompose(@ptrCast(@alignCast(handle.ptr))) orelse return null;
    defer manifold.destructManifoldVec(vec);

    const len = manifold.manifoldVecLength(vec);
    var res = allocator.alloc(geom.GeometryHandle, len) catch return null;

    for (0..len) |i| {
        // manifoldVecGet copies the component into a new caller-owned object.
        const child_ptr = manifold.manifoldVecGet(vec, i) orelse {
            for (res[0..i]) |h| destructImpl(h);
            allocator.free(res);
            return null;
        };
        res[i] = geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(child_ptr) };
    }
    return res;
}

fn transformMatrixImpl(a: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;

    // Fast Path 1: Pure Translation
    if (mat[0] == 1.0 and mat[1] == 0.0 and mat[2] == 0.0 and
        mat[3] == 0.0 and mat[4] == 1.0 and mat[5] == 0.0 and
        mat[6] == 0.0 and mat[7] == 0.0 and mat[8] == 1.0)
    {
        return translateImpl(a, mat[9], mat[10], mat[11]);
    }

    // Fast Path 2: Pure Scale
    if (mat[1] == 0.0 and mat[2] == 0.0 and
        mat[3] == 0.0 and mat[5] == 0.0 and
        mat[6] == 0.0 and mat[7] == 0.0 and
        mat[9] == 0.0 and mat[10] == 0.0 and mat[11] == 0.0)
    {
        return scaleImpl(a, mat[0], mat[4], mat[8]);
    }

    // Native Transform via pointer array
    const ptr = manifold.transform(@ptrCast(@alignCast(a.ptr)), &mat) orelse return null;

    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

/// Returns null on failure; kernel.simplify then falls back to a copy of the input.
fn simplifyImpl(a: geom.GeometryHandle, tolerance: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;

    const ptr = manifold.simplify(@ptrCast(@alignCast(a.ptr)), tolerance) orelse return null;

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
    // A closed mesh has one outward orientation. Faces wound inward give a valid but
    // inside-out solid (negative volume) that breaks every later boolean, so flip them.
    if (manifold.volume(ptr) >= 0) return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
    manifold.destruct(ptr);
    var t: usize = 0;
    while (t < tri_verts.len) : (t += 3) std.mem.swap(u32, &tri_verts[t + 1], &tri_verts[t + 2]);
    const flipped = manifold.polyhedron(vert_props, tri_verts) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(flipped) };
}

fn crossSectionTransformImpl(cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
    std.debug.assert(cs.engine == .manifold);
    if (@intFromPtr(cs.ptr) == 0) return null;

    // Safe: 6 floats comfortably fit inside xmm0-xmm5 CPU registers, avoiding the bug.
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

fn queryFacesImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle, direction: [3]f64, tolerance: f64) ?[]geom.FaceHandle {
    std.debug.assert(handle.engine == .manifold);
    if (@intFromPtr(handle.ptr) == 0) return null;

    // Extract the raw mesh from Manifold.
    const mesh = getMeshImpl(allocator, handle) orelse return null;
    defer {
        // Free the flat arrays after extraction since we only need them for this calculation.
        allocator.free(mesh.vert_props);
        allocator.free(mesh.tri_verts);
    }

    const norm_dir = vecNormalize(direction);

    var max_depth: f64 = -std.math.inf(f64);
    var accum_centroid = [3]f64{ 0, 0, 0 };
    var match_count: usize = 0;

    var i: usize = 0;
    // Protection: Ensure we always have a complete set of 3 indices to read to avoid out-of-bounds panics.
    while (i + 2 < mesh.tri_verts.len) : (i += 3) {
        // Extract indices (using idx0 instead of i0 to avoid shadowing the Zig primitive type)
        const idx0 = mesh.tri_verts[i] * mesh.num_prop;
        const idx1 = mesh.tri_verts[i + 1] * mesh.num_prop;
        const idx2 = mesh.tri_verts[i + 2] * mesh.num_prop;

        // Extract vertices (f32 -> f64 cast implicitly handled by initialization)
        const v0 = [3]f64{ mesh.vert_props[idx0], mesh.vert_props[idx0 + 1], mesh.vert_props[idx0 + 2] };
        const v1 = [3]f64{ mesh.vert_props[idx1], mesh.vert_props[idx1 + 1], mesh.vert_props[idx1 + 2] };
        const v2 = [3]f64{ mesh.vert_props[idx2], mesh.vert_props[idx2 + 1], mesh.vert_props[idx2 + 2] };

        const normal = computeNormal(v0, v1, v2);
        const alignment = vecDot(normal, norm_dir);

        // Check if triangle points in the target direction (dot product close to 1)
        if (1.0 - alignment <= tolerance) {
            const depth = vecDot(v0, norm_dir); // Project vertex onto direction to find the "furthest" face

            if (depth > max_depth + tolerance) {
                // Found a significantly further face! Reset accumulator.
                max_depth = depth;
                accum_centroid = computeCentroid(v0, v1, v2);
                match_count = 1;
            } else if (@abs(depth - max_depth) <= tolerance) {
                // Co-planar with current furthest face. Accumulate for the final average centroid.
                const c = computeCentroid(v0, v1, v2);
                accum_centroid[0] += c[0];
                accum_centroid[1] += c[1];
                accum_centroid[2] += c[2];
                match_count += 1;
            }
        }
    }

    if (match_count == 0) return null;

    // Allocate and return standard Zig slice
    var faces = allocator.alloc(geom.FaceHandle, 1) catch return null;
    faces[0] = .{
        .index = 0,
        .normal = norm_dir,
        .centroid = .{
            accum_centroid[0] / @as(f64, @floatFromInt(match_count)),
            accum_centroid[1] / @as(f64, @floatFromInt(match_count)),
            accum_centroid[2] / @as(f64, @floatFromInt(match_count)),
        },
    };

    return faces;
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
    if (a.engine != .manifold or b.engine != .manifold) return 0.0;
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
    return copyMesh(allocator, @ptrCast(@alignCast(handle.ptr))) catch null;
}

/// The mesh copied out of Manifold into `allocator`'s memory; on failure nothing stays
/// allocated (the vertices used to leak when the triangles' allocation failed).
fn copyMesh(allocator: std.mem.Allocator, obj: *manifold.ManifoldObj) !geom.Mesh {
    const mesh_mem = manifold.allocMeshGL();
    defer manifold.deleteMeshGL(mesh_mem);
    const mesh = manifold.getMeshGL(mesh_mem, obj) orelse return error.MeshUnavailable;
    const vert_props = try allocator.alloc(f32, manifold.meshGLVertPropertiesLength(mesh));
    errdefer allocator.free(vert_props);
    _ = manifold.meshGLVertProperties(vert_props.ptr, mesh);
    const tri_verts = try allocator.alloc(u32, manifold.meshGLTriLength(mesh));
    _ = manifold.meshGLTriVerts(tri_verts.ptr, mesh);
    return .{ .vert_props = vert_props, .tri_verts = tri_verts, .num_prop = manifold.meshGLNumProp(mesh) };
}

fn numVertsImpl(handle: geom.GeometryHandle) usize {
    std.debug.assert(handle.engine == .manifold);
    if (@intFromPtr(handle.ptr) == 0) return 0;
    return manifold.numVert(@ptrCast(@alignCast(handle.ptr)));
}

fn numTrisImpl(handle: geom.GeometryHandle) usize {
    std.debug.assert(handle.engine == .manifold);
    if (@intFromPtr(handle.ptr) == 0) return 0;
    return manifold.numTri(@ptrCast(@alignCast(handle.ptr)));
}

// --- Copies ---

fn cloneImpl(a: geom.GeometryHandle) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;
    const ptr = manifold.copy(@ptrCast(@alignCast(a.ptr))) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn cloneCrossSectionImpl(cs: geom.CrossSectionHandle) ?geom.CrossSectionHandle {
    std.debug.assert(cs.engine == .manifold);
    if (@intFromPtr(cs.ptr) == 0) return null;
    const ptr = manifold.crossSectionCopy(@ptrCast(@alignCast(cs.ptr))) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
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

// materials

fn setMaterialImpl(a: geom.GeometryHandle, material_id: u32) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    if (@intFromPtr(a.ptr) == 0) return null;

    // Pass the material slot through the C-FFI opaque pointer (0 would mean "default").
    const ctx: ?*anyopaque = @ptrFromInt(@as(usize, kernel.materialSlot(material_id)));
    const ptr = manifold.setProperties(@ptrCast(@alignCast(a.ptr)), 1, materialPropFunc, ctx) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

// --- Static Dispatch Table ---

/// Why Manifold flagged `a` as invalid (non-manifold input, non-finite vertices, ...),
/// or null if it is a valid solid.
fn problemImpl(a: geom.GeometryHandle) ?[]const u8 {
    if (@intFromPtr(a.ptr) == 0) return "the kernel returned no solid";
    return switch (manifold.status(@ptrCast(@alignCast(a.ptr)))) {
        .no_error => null,
        .non_finite_vertex => "a vertex has a NaN or infinite coordinate",
        .not_manifold => "the mesh is not a closed manifold (every edge must join exactly two faces, with consistent winding)",
        .vertex_index_out_of_bounds => "a face refers to a vertex that does not exist",
        .result_too_large => "the result is too large for the kernel",
        .invalid_construction => "the shape could not be constructed from these parameters",
        .cancelled => "the operation was cancelled",
        else => "the kernel rejected the mesh data",
    };
}

/// Manifold has every feature (kernel.Feature lists what an engine may lack).
pub fn supports(feature: kernel.Feature) bool {
    _ = feature;
    return true;
}

pub const driver = struct {
    pub const problemFn = problemImpl;
    pub const cubeFn = cubeImpl;
    pub const cylinderFn = cylinderImpl;
    pub const sphereFn = sphereImpl;
    pub const booleanFn = booleanImpl;
    pub const batchBooleanFn = batchBooleanImpl;
    pub const batchHullFn = batchHullImpl;
    pub const decomposeFn = decomposeImpl;
    pub const translateFn = translateImpl;
    pub const rotateFn = rotateImpl;
    pub const scaleFn = scaleImpl;
    pub const squareFn = squareImpl;
    pub const circleFn = circleImpl;
    pub const polyhedronFn = polyhedronImpl;
    pub const polygonsEvenOddFn = polygonsEvenOddImpl;
    pub const extrudeFn = extrudeImpl;
    pub const revolveFn = revolveImpl;
    pub const sliceFn = sliceImpl;
    pub const projectFn = projectImpl;
    pub const mirrorFn = mirrorImpl;
    pub const hullFn = hullImpl;
    pub const loftFn = loftImpl;
    pub const trimByPlaneFn = trimByPlaneImpl;
    pub const splitByPlaneFn = splitByPlaneImpl;
    pub const crossSectionBooleanFn = crossSectionBooleanImpl;
    pub const genusFn = genusImpl;
    pub const minkowskiFn = minkowskiImpl;
    pub const offsetFn = offsetImpl;
    pub const transformMatrixFn = transformMatrixImpl;
    pub const crossSectionTransformFn = crossSectionTransformImpl;
    pub const boundingBoxFn = boundingBoxImpl;
    pub const crossSectionAreaFn = crossSectionAreaImpl;
    pub const crossSectionBoundsFn = crossSectionBoundsImpl;
    pub const crossSectionNumVertsFn = crossSectionNumVertsImpl;
    pub const crossSectionContainsPointFn = crossSectionContainsPointImpl;
    pub const crossSectionIsConvexFn = crossSectionIsConvexImpl;
    pub const queryFacesFn = queryFacesImpl;
    pub const volumeFn = volumeImpl;
    pub const surfaceAreaFn = surfaceAreaImpl;
    pub const getMeshFn = getMeshImpl;
    pub const containsPointFn = containsPointImpl;
    pub const minGapFn = minGapImpl;
    pub const rayCastFn = rayCastImpl;
    pub const polygonFn = polygonImpl;
    pub const numVertsFn = numVertsImpl;
    pub const numTrisFn = numTrisImpl;
    pub const simplifyFn = simplifyImpl;
    pub const setMaterialFn = setMaterialImpl;
    pub const cloneFn = cloneImpl;
    pub const cloneCrossSectionFn = cloneCrossSectionImpl;
    pub const destructFn = destructImpl;
    pub const destructCrossSectionFn = destructCrossSectionImpl;
};
