const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");
const booleans = @import("booleans.zig");
const locus_bool2d = @import("booleans_2d.zig");
const tessellate = @import("tessellate.zig");
const sweeps = @import("sweeps.zig");
const minkowski = @import("minkowski.zig");
const transforms = @import("transforms.zig");
const locus_slicing = @import("slicing.zig");
const math = @import("math.zig");

pub const FfiMesh = struct {
    vertex_ptr: [*]const f32,
    vertex_len: usize,
    index_ptr: [*]const u32,
    index_len: usize,
};

pub const GeometryHandle = usize;

pub const BoundingBox = struct {
    min: [3]f64,
    max: [3]f64,
};

var g_allocator: std.mem.Allocator = undefined;
var g_topo_arena: topo.TopologyArena = undefined;
var g_geom_arena: geom.GeometryArena = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
    g_topo_arena = topo.TopologyArena.init(allocator);
    g_geom_arena = geom.GeometryArena.init(allocator);
}

pub fn deinit() void {
    g_topo_arena.deinit(g_allocator);
    g_geom_arena.deinit(g_allocator);
}

fn cubeImpl(x: f64, y: f64, z: f64, center: bool) ?GeometryHandle {
    const solid_id = generators.generateCube(g_allocator, &g_topo_arena, &g_geom_arena, x, y, z, center) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn cylinderImpl(radius: f64, height: f64, center: bool) ?GeometryHandle {
    const solid_id = generators.generateCylinder(g_allocator, &g_topo_arena, &g_geom_arena, radius, height, center) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn sphereImpl(radius: f64) ?GeometryHandle {
    const solid_id = generators.generateSphere(g_allocator, &g_topo_arena, &g_geom_arena, radius) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn extrudeImpl(base: GeometryHandle, vx: f64, vy: f64, vz: f64) ?GeometryHandle {
    const solid_id = sweeps.extrudeFace(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.FaceId, @intCast(base)), .{ vx, vy, vz }) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn translateImpl(shape: GeometryHandle, x: f64, y: f64, z: f64) ?GeometryHandle {
    const solid_id = transforms.translateSolid(
        g_allocator,
        &g_topo_arena,
        &g_geom_arena,
        @as(topo.SolidId, @intCast(shape)),
        x,
        y,
        z,
    ) catch return null;

    return @as(GeometryHandle, solid_id);
}

fn transformMatrixImpl(shape: GeometryHandle, mat: [12]f64) ?GeometryHandle {
    const solid_id = transforms.transformMatrixSolid(
        g_allocator,
        &g_topo_arena,
        &g_geom_arena,
        @as(topo.SolidId, @intCast(shape)),
        mat,
    ) catch return null;

    return @as(GeometryHandle, solid_id);
}

fn booleanImpl(a: GeometryHandle, b: GeometryHandle, op_type: u8) ?GeometryHandle {
    const op = switch (op_type) {
        0 => booleans.BooleanOp.union_op,
        1 => booleans.BooleanOp.difference,
        else => booleans.BooleanOp.intersection,
    };
    const mock_config = .{};
    const solid_id = booleans.computeBoolean(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(a)), @as(topo.SolidId, @intCast(b)), op, mock_config) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn minkowskiImpl(a: GeometryHandle, b: GeometryHandle) ?GeometryHandle {
    const solid_id = minkowski.minkowskiSumConvex(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(a)), @as(topo.SolidId, @intCast(b))) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn containsPointImpl(shape: GeometryHandle, pt: [3]f64) bool {
    return booleans.isPointInsideSolid(&g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), pt);
}

fn boundingBoxImpl(shape: GeometryHandle) ?BoundingBox {
    var min = [_]f64{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var max = [_]f64{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    var found = false;

    const solid_id: topo.SolidId = @intCast(shape);
    if (solid_id >= g_topo_arena.solids.items.len) return null;

    const s = g_topo_arena.solids.items[solid_id];
    for (0..s.shells_len) |s_off| {
        const shell = g_topo_arena.shells.items[g_topo_arena.solid_shells.items[s.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face = g_topo_arena.faces.items[g_topo_arena.shell_faces.items[shell.faces_start + f_off]];
            for (0..face.loops_len) |l_off| {
                const loop = g_topo_arena.loops.items[g_topo_arena.face_loops.items[face.loops_start + l_off]];
                var curr_he = loop.first_half_edge;
                while (true) {
                    const he = g_topo_arena.half_edges.items[curr_he];
                    const pt = g_topo_arena.vertices.items[he.start_vertex].point;
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
    return BoundingBox{ .min = min, .max = max };
}

fn volumeImpl(shape: GeometryHandle) f64 {
    var mesh = tessellate.Mesh{};
    const mock_config = .{};
    tessellate.tessellateSolid(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), &mesh, mock_config) catch return 0.0;
    defer mesh.deinit(g_allocator);

    var vol: f64 = 0.0;
    for (mesh.triangles.items) |t| {
        const p0 = mesh.vertices.items[t[0]];
        const p1 = mesh.vertices.items[t[1]];
        const p2 = mesh.vertices.items[t[2]];

        const cross_x = p1[1] * p2[2] - p1[2] * p2[1];
        const cross_y = p1[2] * p2[0] - p1[0] * p2[2];
        const cross_z = p1[0] * p2[1] - p1[1] * p2[0];

        vol += (p0[0] * cross_x + p0[1] * cross_y + p0[2] * cross_z) / 6.0;
    }
    return @abs(vol);
}

fn surfaceAreaImpl(shape: GeometryHandle) f64 {
    var mesh = tessellate.Mesh{};
    const mock_config = .{};
    tessellate.tessellateSolid(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), &mesh, mock_config) catch return 0.0;
    defer mesh.deinit(g_allocator);

    var area: f64 = 0.0;
    for (mesh.triangles.items) |t| {
        const p0 = mesh.vertices.items[t[0]];
        const p1 = mesh.vertices.items[t[1]];
        const p2 = mesh.vertices.items[t[2]];

        const v1x = p1[0] - p0[0];
        const v1y = p1[1] - p0[1];
        const v1z = p1[2] - p0[2];

        const v2x = p2[0] - p0[0];
        const v2y = p2[1] - p0[1];
        const v2z = p2[2] - p0[2];

        const cx = v1y * v2z - v1z * v2y;
        const cy = v1z * v2x - v1x * v2z;
        const cz = v1x * v2y - v1y * v2x;

        area += 0.5 * @sqrt(cx * cx + cy * cy + cz * cz);
    }
    return area;
}

fn getMeshImpl(shape: GeometryHandle) ?FfiMesh {
    var mesh = tessellate.Mesh{};
    const mock_config = .{};

    tessellate.tessellateSolid(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), &mesh, mock_config) catch return null;
    defer mesh.deinit(g_allocator);

    return FfiMesh{
        .vertex_ptr = undefined,
        .vertex_len = mesh.vertices.items.len * 3,
        .index_ptr = undefined,
        .index_len = mesh.triangles.items.len * 3,
    };
}

fn trimByPlaneImpl(shape: GeometryHandle, nx: f64, ny: f64, nz: f64, offset: f64) ?GeometryHandle {
    const solid_id = locus_slicing.trimByPlane(g_allocator, &g_topo_arena, &g_geom_arena, @as(topo.SolidId, @intCast(shape)), nx, ny, nz, offset) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn squareImpl(x: f64, y: f64, center: bool) ?GeometryHandle {
    const solid_id = generators.generateSquare(g_allocator, &g_topo_arena, &g_geom_arena, x, y, center) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn polyhedronImpl(allocator: std.mem.Allocator, pts: []const [3]f64, faces: []const [3]u32) ?GeometryHandle {
    const solid_id = generators.buildPolyhedron(allocator, &g_topo_arena, &g_geom_arena, pts, faces) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn revolveImpl(cs: GeometryHandle, segments: i32, degrees: f64) ?GeometryHandle {
    const solid_id = sweeps.revolveFace(g_allocator, &g_topo_arena, &g_geom_arena, &g_topo_arena, // Test mock uses the same arena for 2D and 3D
        @as(topo.FaceId, @intCast(cs)), // <-- Cast to FaceId instead of SolidId
        @as(u32, @intCast(segments)), degrees) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn crossSectionTransformImpl(shape: GeometryHandle, mat: [6]f64) ?GeometryHandle {
    const mat3d = [12]f64{
        mat[0], mat[1], 0.0, mat[2],
        mat[3], mat[4], 0.0, mat[5],
        0.0,    0.0,    1.0, 0.0,
    };
    const solid_id = transforms.transformMatrixSolid(g_allocator, &g_topo_arena, &g_geom_arena, @intCast(shape), mat3d) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn crossSectionBooleanImpl(a: GeometryHandle, b: GeometryHandle, op_type: u8) ?GeometryHandle {
    const op = switch (op_type) {
        0 => booleans.BooleanOp.union_op,
        1 => booleans.BooleanOp.difference,
        else => booleans.BooleanOp.intersection,
    };
    const solid_id = locus_bool2d.crossSectionBoolean(g_allocator, &g_topo_arena, &g_geom_arena, @intCast(a), @intCast(b), op) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn offsetImpl(cs: GeometryHandle, delta: f64) ?GeometryHandle {
    const solid_id: topo.SolidId = @intCast(cs);
    const s = g_topo_arena.solids.items[solid_id];
    const shell = g_topo_arena.shells.items[g_topo_arena.solid_shells.items[s.shells_start]];
    const face_id = g_topo_arena.shell_faces.items[shell.faces_start];
    const face = g_topo_arena.faces.items[face_id];
    const loop = g_topo_arena.loops.items[g_topo_arena.face_loops.items[face.loops_start]];

    var curr = loop.first_half_edge;
    while (true) {
        const he = g_topo_arena.half_edges.items[curr];
        const prev_he = g_topo_arena.half_edges.items[he.prev];

        const pt = g_topo_arena.vertices.items[he.start_vertex].point;
        const prev_pt = g_topo_arena.vertices.items[prev_he.start_vertex].point;
        const next_pt = g_topo_arena.vertices.items[g_topo_arena.half_edges.items[he.next].start_vertex].point;

        const t1 = math.normalize(math.sub(pt, prev_pt));
        const t2 = math.normalize(math.sub(next_pt, pt));
        const n1 = math.Vec3{ t1[1], -t1[0], 0 };
        const n2 = math.Vec3{ t2[1], -t2[0], 0 };

        const bisector = math.normalize(math.add(n1, n2));
        const dot = math.dot(bisector, n1);

        if (@abs(dot) > 1e-4) {
            const expand_dist = delta / dot;
            g_topo_arena.vertices.items[he.start_vertex].point = math.add(pt, math.scale(bisector, expand_dist));
        }
        curr = he.next;
        if (curr == loop.first_half_edge) break;
    }
    return cs;
}

fn mirrorImpl(shape: GeometryHandle, nx: f64, ny: f64, nz: f64) ?GeometryHandle {
    const len = @sqrt(nx * nx + ny * ny + nz * nz);
    if (len < 1e-12) return shape;
    const n = [3]f64{ nx / len, ny / len, nz / len };

    const mat = [12]f64{
        1.0 - 2.0 * n[0] * n[0], -2.0 * n[0] * n[1],      -2.0 * n[0] * n[2],      0.0,
        -2.0 * n[1] * n[0],      1.0 - 2.0 * n[1] * n[1], -2.0 * n[1] * n[2],      0.0,
        -2.0 * n[2] * n[0],      -2.0 * n[2] * n[1],      1.0 - 2.0 * n[2] * n[2], 0.0,
    };

    const solid_id = transforms.transformMatrixSolid(g_allocator, &g_topo_arena, &g_geom_arena, @intCast(shape), mat) catch return null;

    // Mirroring flips chirality. Invert face orientation to keep normals outward!
    const s = g_topo_arena.solids.items[solid_id];
    for (0..s.shells_len) |s_off| {
        const shell = g_topo_arena.shells.items[g_topo_arena.solid_shells.items[s.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face_id = g_topo_arena.shell_faces.items[shell.faces_start + f_off];
            g_topo_arena.faces.items[face_id].forward = !g_topo_arena.faces.items[face_id].forward;
        }
    }
    return @as(GeometryHandle, solid_id);
}

fn polygonsEvenOddImpl(allocator: std.mem.Allocator, contours: []const []const [2]f64) ?GeometryHandle {
    const solid_id = generators.generatePolygonsEvenOdd(allocator, &g_topo_arena, &g_geom_arena, contours) catch return null;
    return @as(GeometryHandle, solid_id);
}

fn queryFacesImpl(allocator: std.mem.Allocator, handle: GeometryHandle, direction: [3]f64, tolerance: f64) ?[]geom.FaceHandle {
    const solid_id: topo.SolidId = @intCast(handle);
    if (solid_id >= g_topo_arena.solids.items.len) return null;
    const s = g_topo_arena.solids.items[solid_id];

    const norm_dir = math.normalize(.{ direction[0], direction[1], direction[2] });
    var max_depth: f64 = -std.math.inf(f64);
    var accum_centroid = [3]f64{ 0, 0, 0 };
    var match_count: usize = 0;

    for (0..s.shells_len) |s_off| {
        const shell = g_topo_arena.shells.items[g_topo_arena.solid_shells.items[s.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face_id = g_topo_arena.shell_faces.items[shell.faces_start + f_off];
            const face = g_topo_arena.faces.items[face_id];

            if (face.surface.surface_type != .plane) continue;
            const plane = g_geom_arena.planes.items[face.surface.index];

            var normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
            if (!face.forward) normal = math.scale(normal, -1.0);

            const alignment = math.dot(normal, norm_dir);
            if (1.0 - alignment <= tolerance) {
                var centroid = [3]f64{ 0, 0, 0 };
                var v_count: f64 = 0;
                const loop = g_topo_arena.loops.items[g_topo_arena.face_loops.items[face.loops_start]];
                var curr_he = loop.first_half_edge;
                while (true) {
                    const pt = g_topo_arena.vertices.items[g_topo_arena.half_edges.items[curr_he].start_vertex].point;
                    centroid[0] += pt[0];
                    centroid[1] += pt[1];
                    centroid[2] += pt[2];
                    v_count += 1.0;
                    curr_he = g_topo_arena.half_edges.items[curr_he].next;
                    if (curr_he == loop.first_half_edge) break;
                }
                if (v_count > 0) {
                    centroid[0] /= v_count;
                    centroid[1] /= v_count;
                    centroid[2] /= v_count;
                }

                const depth = math.dot(centroid, norm_dir);
                if (depth > max_depth + tolerance) {
                    max_depth = depth;
                    accum_centroid = centroid;
                    match_count = 1;
                } else if (@abs(depth - max_depth) <= tolerance) {
                    accum_centroid[0] += centroid[0];
                    accum_centroid[1] += centroid[1];
                    accum_centroid[2] += centroid[2];
                    match_count += 1;
                }
            }
        }
    }

    if (match_count == 0) return null;
    var faces = allocator.alloc(geom.FaceHandle, 1) catch return null;
    faces[0] = .{
        .index = 0,
        .normal = .{ norm_dir[0], norm_dir[1], norm_dir[2] },
        .centroid = .{
            accum_centroid[0] / @as(f64, @floatFromInt(match_count)),
            accum_centroid[1] / @as(f64, @floatFromInt(match_count)),
            accum_centroid[2] / @as(f64, @floatFromInt(match_count)),
        },
    };
    return faces;
}

fn rayCastImpl(alloc: std.mem.Allocator, a: GeometryHandle, o: [3]f64, e: [3]f64) ?[]geom.RayHit {
    const mesh = getMeshImpl(a) orelse return null;
    defer {
        g_allocator.free(mesh.vertex_ptr[0..mesh.vertex_len]);
        g_allocator.free(mesh.index_ptr[0..mesh.index_len]);
    }

    const ray_origin = math.Vec3{ o[0], o[1], o[2] };
    const ray_end = math.Vec3{ e[0], e[1], e[2] };
    const ray_vec = math.sub(ray_end, ray_origin);
    const ray_len = math.mag(ray_vec);
    if (ray_len < 1e-12) return null;
    const ray_dir = math.scale(ray_vec, 1.0 / ray_len);

    var hits = std.ArrayListUnmanaged(geom.RayHit).empty;
    defer hits.deinit(alloc);

    var i: usize = 0;
    while (i < mesh.index_len) : (i += 3) {
        const idx0 = mesh.index_ptr[i] * 3;
        const idx1 = mesh.index_ptr[i + 1] * 3;
        const idx2 = mesh.index_ptr[i + 2] * 3;

        const v0 = math.Vec3{ mesh.vertex_ptr[idx0], mesh.vertex_ptr[idx0 + 1], mesh.vertex_ptr[idx0 + 2] };
        const v1 = math.Vec3{ mesh.vertex_ptr[idx1], mesh.vertex_ptr[idx1 + 1], mesh.vertex_ptr[idx1 + 2] };
        const v2 = math.Vec3{ mesh.vertex_ptr[idx2], mesh.vertex_ptr[idx2 + 1], mesh.vertex_ptr[idx2 + 2] };

        const edge1 = math.sub(v1, v0);
        const edge2 = math.sub(v2, v0);
        const h_vec = math.cross(ray_dir, edge2);
        const a_det = math.dot(edge1, h_vec);

        if (a_det > -1e-8 and a_det < 1e-8) continue;

        const f = 1.0 / a_det;
        const s_vec = math.sub(ray_origin, v0);
        const u = f * math.dot(s_vec, h_vec);

        if (u < 0.0 or u > 1.0) continue;

        const q_vec = math.cross(s_vec, edge1);
        const v = f * math.dot(ray_dir, q_vec);

        if (v < 0.0 or u + v > 1.0) continue;

        const t = f * math.dot(edge2, q_vec);
        if (t > 1e-8 and t < ray_len) {
            const hit_pos = math.add(ray_origin, math.scale(ray_dir, t));
            const normal = math.normalize(math.cross(edge1, edge2));
            hits.append(alloc, .{
                .distance = t,
                .position = .{ hit_pos[0], hit_pos[1], hit_pos[2] },
                .normal = .{ normal[0], normal[1], normal[2] },
            }) catch continue;
        }
    }

    if (hits.items.len == 0) return null;

    std.mem.sort(geom.RayHit, hits.items, {}, struct {
        fn lessThan(_: void, lhs: geom.RayHit, rhs: geom.RayHit) bool {
            return lhs.distance < rhs.distance;
        }
    }.lessThan);

    return hits.toOwnedSlice(alloc) catch null;
}

fn minGapImpl(a: GeometryHandle, b: GeometryHandle, sl: f64) f64 {
    _ = sl;
    const mesh_a = getMeshImpl(a) orelse return 0.0;
    defer {
        g_allocator.free(mesh_a.vertex_ptr[0..mesh_a.vertex_len]);
        g_allocator.free(mesh_a.index_ptr[0..mesh_a.index_len]);
    }

    const mesh_b = getMeshImpl(b) orelse return 0.0;
    defer {
        g_allocator.free(mesh_b.vertex_ptr[0..mesh_b.vertex_len]);
        g_allocator.free(mesh_b.index_ptr[0..mesh_b.index_len]);
    }

    var min_dist_sq: f64 = std.math.inf(f64);
    var i: usize = 0;
    while (i < mesh_a.vertex_len) : (i += 3) {
        const pa = math.Vec3{ mesh_a.vertex_ptr[i], mesh_a.vertex_ptr[i + 1], mesh_a.vertex_ptr[i + 2] };
        var j: usize = 0;
        while (j < mesh_b.vertex_len) : (j += 3) {
            const pb = math.Vec3{ mesh_b.vertex_ptr[j], mesh_b.vertex_ptr[j + 1], mesh_b.vertex_ptr[j + 2] };
            const dist_sq = math.distSq(pa, pb);
            if (dist_sq < min_dist_sq) min_dist_sq = dist_sq;
        }
    }
    return @sqrt(min_dist_sq);
}

pub const driver = struct {
    pub const cubeFn = cubeImpl;
    pub const cylinderFn = cylinderImpl;
    pub const sphereFn = sphereImpl;
    pub const extrudeFn = extrudeImpl;
    pub const translateFn = translateImpl;
    pub const transformMatrixFn = transformMatrixImpl;
    pub const booleanFn = booleanImpl;
    pub const minkowskiFn = minkowskiImpl;
    pub const containsPointFn = containsPointImpl;
    pub const boundingBoxFn = boundingBoxImpl;
    pub const volumeFn = volumeImpl;
    pub const surfaceAreaFn = surfaceAreaImpl;
    pub const getMeshFn = getMeshImpl;
    pub const trimByPlaneFn = trimByPlaneImpl;
    pub const squareFn = squareImpl;
    pub const polyhedronFn = polyhedronImpl;
    pub const revolveFn = revolveImpl;
    pub const crossSectionTransformFn = crossSectionTransformImpl;
    pub const crossSectionBooleanFn = crossSectionBooleanImpl;
    pub const offsetFn = offsetImpl;
    pub const mirrorFn = mirrorImpl;
    pub const polygonsEvenOddFn = polygonsEvenOddImpl;
    pub const queryFacesFn = queryFacesImpl;
    pub const rayCastFn = rayCastImpl;
    pub const minGapFn = minGapImpl;
};
