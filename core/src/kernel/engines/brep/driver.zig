const std = @import("std");
const kernel = @import("../../kernel.zig");
const geom = @import("../../geometry_handle.zig");

// Import the isolated Locus Native B-Rep Library
const locus_topo = @import("../../../locus/src/topology.zig");
const locus_geom = @import("../../../locus/src/geometry.zig");
const locus_gen = @import("../../../locus/src/generators.zig");
const locus_sweeps = @import("../../../locus/src/sweeps.zig");
const locus_trans = @import("../../../locus/src/transforms.zig");
const locus_tess = @import("../../../locus/src/tessellate.zig");
const locus_mink = @import("../../../locus/src/minkowski.zig");
const locus_bool = @import("../../../locus/src/booleans.zig");
const locus_merger = @import("../../../locus/src/merger.zig");
const locus_slicing = @import("../../../locus/src/slicing.zig");

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
        // Explicitly pass allocator to match updated Unmanaged arena deinit API
        self.t_arena.deinit(self.allocator);
        self.g_arena.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

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
    // Pass backend_allocator as first parameter to half-edge generator
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

// --- Transformer Bridges ---

fn extrudeImpl(cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
    _ = slices;
    _ = twist_degrees;
    _ = scale_x;
    _ = scale_y;
    if (@intFromPtr(cs.ptr) == 0) return null;

    const solid: *BrepSolid = @ptrCast(@alignCast(cs.ptr));
    // Pass backend_allocator as first parameter to extrudeFace
    solid.solid_id = locus_sweeps.extrudeFace(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, .{ 0, 0, height }) catch return null;

    // Convert 2D CrossSectionHandle to 3D GeometryHandle
    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
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

fn booleanImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    const solid_a: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const solid_b: *BrepSolid = @ptrCast(@alignCast(b.ptr));

    const locus_op: locus_bool.BooleanOp = switch (op) {
        .union_op => .union_op,
        .difference_op => .difference,
        .intersection_op => .intersection,
    };

    // Phase 1: Merge B into A's Arena
    const merged_b_id = locus_merger.mergeSolidArenas(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, &solid_b.t_arena, &solid_b.g_arena, solid_b.solid_id) catch return a;

    // Phase 2 & 3: Compute Boolean CSG using the unified half-edge arena
    solid_a.solid_id = locus_bool.computeBoolean(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, solid_a.solid_id, merged_b_id, locus_op, .{}) catch return a;

    return a;
}

fn batchBooleanImpl(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    _ = allocator;
    if (objs.len == 0) return null;

    // Fallback for B-Rep: Sequential evaluation
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

    // Phase 1: Merge B into A's Arena
    const merged_b_id = locus_merger.mergeSolidArenas(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, &solid_b.t_arena, &solid_b.g_arena, solid_b.solid_id) catch return a;

    // Phase 2: Compute Minkowski Sum
    solid_a.solid_id = locus_mink.minkowskiSumConvex(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, solid_a.solid_id, merged_b_id) catch return a;

    return a;
}

// --- Tessellation Bridge ---

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

// --- Stubbed / Unimplemented V-Table Endpoints ---

fn polyhedronImpl(allocator: std.mem.Allocator, pts: []const [3]f64, faces: []const [3]u32) ?geom.GeometryHandle {
    _ = allocator;
    _ = pts;
    _ = faces;
    return null;
}
fn polygonsEvenOddImpl(allocator: std.mem.Allocator, contours: []const []const [2]f64) ?geom.CrossSectionHandle {
    _ = allocator;
    _ = contours;
    return null;
}
fn revolveImpl(cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
    _ = cs;
    _ = segments;
    _ = revolve_degrees;
    return null;
}
fn sliceImpl(a: geom.GeometryHandle, height: f64) ?geom.CrossSectionHandle {
    _ = a;
    _ = height;
    return null;
}
fn projectImpl(a: geom.GeometryHandle) ?geom.CrossSectionHandle {
    _ = a;
    return null;
}
fn mirrorImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle {
    _ = a;
    _ = nx;
    _ = ny;
    _ = nz;
    return null;
}
fn hullImpl(a: geom.GeometryHandle) ?geom.GeometryHandle {
    _ = a;
    return null;
}
fn batchHullImpl(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle) ?geom.GeometryHandle {
    _ = allocator;
    _ = objs;
    // B-Rep Convex Hulls require a dedicated solver (e.g. QuickHull3D). Stubbed for now.
    return null;
}

fn decomposeImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?[]geom.GeometryHandle {
    // Basic fallback: Return the solid itself as a single-item array
    var res = allocator.alloc(geom.GeometryHandle, 1) catch return null;
    res[0] = handle;
    return res;
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

    // We update the original handle to point to the first half
    solid.solid_id = pair.first;

    // We must instantiate a completely new handle/wrapper for the second half
    const solid_b = BrepSolid.create(backend_allocator) catch return .{ .first = a, .second = null };

    // Transfer the result topology into the new wrapper (by copying the arena state)
    solid_b.t_arena = solid.t_arena; // Note: In a production app, we would deep-clone the arena or extract the subgraph here
    solid_b.g_arena = solid.g_arena;
    solid_b.solid_id = pair.second;

    return .{ .first = a, .second = geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid_b) } };
}

fn crossSectionBooleanImpl(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: kernel.BooleanOp) ?geom.CrossSectionHandle {
    _ = a;
    _ = b;
    _ = op;
    return null;
}

fn transformMatrixImpl(a: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    solid.solid_id = locus_trans.transformMatrixSolid(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, mat) catch return a;
    return a;
}

fn crossSectionTransformImpl(cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
    _ = cs;
    _ = mat;
    return null;
}
fn genusImpl(handle: geom.GeometryHandle) i32 {
    if (@intFromPtr(handle.ptr) == 0) return 0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));

    // Euler Formula: V - E + F = 2(1 - g)
    const v = @as(i32, @intCast(solid.t_arena.vertices.items.len));
    const e = @as(i32, @intCast(solid.t_arena.half_edges.items.len / 2));
    const f = @as(i32, @intCast(solid.t_arena.faces.items.len));

    const euler = v - e + f;
    return @divTrunc(2 - euler, 2);
}

fn boundingBoxImpl(handle: geom.GeometryHandle) ?geom.BoundingBox {
    if (@intFromPtr(handle.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));

    var min = [_]f64{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var max = [_]f64{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    var found = false;

    // Traverse the Half-Edge graph to find all active vertices in this solid
    const s = solid.t_arena.solids.items[solid.solid_id];
    for (0..s.shells_len) |s_off| {
        const shell = solid.t_arena.shells.items[solid.t_arena.solid_shells.items[s.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face = solid.t_arena.faces.items[solid.t_arena.shell_faces.items[shell.faces_start + f_off]];
            for (0..face.loops_len) |l_off| {
                const loop = solid.t_arena.loops.items[solid.t_arena.face_loops.items[face.loops_start + l_off]];
                var curr_he = loop.first_half_edge;
                while (true) {
                    const he = solid.t_arena.half_edges.items[curr_he];
                    const pt = solid.t_arena.vertices.items[he.start_vertex].point;
                    for (0..3) |i| {
                        if (pt[i] < min[i]) min[i] = pt[i];
                        if (pt[i] > max[i]) max[i] = pt[i];
                    }
                    found = true;
                    curr_he = he.next;
                    if (curr_he == loop.first_half_edge) break;
                }
            }
        }
    }
    if (!found) return null;
    return geom.BoundingBox{ .min = min, .max = max };
}

fn queryFacesImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle, direction: [3]f64, tolerance: f64) ?[]geom.FaceHandle {
    _ = allocator;
    _ = handle;
    _ = direction;
    _ = tolerance;
    return null;
}

fn volumeImpl(handle: geom.GeometryHandle) f64 {
    const mesh = getMeshImpl(backend_allocator, handle) orelse return 0.0;
    defer backend_allocator.free(mesh.vert_props);
    defer backend_allocator.free(mesh.tri_verts);

    var vol: f64 = 0.0;
    var i: usize = 0;
    // Divergence Theorem: Sum of (P0 dot (P1 cross P2)) / 6.0
    while (i < mesh.tri_verts.len) : (i += 3) {
        const idx0 = mesh.tri_verts[i] * 3;
        const idx1 = mesh.tri_verts[i + 1] * 3;
        const idx2 = mesh.tri_verts[i + 2] * 3;

        const p0 = [_]f64{ mesh.vert_props[idx0], mesh.vert_props[idx0 + 1], mesh.vert_props[idx0 + 2] };
        const p1 = [_]f64{ mesh.vert_props[idx1], mesh.vert_props[idx1 + 1], mesh.vert_props[idx1 + 2] };
        const p2 = [_]f64{ mesh.vert_props[idx2], mesh.vert_props[idx2 + 1], mesh.vert_props[idx2 + 2] };

        const cross_x = p1[1] * p2[2] - p1[2] * p2[1];
        const cross_y = p1[2] * p2[0] - p1[0] * p2[2];
        const cross_z = p1[0] * p2[1] - p1[1] * p2[0];

        vol += (p0[0] * cross_x + p0[1] * cross_y + p0[2] * cross_z) / 6.0;
    }
    return @abs(vol);
}

fn surfaceAreaImpl(handle: geom.GeometryHandle) f64 {
    const mesh = getMeshImpl(backend_allocator, handle) orelse return 0.0;
    defer backend_allocator.free(mesh.vert_props);
    defer backend_allocator.free(mesh.tri_verts);

    var area: f64 = 0.0;
    var i: usize = 0;
    // Area of a triangle is half the magnitude of the cross product of two edges
    while (i < mesh.tri_verts.len) : (i += 3) {
        const idx0 = mesh.tri_verts[i] * 3;
        const idx1 = mesh.tri_verts[i + 1] * 3;
        const idx2 = mesh.tri_verts[i + 2] * 3;

        const v1x = mesh.vert_props[idx1] - mesh.vert_props[idx0];
        const v1y = mesh.vert_props[idx1 + 1] - mesh.vert_props[idx0 + 1];
        const v1z = mesh.vert_props[idx1 + 2] - mesh.vert_props[idx0 + 2];

        const v2x = mesh.vert_props[idx2] - mesh.vert_props[idx0];
        const v2y = mesh.vert_props[idx2 + 1] - mesh.vert_props[idx0 + 1];
        const v2z = mesh.vert_props[idx2 + 2] - mesh.vert_props[idx0 + 2];

        const cx = v1y * v2z - v1z * v2y;
        const cy = v1z * v2x - v1x * v2z;
        const cz = v1x * v2y - v1y * v2x;

        area += 0.5 * @sqrt(cx * cx + cy * cy + cz * cz);
    }
    return area;
}

fn containsPointImpl(a: geom.GeometryHandle, pt: [3]f64) bool {
    if (@intFromPtr(a.ptr) == 0) return false;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    // Wire directly into our Boolean raycaster
    return locus_bool.isPointInsideSolid(&solid.t_arena, &solid.g_arena, solid.solid_id, pt);
}

fn minGapImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, sl: f64) f64 {
    _ = a;
    _ = b;
    _ = sl;
    return 0.0;
}
fn offsetImpl(cs: geom.CrossSectionHandle, delta: f64, join_type: u8) ?geom.CrossSectionHandle {
    _ = cs;
    _ = delta;
    _ = join_type;
    return null;
}
fn rayCastImpl(alloc: std.mem.Allocator, a: geom.GeometryHandle, o: [3]f64, e: [3]f64) ?[]geom.RayHit {
    _ = alloc;
    _ = a;
    _ = o;
    _ = e;
    return null;
}
fn simplifyImpl(a: geom.GeometryHandle, tolerance: f64) ?geom.GeometryHandle {
    _ = tolerance;
    std.debug.assert(a.engine == .brep_native);
    return a;
}
fn setMaterialImpl(a: geom.GeometryHandle, material_id: u32) ?geom.GeometryHandle {
    _ = a;
    _ = material_id;
    return null;
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
