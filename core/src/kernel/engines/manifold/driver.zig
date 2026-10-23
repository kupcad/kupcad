//! The Manifold mesh engine behind `kernel.zig`: `driver` maps each kernel operation
//! (primitives, booleans, transforms, extrusions, queries, reading out the mesh) onto the
//! Manifold C bindings, and `supports` says it has every `kernel.Feature`.

const std = @import("std");
const kernel = @import("../../kernel.zig");
const geom = @import("../../../core/geometry_handle.zig");
const planar = @import("../../planar.zig");
const manifold = @import("../../../bindings/manifold.zig");
const engine_config = @import("../../../core/engine_config.zig");
const EngineConfig = engine_config.EngineConfig;
const vec3 = @import("../../../core/vec3.zig");

fn materialPropFunc(new_prop: [*]f64, pos: manifold.ManifoldVec3, old_prop: [*]const f64, ctx: ?*anyopaque) callconv(.c) void {
    _ = pos;
    _ = old_prop;
    const mat_id: u32 = @intCast(@intFromPtr(ctx));
    new_prop[0] = @floatFromInt(mat_id);
}

// --- Primitives Generation ---

fn emptyImpl(config: *const EngineConfig) ?geom.GeometryHandle {
    _ = config; // Manifold builds what it is given; B-Rep reads its resolution from it
    const ptr = manifold.empty() orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn emptySketchImpl(config: *const EngineConfig) ?geom.CrossSectionHandle {
    _ = config; // Manifold builds what it is given; B-Rep reads its resolution from it
    const ptr = manifold.emptyCrossSection() orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn cubeImpl(config: *const EngineConfig, x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    _ = config; // Manifold builds what it is given; B-Rep reads its resolution from it
    const ptr = manifold.cube(x, y, z, center) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn cylinderImpl(config: *const EngineConfig, r1: f64, r2: f64, height: f64, center: bool, segments: i32) ?geom.GeometryHandle {
    _ = config; // Manifold builds what it is given; B-Rep reads its resolution from it
    const ptr = manifold.cylinder(r1, r2, height, center, segments) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn sphereImpl(config: *const EngineConfig, radius: f64, segments: i32) ?geom.GeometryHandle {
    _ = config; // Manifold builds what it is given; B-Rep reads its resolution from it
    const ptr = manifold.sphere(radius, segments) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn squareImpl(config: *const EngineConfig, x: f64, y: f64, center: bool) ?geom.CrossSectionHandle {
    _ = config; // Manifold builds what it is given; B-Rep reads its resolution from it
    const ptr = manifold.square(x, y, center) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn circleImpl(config: *const EngineConfig, radius: f64, segments: i32) ?geom.CrossSectionHandle {
    _ = config; // Manifold builds what it is given; B-Rep reads its resolution from it
    const ptr = manifold.circle(radius, segments) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn polygonImpl(config: *const EngineConfig, allocator: std.mem.Allocator, pts: []const [2]f64) ?geom.CrossSectionHandle {
    _ = config; // Manifold builds what it is given; B-Rep reads its resolution from it
    const m_pts = allocator.alloc(manifold.ManifoldVec2, pts.len) catch return null;
    defer allocator.free(m_pts);
    for (pts, 0..) |p, i| m_pts[i] = .{ .x = p[0], .y = p[1] };
    const ptr = manifold.polygon(m_pts) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn polygonsEvenOddImpl(config: *const EngineConfig, allocator: std.mem.Allocator, contours: []const []const [2]f64) ?geom.CrossSectionHandle {
    _ = config; // Manifold builds what it is given; B-Rep reads its resolution from it
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

fn crossSectionContoursImpl(handle: geom.CrossSectionHandle, allocator: std.mem.Allocator) ?geom.Contours {
    const contours = Contours.of(handle) orelse return null;
    defer contours.deinit();
    const count = contours.count();
    var total: usize = 0;
    for (0..count) |ci| total += contours.len(ci);
    const points = allocator.alloc([2]f64, total) catch return null;
    errdefer allocator.free(points);
    const starts = allocator.alloc(u32, count + 1) catch return null;
    var at: usize = 0;
    for (0..count) |ci| {
        starts[ci] = @intCast(at);
        for (0..contours.len(ci)) |i| {
            points[at] = contours.point(ci, i);
            at += 1;
        }
    }
    starts[count] = @intCast(at);
    return .{ .points = points, .starts = starts };
}

fn crossSectionContainsPointImpl(handle: geom.CrossSectionHandle, pt: [2]f64, tolerance: f64) ?bool {
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
    return manifold.crossSectionNumVert(@ptrCast(@alignCast(handle.ptr)));
}

fn crossSectionBoundsImpl(handle: geom.CrossSectionHandle) ?geom.Rect2D {
    if (manifold.crossSectionNumVert(@ptrCast(@alignCast(handle.ptr))) == 0) return null;
    const b = manifold.crossSectionBounds(@ptrCast(@alignCast(handle.ptr)));
    return .{ .min = .{ b.min.x, b.min.y }, .max = .{ b.max.x, b.max.y } };
}

fn minkowskiImpl(a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
    if (a.engine != .manifold or b.engine != .manifold) return null;
    const ptr = manifold.minkowskiSum(@ptrCast(@alignCast(a.ptr)), @ptrCast(@alignCast(b.ptr))) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

/// What is left of the solid once the space around it, grown by a sphere of `radius` (a
/// Minkowski sum), is cut away: the solid shrunk by `radius` on every side. The space is a
/// box past the solid by twice the radius on each side, less the solid, so it reaches
/// every point within the radius of the solid's surface.
fn erodeImpl(a: geom.GeometryHandle, radius: f64, segments: i32) ?geom.GeometryHandle {
    if (a.engine != .manifold) return null;
    const solid: *manifold.ManifoldObj = @ptrCast(@alignCast(a.ptr));
    const bounds = manifold.boundingBox(solid);
    const margin = 2 * radius;
    const size = [3]f64{ bounds.max[0] - bounds.min[0] + 2 * margin, bounds.max[1] - bounds.min[1] + 2 * margin, bounds.max[2] - bounds.min[2] + 2 * margin };
    const block = manifold.cube(size[0], size[1], size[2], false) orelse return null;
    defer manifold.destruct(block);
    const box = manifold.translate(block, bounds.min[0] - margin, bounds.min[1] - margin, bounds.min[2] - margin) orelse return null;
    defer manifold.destruct(box);
    const around = manifold.boolean(box, solid, .subtract) orelse return null;
    defer manifold.destruct(around);
    const ball = manifold.sphere(radius, segments) orelse return null;
    defer manifold.destruct(ball);
    const grown = manifold.minkowskiSum(around, ball) orelse return null;
    defer manifold.destruct(grown);
    const ptr = manifold.boolean(solid, grown, .subtract) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

// --- 3D Rigid Transformations ---

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

fn crossSectionHullImpl(allocator: std.mem.Allocator, sketches: []const geom.CrossSectionHandle) ?geom.CrossSectionHandle {
    const m_sketches = allocator.alloc(*manifold.ManifoldCrossSection, sketches.len) catch return null;
    defer allocator.free(m_sketches);
    for (sketches, m_sketches) |cs, *m| {
        if (cs.engine != .manifold) return null;
        m.* = @ptrCast(@alignCast(cs.ptr));
    }
    const ptr = manifold.crossSectionBatchHull(m_sketches) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

/// The loft of two convex profiles (the evaluator rejects others) is the hull of their
/// outlines placed at z = 0 and z = height: exact, with nothing to tune. (It hulled two thin
/// extruded sheets, which bulged by their thickness wherever the profiles differ.)
fn loftImpl(allocator: std.mem.Allocator, a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, height: f64) ?geom.GeometryHandle {
    if (a.engine != .manifold or b.engine != .manifold) return null;

    var pts = std.ArrayList(manifold.ManifoldVec3).empty;
    defer pts.deinit(allocator);
    for ([2]geom.CrossSectionHandle{ a, b }, [2]f64{ 0.0, height }) |profile, z| {
        const contours = Contours.of(profile) orelse return null;
        defer contours.deinit();
        for (0..contours.count()) |ci| {
            for (0..contours.len(ci)) |i| {
                const p = contours.point(ci, i);
                pts.append(allocator, .{ .x = p[0], .y = p[1], .z = z }) catch return null;
            }
        }
    }
    const hull_ptr = manifold.hullPoints(pts.items) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(hull_ptr) };
}

fn decomposeImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?[]geom.GeometryHandle {
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

    const ptr = manifold.simplify(@ptrCast(@alignCast(a.ptr)), tolerance) orelse return null;

    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

// --- 2D Profile & Sweeps ---

fn offsetImpl(cs: geom.CrossSectionHandle, delta: f64, join_type: u8, segments: i32, miter_limit: f64) ?geom.CrossSectionHandle {
    std.debug.assert(cs.engine == .manifold);
    const jt: manifold.JoinType = switch (join_type) {
        0 => .square,
        2 => .miter,
        3 => .bevel,
        else => .round,
    };
    const ptr = manifold.offset(@ptrCast(@alignCast(cs.ptr)), delta, jt, miter_limit, segments) orelse return null;
    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn polyhedronImpl(config: *const EngineConfig, allocator: std.mem.Allocator, points: []const [3]f64, faces: []const [3]u32) ?geom.GeometryHandle {
    _ = config; // Manifold builds what it is given; B-Rep reads its resolution from it
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

    // Safe: 6 floats comfortably fit inside xmm0-xmm5 CPU registers, avoiding the bug.
    const ptr = manifold.crossSectionTransform(@ptrCast(@alignCast(cs.ptr)), mat[0], mat[1], mat[2], mat[3], mat[4], mat[5]) orelse return null;

    return geom.CrossSectionHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn extrudeImpl(cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
    std.debug.assert(cs.engine == .manifold);
    // Sweeping the empty Sketch gives the empty Solid (Manifold rejects empty polygons).
    if (manifold.crossSectionNumVert(@ptrCast(@alignCast(cs.ptr))) == 0) return emptyImpl(&.{});
    const ptr = manifold.extrude(@ptrCast(@alignCast(cs.ptr)), height, slices, twist_degrees, scale_x, scale_y) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn revolveImpl(cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
    std.debug.assert(cs.engine == .manifold);
    if (manifold.crossSectionNumVert(@ptrCast(@alignCast(cs.ptr))) == 0) return emptyImpl(&.{});
    const ptr = manifold.revolve(@ptrCast(@alignCast(cs.ptr)), segments, revolve_degrees) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

// --- Planar Cuts & Slicing ---

fn trimByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    const ptr = manifold.trimByPlane(@ptrCast(@alignCast(a.ptr)), nx, ny, nz, offset_dist) orelse return null;
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

// --- Mass Properties & Spatial Diagnostics ---

fn genusImpl(handle: geom.GeometryHandle) i32 {
    std.debug.assert(handle.engine == .manifold);
    return manifold.genus(@ptrCast(@alignCast(handle.ptr)));
}

/// The face of the solid furthest along `direction` among those facing it (their normals
/// within ANGULAR_TOLERANCE of it, as the B-Rep kernel compares directions), its triangles'
/// centroid averaged over those within `tolerance` of its plane. Read from the mesh in f64,
/// so the plane test means the same at any size.
fn queryFacesImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle, direction: [3]f64, tolerance: f64) ?[]geom.FaceHandle {
    std.debug.assert(handle.engine == .manifold);
    var mesh = Mesh64.of(allocator, @ptrCast(@alignCast(handle.ptr))) catch return null;
    defer mesh.deinit(allocator);

    const norm_dir = vec3.normalize(direction);
    var max_depth: f64 = -std.math.inf(f64);
    var accum_centroid = [3]f64{ 0, 0, 0 };
    var match_count: usize = 0;
    for (0..mesh.triangleCount()) |t| {
        const tri = mesh.triangle(t);
        if (1.0 - vec3.dot(vec3.triangleNormal(tri[0], tri[1], tri[2]), norm_dir) > engine_config.ANGULAR_TOLERANCE) continue;
        // How far along the direction its plane lies: a further one starts the face over,
        // one as far adds to it
        const depth = vec3.dot(tri[0], norm_dir);
        const c = vec3.centroid(tri[0], tri[1], tri[2]);
        if (depth > max_depth + tolerance) {
            max_depth = depth;
            accum_centroid = c;
            match_count = 1;
        } else if (@abs(depth - max_depth) <= tolerance) {
            accum_centroid = vec3.add(accum_centroid, c);
            match_count += 1;
        }
    }
    if (match_count == 0) return null;

    const faces = allocator.alloc(geom.FaceHandle, 1) catch return null;
    faces[0] = .{ .index = 0, .normal = norm_dir, .centroid = vec3.scale(accum_centroid, 1.0 / @as(f64, @floatFromInt(match_count))) };
    return faces;
}

/// A solid's mesh as Manifold keeps it, in f64: what a measurement reads, where the f32
/// mesh an export writes would round a large part's coordinates by more than a tolerance.
const Mesh64 = struct {
    vert_props: []f64,
    tri_verts: []u64,
    num_prop: usize,

    /// On failure nothing stays allocated. An empty solid has nothing to copy (the C
    /// binding memcpy's from a null data pointer then, see copyMesh).
    fn of(allocator: std.mem.Allocator, obj: *manifold.ManifoldObj) !Mesh64 {
        const mem = manifold.allocMeshGL64();
        defer manifold.deleteMeshGL64(mem);
        const mesh = manifold.getMeshGL64(mem, obj) orelse return error.MeshUnavailable;
        const vert_props = try allocator.alloc(f64, manifold.meshGL64VertPropertiesLength(mesh));
        errdefer allocator.free(vert_props);
        if (vert_props.len > 0) _ = manifold.meshGL64VertProperties(vert_props.ptr, mesh);
        const tri_verts = try allocator.alloc(u64, manifold.meshGL64TriLength(mesh));
        if (tri_verts.len > 0) _ = manifold.meshGL64TriVerts(tri_verts.ptr, mesh);
        return .{ .vert_props = vert_props, .tri_verts = tri_verts, .num_prop = manifold.meshGL64NumProp(mesh) };
    }

    fn deinit(self: *Mesh64, allocator: std.mem.Allocator) void {
        allocator.free(self.vert_props);
        allocator.free(self.tri_verts);
    }

    fn triangleCount(self: Mesh64) usize {
        return self.tri_verts.len / 3;
    }

    /// Triangle `t`'s corners.
    fn triangle(self: Mesh64, t: usize) [3][3]f64 {
        var corners: [3][3]f64 = undefined;
        // A vertex of a mesh in memory is an index into it, whatever usize's width
        for (&corners, self.tri_verts[3 * t ..][0..3]) |*corner, vertex| corner.* = self.vert_props[@as(usize, @intCast(vertex)) * self.num_prop ..][0..3].*;
        return corners;
    }
};

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

/// Whether `pt` lies in the solid, the solid closed: inside by its winding number, or
/// within `config`'s tolerance of its surface (where the winding number may go either way),
/// as a sketch's region is closed. Null when its mesh can't be read into `allocator`.
fn containsPointImpl(allocator: std.mem.Allocator, a: geom.GeometryHandle, config: *const EngineConfig, pt: [3]f64) ?bool {
    std.debug.assert(a.engine == .manifold);
    const obj: *manifold.ManifoldObj = @ptrCast(@alignCast(a.ptr));
    if (manifold.containsPoint(obj, pt[0], pt[1], pt[2])) return true;
    const tolerance = config.tolerance;
    const box = manifold.boundingBox(obj);
    for (0..3) |axis| {
        if (pt[axis] < box.min[axis] - tolerance or pt[axis] > box.max[axis] + tolerance) return false;
    }
    var mesh = Mesh64.of(allocator, obj) catch return null;
    defer mesh.deinit(allocator);
    for (0..mesh.triangleCount()) |t| {
        const tri = mesh.triangle(t);
        if (vec3.pointTriangleDistanceSq(pt, tri[0], tri[1], tri[2]) <= tolerance * tolerance) return true;
    }
    return false;
}

fn minGapImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, search_length: f64) f64 {
    if (a.engine != .manifold or b.engine != .manifold) return 0.0;
    return manifold.minGap(@ptrCast(@alignCast(a.ptr)), @ptrCast(@alignCast(b.ptr)), search_length);
}

fn rayCastImpl(allocator: std.mem.Allocator, a: geom.GeometryHandle, origin: [3]f64, end: [3]f64) ?[]geom.RayHit {
    std.debug.assert(a.engine == .manifold);
    return manifold.rayCast(allocator, @ptrCast(@alignCast(a.ptr)), origin[0], origin[1], origin[2], end[0], end[1], end[2]);
}

fn getMeshImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh {
    std.debug.assert(handle.engine == .manifold);
    return copyMesh(allocator, @ptrCast(@alignCast(handle.ptr))) catch null;
}

/// The mesh copied out of Manifold into `allocator`'s memory; on failure nothing stays
/// allocated (the vertices used to leak when the triangles' allocation failed).
fn copyMesh(allocator: std.mem.Allocator, obj: *manifold.ManifoldObj) !geom.Mesh {
    const mesh_mem = manifold.allocMeshGL();
    defer manifold.deleteMeshGL(mesh_mem);
    const mesh = manifold.getMeshGL(mesh_mem, obj) orelse return error.MeshUnavailable;
    // An empty solid has nothing to copy, and copying it is undefined behaviour: the C
    // binding memcpy's from the vector's data pointer, null for an empty vector on Linux,
    // which UBSan traps (CI aborted exporting the empty Solid; macOS never saw it).
    const vert_props = try allocator.alloc(f32, manifold.meshGLVertPropertiesLength(mesh));
    errdefer allocator.free(vert_props);
    if (vert_props.len > 0) _ = manifold.meshGLVertProperties(vert_props.ptr, mesh);
    const tri_verts = try allocator.alloc(u32, manifold.meshGLTriLength(mesh));
    if (tri_verts.len > 0) _ = manifold.meshGLTriVerts(tri_verts.ptr, mesh);
    return .{ .vert_props = vert_props, .tri_verts = tri_verts, .num_prop = manifold.meshGLNumProp(mesh) };
}

fn numVertsImpl(handle: geom.GeometryHandle) usize {
    std.debug.assert(handle.engine == .manifold);
    return manifold.numVert(@ptrCast(@alignCast(handle.ptr)));
}

fn numTrisImpl(handle: geom.GeometryHandle) ?usize {
    std.debug.assert(handle.engine == .manifold);
    return manifold.numTri(@ptrCast(@alignCast(handle.ptr)));
}

// --- Copies ---

fn cloneImpl(a: geom.GeometryHandle) ?geom.GeometryHandle {
    std.debug.assert(a.engine == .manifold);
    const ptr = manifold.copy(@ptrCast(@alignCast(a.ptr))) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

fn cloneCrossSectionImpl(a: geom.CrossSectionHandle) ?geom.CrossSectionHandle {
    std.debug.assert(a.engine == .manifold);
    const ptr = manifold.crossSectionCopy(@ptrCast(@alignCast(a.ptr))) orelse return null;
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

    // Pass the material slot through the C-FFI opaque pointer (0 would mean "default").
    const ctx: ?*anyopaque = @ptrFromInt(@as(usize, kernel.materialSlot(material_id)));
    const ptr = manifold.setProperties(@ptrCast(@alignCast(a.ptr)), 1, materialPropFunc, ctx) orelse return null;
    return geom.GeometryHandle{ .engine = .manifold, .ptr = @ptrCast(ptr) };
}

// --- Static Dispatch Table ---

/// Why Manifold flagged `a` as invalid (non-manifold input, non-finite vertices, ...),
/// or null if it is a valid solid.
fn problemImpl(a: geom.GeometryHandle) ?[]const u8 {
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
    pub const emptyFn = emptyImpl;
    pub const emptySketchFn = emptySketchImpl;
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
    pub const crossSectionBooleanFn = crossSectionBooleanImpl;
    pub const crossSectionHullFn = crossSectionHullImpl;
    pub const genusFn = genusImpl;
    pub const minkowskiFn = minkowskiImpl;
    pub const erodeFn = erodeImpl;
    pub const offsetFn = offsetImpl;
    pub const transformMatrixFn = transformMatrixImpl;
    pub const crossSectionTransformFn = crossSectionTransformImpl;
    pub const boundingBoxFn = boundingBoxImpl;
    pub const crossSectionAreaFn = crossSectionAreaImpl;
    pub const crossSectionBoundsFn = crossSectionBoundsImpl;
    pub const crossSectionNumVertsFn = crossSectionNumVertsImpl;
    pub const crossSectionContoursFn = crossSectionContoursImpl;
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
