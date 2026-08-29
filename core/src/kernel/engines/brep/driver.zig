const std = @import("std");
const kernel = @import("../../kernel.zig");
const geom = @import("../../geometry_handle.zig");

// Import the isolated Locus Native B-Rep Library
const locus_math = @import("../../../locus/src/math.zig");
const locus_topo = @import("../../../locus/src/topology.zig");
const locus_geom = @import("../../../locus/src/geometry.zig");
const locus_gen = @import("../../../locus/src/generators.zig");
const locus_sweeps = @import("../../../locus/src/sweeps.zig");
const locus_trans = @import("../../../locus/src/transforms.zig");
const locus_tess = @import("../../../locus/src/tessellate.zig");
const locus_mink = @import("../../../locus/src/minkowski.zig");
const locus_bool = @import("../../../locus/src/booleans.zig");
const locus_bool2d = @import("../../../locus/src/booleans_2d.zig");
const locus_merger = @import("../../../locus/src/merger.zig");
const locus_slicing = @import("../../../locus/src/slicing.zig");
const locus_qh = @import("../../../locus/src/quickhull.zig");
const locus_prop = @import("../../../locus/src/properties.zig");
const locus_insp = @import("../../../locus/src/inspection.zig");
const locus_proj = @import("../../../locus/src/projections.zig");
const locus_query = @import("../../../locus/src/queries.zig");

var backend_allocator = std.heap.page_allocator;

/// The container stored behind handle.ptr.
/// Encapsulates an isolated Locus CAD environment per geometry handle.
pub const BrepSolid = struct {
    allocator: std.mem.Allocator,
    t_arena: locus_topo.TopologyArena,
    g_arena: locus_geom.GeometryArena,
    solid_id: locus_topo.SolidId, // Doubles as FaceId for 2D cross sections

    pub fn create(allocator: std.mem.Allocator) !*BrepSolid {
        const self = try allocator.create(BrepSolid);
        self.* = .{
            .allocator = allocator,
            .t_arena = locus_topo.TopologyArena.init(allocator),
            .g_arena = locus_geom.GeometryArena.init(allocator),
            .solid_id = 0,
        };
        return self;
    }

    pub fn destroy(self: *BrepSolid) void {
        self.t_arena.deinit(self.allocator);
        self.g_arena.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn extractAllVertices(allocator: std.mem.Allocator, handles: []const geom.GeometryHandle) ![]const locus_math.Vec3 {
    var pts = std.ArrayListUnmanaged(locus_math.Vec3).empty;
    for (handles) |h| {
        if (@intFromPtr(h.ptr) == 0) continue;
        const solid: *BrepSolid = @ptrCast(@alignCast(h.ptr));
        const s = solid.t_arena.solids.items[solid.solid_id];
        for (0..s.shells_len) |s_off| {
            const shell = solid.t_arena.shells.items[solid.t_arena.solid_shells.items[s.shells_start + s_off]];
            for (0..shell.faces_len) |f_off| {
                const face_id = solid.t_arena.shell_faces.items[shell.faces_start + f_off];
                const face = solid.t_arena.faces.items[face_id];
                for (0..face.loops_len) |l_off| {
                    const loop = solid.t_arena.loops.items[solid.t_arena.face_loops.items[face.loops_start + l_off]];
                    var curr = loop.first_half_edge;
                    while (true) {
                        const he = solid.t_arena.half_edges.items[curr];
                        try pts.append(allocator, solid.t_arena.vertices.items[he.start_vertex].point);
                        curr = he.next;
                        if (curr == loop.first_half_edge) break;
                    }
                }
            }
        }
    }
    return pts.toOwnedSlice(allocator);
}

fn buildHullFromHandles(handles: []const geom.GeometryHandle) ?geom.GeometryHandle {
    const pts = extractAllVertices(backend_allocator, handles) catch return null;
    defer backend_allocator.free(pts);

    if (pts.len < 4) return null;
    const solid = BrepSolid.create(backend_allocator) catch return null;

    var builder = locus_qh.QuickhullBuilder.init(backend_allocator, pts);
    defer builder.deinit();
    builder.buildHull() catch {
        solid.destroy();
        return null;
    };

    var tris = std.ArrayListUnmanaged([3]u32).empty;
    defer tris.deinit(backend_allocator);

    for (builder.faces.items) |hull_face| {
        if (hull_face.disabled) continue;
        const he0 = builder.half_edges.items[hull_face.first_half_edge];
        const he1 = builder.half_edges.items[he0.next_edge];
        const he2 = builder.half_edges.items[he1.next_edge];
        tris.append(backend_allocator, .{ he2.end_vertex, he0.end_vertex, he1.end_vertex }) catch return null;
    }

    solid.solid_id = locus_gen.buildPolyhedron(backend_allocator, &solid.t_arena, &solid.g_arena, pts, tris.items) catch {
        solid.destroy();
        return null;
    };
    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

// --- Lifecycle Management ---

fn destructImpl(handle: geom.GeometryHandle) void {
    std.debug.assert(handle.engine == .brep_native);
    if (@intFromPtr(handle.ptr) != 0) {
        const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
        solid.destroy();
    }
}

fn destructCrossSectionImpl(handle: geom.CrossSectionHandle) void {
    std.debug.assert(handle.engine == .brep_native);
    if (@intFromPtr(handle.ptr) != 0) {
        const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
        solid.destroy();
    }
}

// --- Generator Bridges ---

fn cubeImpl(x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    const solid = BrepSolid.create(backend_allocator) catch return null;
    solid.solid_id = locus_gen.generateCube(backend_allocator, &solid.t_arena, &solid.g_arena, x, y, z, center) catch {
        solid.destroy();
        return null;
    };
    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn cylinderImpl(r1: f64, r2: f64, height: f64, center: bool, segments: i32) ?geom.GeometryHandle {
    _ = r2;
    _ = segments;
    const solid = BrepSolid.create(backend_allocator) catch return null;
    solid.solid_id = locus_gen.generateCylinder(backend_allocator, &solid.t_arena, &solid.g_arena, r1, height, center) catch {
        solid.destroy();
        return null;
    };
    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn sphereImpl(radius: f64) ?geom.GeometryHandle {
    const solid = BrepSolid.create(backend_allocator) catch return null;
    solid.solid_id = locus_gen.generateSphere(backend_allocator, &solid.t_arena, &solid.g_arena, radius) catch {
        solid.destroy();
        return null;
    };
    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn squareImpl(x: f64, y: f64, center: bool) ?geom.CrossSectionHandle {
    const solid = BrepSolid.create(backend_allocator) catch return null;
    solid.solid_id = locus_gen.generateSquare(backend_allocator, &solid.t_arena, &solid.g_arena, x, y, center) catch {
        solid.destroy();
        return null;
    };
    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn circleImpl(radius: f64, segments: i32) ?geom.CrossSectionHandle {
    const solid = BrepSolid.create(backend_allocator) catch return null;
    solid.solid_id = locus_gen.generateCircle(backend_allocator, &solid.t_arena, &solid.g_arena, radius, segments) catch {
        solid.destroy();
        return null;
    };
    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn polygonImpl(allocator: std.mem.Allocator, pts: []const [2]f64) ?geom.CrossSectionHandle {
    _ = allocator;
    const solid = BrepSolid.create(backend_allocator) catch return null;
    solid.solid_id = locus_gen.generatePolygon(backend_allocator, &solid.t_arena, &solid.g_arena, pts) catch {
        solid.destroy();
        return null;
    };
    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn polyhedronImpl(allocator: std.mem.Allocator, pts: []const [3]f64, faces: []const [3]u32) ?geom.GeometryHandle {
    _ = allocator;
    const solid = BrepSolid.create(backend_allocator) catch return null;
    solid.solid_id = locus_gen.buildPolyhedron(backend_allocator, &solid.t_arena, &solid.g_arena, pts, faces) catch {
        solid.destroy();
        return null;
    };
    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn polygonsEvenOddImpl(allocator: std.mem.Allocator, contours: []const []const [2]f64) ?geom.CrossSectionHandle {
    _ = allocator;
    const solid = BrepSolid.create(backend_allocator) catch return null;
    solid.solid_id = locus_gen.generatePolygonsEvenOdd(backend_allocator, &solid.t_arena, &solid.g_arena, contours) catch {
        solid.destroy();
        return null;
    };
    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

// --- Transformer Bridges ---

fn extrudeImpl(cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
    _ = slices;
    _ = twist_degrees;
    _ = scale_x;
    _ = scale_y;
    if (@intFromPtr(cs.ptr) == 0) return null;

    const solid: *BrepSolid = @ptrCast(@alignCast(cs.ptr));
    solid.solid_id = locus_sweeps.extrudeFace(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, .{ 0, 0, height }) catch return null;
    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn revolveImpl(cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
    if (@intFromPtr(cs.ptr) == 0) return null;
    const solid_2d: *BrepSolid = @ptrCast(@alignCast(cs.ptr));
    const revolved_solid = BrepSolid.create(backend_allocator) catch return null;

    revolved_solid.solid_id = locus_sweeps.revolveFace(backend_allocator, &revolved_solid.t_arena, &revolved_solid.g_arena, &solid_2d.t_arena, solid_2d.solid_id, @intCast(segments), revolve_degrees) catch {
        revolved_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(revolved_solid) };
}

fn translateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    solid.solid_id = locus_trans.translateSolid(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, x, y, z) catch return a;
    return a;
}

fn rotateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    solid.solid_id = locus_trans.rotateSolid(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, x, y, z) catch return a;
    return a;
}

fn scaleImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    solid.solid_id = locus_trans.scaleSolid(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, x, y, z) catch return a;
    return a;
}

fn transformMatrixImpl(a: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    solid.solid_id = locus_trans.transformMatrixSolid(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, mat) catch return a;
    return a;
}

fn crossSectionTransformImpl(cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
    if (@intFromPtr(cs.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(cs.ptr));
    const mat3d = [12]f64{
        mat[0], mat[1], 0.0, mat[2],
        mat[3], mat[4], 0.0, mat[5],
        0.0,    0.0,    1.0, 0.0,
    };
    _ = locus_trans.transformMatrixSolid(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, mat3d) catch return cs;
    return cs;
}

fn mirrorImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    solid.solid_id = locus_trans.mirrorSolid(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, nx, ny, nz) catch return a;
    return a;
}

fn offsetImpl(cs: geom.CrossSectionHandle, delta: f64, join_type: u8) ?geom.CrossSectionHandle {
    _ = join_type;
    _ = delta;
    return cs; // To be moved to locus sweeps
}

// --- Boolean Bridges ---

fn booleanImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    const solid_a: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const solid_b: *BrepSolid = @ptrCast(@alignCast(b.ptr));

    const locus_op: locus_bool.BooleanOp = switch (op) {
        .union_op => .union_op,
        .difference_op => .difference,
        .intersection_op => .intersection,
    };

    const merged_b_id = locus_merger.mergeSolidArenas(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, &solid_b.t_arena, &solid_b.g_arena, solid_b.solid_id) catch return a;
    solid_a.solid_id = locus_bool.computeBoolean(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, solid_a.solid_id, merged_b_id, locus_op, .{}) catch return a;

    return a;
}

fn batchBooleanImpl(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    _ = allocator;
    if (objs.len == 0) return null;
    var acc = objs[0];
    for (objs[1..]) |obj| {
        if (booleanImpl(acc, obj, op)) |res| {
            acc = res;
        }
    }
    return acc;
}

fn minkowskiImpl(a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
    const solid_a: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const solid_b: *BrepSolid = @ptrCast(@alignCast(b.ptr));

    const merged_b_id = locus_merger.mergeSolidArenas(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, &solid_b.t_arena, &solid_b.g_arena, solid_b.solid_id) catch return a;
    solid_a.solid_id = locus_mink.minkowskiSumConvex(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, solid_a.solid_id, merged_b_id) catch return a;

    return a;
}

fn crossSectionBooleanImpl(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: kernel.BooleanOp) ?geom.CrossSectionHandle {
    if (@intFromPtr(a.ptr) == 0 or @intFromPtr(b.ptr) == 0) return null;

    const solid_a: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const solid_b: *BrepSolid = @ptrCast(@alignCast(b.ptr));

    const locus_op: locus_bool.BooleanOp = switch (op) {
        .union_op => .union_op,
        .difference_op => .difference,
        .intersection_op => .intersection,
    };

    const merged_b_id = locus_merger.mergeSolidArenas(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, &solid_b.t_arena, &solid_b.g_arena, solid_b.solid_id) catch return a;
    solid_a.solid_id = locus_bool2d.crossSectionBoolean(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, solid_a.solid_id, merged_b_id, locus_op) catch return a;

    return a;
}

fn trimByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset: f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    solid.solid_id = locus_slicing.trimByPlane(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, nx, ny, nz, offset) catch return a;
    return a;
}

fn splitByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset: f64) geom.SolidPair {
    if (@intFromPtr(a.ptr) == 0) return .{ .first = null, .second = null };
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));

    const pair = locus_slicing.splitByPlane(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, nx, ny, nz, offset) catch return .{ .first = a, .second = null };

    solid.solid_id = pair.first;
    const solid_b = BrepSolid.create(backend_allocator) catch return .{ .first = a, .second = null };
    solid_b.t_arena = solid.t_arena;
    solid_b.g_arena = solid.g_arena;
    solid_b.solid_id = pair.second;

    return .{ .first = a, .second = geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid_b) } };
}

fn hullImpl(a: geom.GeometryHandle) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    return buildHullFromHandles(&[_]geom.GeometryHandle{a});
}

fn batchHullImpl(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle) ?geom.GeometryHandle {
    _ = allocator;
    if (objs.len == 0) return null;
    return buildHullFromHandles(objs);
}

fn decomposeImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?[]geom.GeometryHandle {
    var res = allocator.alloc(geom.GeometryHandle, 1) catch return null;
    res[0] = handle;
    return res;
}

// --- Projections & Slicing ---

fn sliceImpl(a: geom.GeometryHandle, height: f64) ?geom.CrossSectionHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const solid_3d: *BrepSolid = @ptrCast(@alignCast(a.ptr));

    var mesh = locus_tess.Mesh{};
    defer mesh.deinit(backend_allocator);
    locus_tess.tessellateSolid(backend_allocator, &solid_3d.t_arena, &solid_3d.g_arena, solid_3d.solid_id, &mesh, .{}) catch return null;

    const contours = locus_slicing.sliceMeshToContours(backend_allocator, &mesh, height) catch return null;
    defer {
        for (contours) |c| backend_allocator.free(c);
        backend_allocator.free(contours);
    }

    if (contours.len == 0) return null;

    const cs_solid = BrepSolid.create(backend_allocator) catch return null;
    cs_solid.solid_id = locus_gen.generatePolygonsEvenOdd(backend_allocator, &cs_solid.t_arena, &cs_solid.g_arena, contours) catch {
        cs_solid.destroy();
        return null;
    };

    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(cs_solid) };
}

fn projectImpl(a: geom.GeometryHandle) ?geom.CrossSectionHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const solid_3d: *BrepSolid = @ptrCast(@alignCast(a.ptr));

    const face_cs = BrepSolid.create(backend_allocator) catch return null;

    if (locus_proj.projectSolid(
        backend_allocator,
        &face_cs.t_arena,
        &face_cs.g_arena,
        &solid_3d.t_arena,
        &solid_3d.g_arena,
        solid_3d.solid_id,
    ) catch null) |cs_id| {
        face_cs.solid_id = cs_id;
        return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(face_cs) };
    }

    face_cs.destroy();
    return null;
}

// --- Properties & Diagnostics ---

fn genusImpl(handle: geom.GeometryHandle) i32 {
    if (@intFromPtr(handle.ptr) == 0) return 0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    return locus_prop.genus(&solid.t_arena, solid.solid_id);
}

fn boundingBoxImpl(handle: geom.GeometryHandle) ?geom.BoundingBox {
    if (@intFromPtr(handle.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    if (locus_prop.boundingBox(&solid.t_arena, solid.solid_id)) |bb| {
        return geom.BoundingBox{ .min = bb.min, .max = bb.max };
    }
    return null;
}

fn volumeImpl(handle: geom.GeometryHandle) f64 {
    if (@intFromPtr(handle.ptr) == 0) return 0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    return locus_prop.volume(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id);
}

fn surfaceAreaImpl(handle: geom.GeometryHandle) f64 {
    if (@intFromPtr(handle.ptr) == 0) return 0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    return locus_prop.surfaceArea(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id);
}

fn crossSectionAreaImpl(handle: geom.CrossSectionHandle) f64 {
    if (@intFromPtr(handle.ptr) == 0) return 0.0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    return locus_prop.crossSectionArea(&solid.t_arena, solid.solid_id);
}

fn crossSectionBoundsImpl(handle: geom.CrossSectionHandle) geom.Rect2D {
    if (@intFromPtr(handle.ptr) == 0) return .{ .min = .{ 0, 0 }, .max = .{ 0, 0 } };
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    const bb = locus_prop.crossSectionBounds(&solid.t_arena, solid.solid_id);
    return .{ .min = .{ bb.min[0], bb.min[1] }, .max = .{ bb.max[0], bb.max[1] } };
}

fn queryFacesImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle, direction: [3]f64, tolerance: f64) ?[]geom.FaceHandle {
    if (@intFromPtr(handle.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));

    if (locus_insp.queryFaces(allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, direction, tolerance) catch null) |l_faces| {
        var handles = allocator.alloc(geom.FaceHandle, l_faces.len) catch return null;
        for (l_faces, 0..) |f, i| {
            handles[i] = .{ .index = f.index, .normal = f.normal, .centroid = f.centroid };
        }
        allocator.free(l_faces);
        return handles;
    }
    return null;
}

fn containsPointImpl(a: geom.GeometryHandle, pt: [3]f64) bool {
    if (@intFromPtr(a.ptr) == 0) return false;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    return locus_bool.isPointInsideSolid(&solid.t_arena, &solid.g_arena, solid.solid_id, pt);
}

fn minGapImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, sl: f64) f64 {
    _ = sl;
    if (@intFromPtr(a.ptr) == 0 or @intFromPtr(b.ptr) == 0) return 0.0;

    const solid_a: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const solid_b: *BrepSolid = @ptrCast(@alignCast(b.ptr));

    var mesh_a = locus_tess.Mesh{};
    defer mesh_a.deinit(backend_allocator);
    var mesh_b = locus_tess.Mesh{};
    defer mesh_b.deinit(backend_allocator);

    // Tessellate locally because the two handles have strictly isolated GeometryArenas
    locus_tess.tessellateSolid(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, solid_a.solid_id, &mesh_a, .{}) catch return 0.0;
    locus_tess.tessellateSolid(backend_allocator, &solid_b.t_arena, &solid_b.g_arena, solid_b.solid_id, &mesh_b, .{}) catch return 0.0;

    var min_dist_sq: f64 = std.math.inf(f64);
    for (mesh_a.vertices.items) |pa| {
        for (mesh_b.vertices.items) |pb| {
            const dist_sq = locus_math.distSq(pa, pb);
            if (dist_sq < min_dist_sq) min_dist_sq = dist_sq;
        }
    }
    return @sqrt(min_dist_sq);
}

fn rayCastImpl(alloc: std.mem.Allocator, a: geom.GeometryHandle, o: [3]f64, e: [3]f64) ?[]geom.RayHit {
    if (@intFromPtr(a.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));

    if (locus_query.rayCast(alloc, &solid.t_arena, &solid.g_arena, solid.solid_id, o, e) catch null) |hits| {
        var mapped = alloc.alloc(geom.RayHit, hits.len) catch return null;
        for (hits, 0..) |h, i| mapped[i] = .{ .distance = h.distance, .position = h.position, .normal = h.normal };
        alloc.free(hits);
        return mapped;
    }
    return null;
}

fn getMeshImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh {
    std.debug.assert(handle.engine == .brep_native);
    if (@intFromPtr(handle.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));

    var mesh = locus_tess.Mesh{};
    defer mesh.deinit(backend_allocator);

    locus_tess.tessellateSolid(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, &mesh, .{}) catch return null;

    var vert_props = allocator.alloc(f32, mesh.vertices.items.len * 3) catch return null;
    for (mesh.vertices.items, 0..) |v, i| {
        vert_props[i * 3 + 0] = @floatCast(v[0]);
        vert_props[i * 3 + 1] = @floatCast(v[1]);
        vert_props[i * 3 + 2] = @floatCast(v[2]);
    }

    var tri_verts = allocator.alloc(u32, mesh.triangles.items.len * 3) catch return null;
    for (mesh.triangles.items, 0..) |t, i| {
        tri_verts[i * 3 + 0] = t[0];
        tri_verts[i * 3 + 1] = t[1];
        tri_verts[i * 3 + 2] = t[2];
    }

    return geom.Mesh{
        .vert_props = vert_props,
        .tri_verts = tri_verts,
        .num_prop = 3,
    };
}

fn simplifyImpl(a: geom.GeometryHandle, tolerance: f64) ?geom.GeometryHandle {
    _ = tolerance;
    return a;
}

fn setMaterialImpl(a: geom.GeometryHandle, material_id: u32) ?geom.GeometryHandle {
    _ = material_id;
    return a;
}

pub const driver = kernel.GeometryKernel{
    .cubeFn = cubeImpl,
    .cylinderFn = cylinderImpl,
    .sphereFn = sphereImpl,
    .booleanFn = booleanImpl,
    .batchBooleanFn = batchBooleanImpl,
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
    .batchHullFn = batchHullImpl,
    .decomposeFn = decomposeImpl,
    .trimByPlaneFn = trimByPlaneImpl,
    .splitByPlaneFn = splitByPlaneImpl,
    .crossSectionBooleanFn = crossSectionBooleanImpl,
    .genusFn = genusImpl,
    .transformMatrixFn = transformMatrixImpl,
    .minkowskiFn = minkowskiImpl,
    .offsetFn = offsetImpl,
    .crossSectionTransformFn = crossSectionTransformImpl,
    .boundingBoxFn = boundingBoxImpl,
    .crossSectionAreaFn = crossSectionAreaImpl,
    .crossSectionBoundsFn = crossSectionBoundsImpl,
    .queryFacesFn = queryFacesImpl,
    .volumeFn = volumeImpl,
    .surfaceAreaFn = surfaceAreaImpl,
    .getMeshFn = getMeshImpl,
    .containsPointFn = containsPointImpl,
    .minGapFn = minGapImpl,
    .rayCastFn = rayCastImpl,
    .polygonFn = polygonImpl,
    .simplifyFn = simplifyImpl,
    .destructFn = destructImpl,
    .destructCrossSectionFn = destructCrossSectionImpl,
    .setMaterialFn = setMaterialImpl,
};
