const std = @import("std");
const kernel = @import("../../kernel.zig");
const geom = @import("../../geometry_handle.zig");
const engine_config = @import("../../../core/engine_config.zig");

// --- DoD Locus Native B-Rep Library Imports ---
const locus_math = @import("../../../locus/src/math.zig");
const locus_env = @import("../../../locus/src/math_env.zig");
const locus_topo_types = @import("../../../locus/src/topology/types.zig");
const locus_topo_arena = @import("../../../locus/src/topology/arena.zig");
const locus_geom_arena = @import("../../../locus/src/geometry/arena.zig");

// --- Locus Operations ---
const locus_gen = @import("../../../locus/src/operations/generators.zig");
const locus_sweeps = @import("../../../locus/src/operations/sweeps.zig");
const locus_trans = @import("../../../locus/src/operations/transforms.zig");
const locus_tess = @import("../../../locus/src/operations/tessellate.zig");
const locus_mink = @import("../../../locus/src/operations/minkowski.zig");
const locus_bool = @import("../../../locus/src/operations/booleans.zig");
const locus_bool2d = @import("../../../locus/src/operations/booleans_2d.zig");
const locus_slicing = @import("../../../locus/src/operations/slicing.zig");
const locus_qh = @import("../../../locus/src/operations/quickhull.zig");
const locus_prop = @import("../../../locus/src/operations/properties.zig");
const locus_insp = @import("../../../locus/src/operations/inspection.zig");
const locus_proj = @import("../../../locus/src/operations/projections.zig");
const locus_query = @import("../../../locus/src/operations/queries.zig");
const locus_step = @import("../../../locus/src/operations/step_export.zig");

/// What Locus allocates its working data and solids with. The driver interface carries no
/// allocator (Locus is unfinished), so this is libc's general-purpose allocator: it was
/// std.heap.page_allocator, which gives every allocation, however small, its own pages.
const backend_allocator = std.heap.c_allocator;

/// Directions count as parallel when 1 - |cos θ| is at most this (θ ≈ 0.8°).
const ANGULAR_TOLERANCE: f64 = 1e-4;

pub const BrepSolid = struct {
    allocator: std.mem.Allocator,
    /// The settings the solid was built under (CAD.config); every solid made from it
    /// keeps them, so a whole model is computed with one tolerance.
    env: locus_env.MathEnv,
    t_arena: locus_topo_arena.TopologyArena,
    g_arena: locus_geom_arena.GeometryArena,
    solid_id: locus_topo_types.SolidIndex,

    pub fn create(allocator: std.mem.Allocator, env: locus_env.MathEnv) !*BrepSolid {
        const self = try allocator.create(BrepSolid);
        self.* = .{
            .allocator = allocator,
            .env = env,
            .t_arena = locus_topo_arena.TopologyArena.init(),
            .g_arena = locus_geom_arena.GeometryArena.init(),
            .solid_id = @fromBackingInt(0),
        };
        return self;
    }

    pub fn destroy(self: *BrepSolid) void {
        self.t_arena.deinit(self.allocator);
        self.g_arena.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// The Locus settings for solids built under `config`. Every distance tolerance follows
/// the one `tolerance`; the angular one compares unit directions, so it doesn't scale with
/// the model and stays fixed.
pub fn mathEnv(config: *const engine_config.EngineConfig) locus_env.MathEnv {
    return .init(.{
        .vertex_tolerance = config.tolerance,
        .sewing_tolerance = config.tolerance,
        .parametric_tolerance = config.tolerance,
        .angular_tolerance = ANGULAR_TOLERANCE,
        .max_newton_trials = config.brep.max_newton_trials,
        .max_marching_steps = config.brep.max_marching_steps,
        .resolution = config.resolution,
    });
}

pub fn exportStep(allocator: std.mem.Allocator, handles: []const geom.GeometryHandle) ![]const u8 {
    var step_solids = std.ArrayListUnmanaged(locus_step.StepSolid).empty;
    defer step_solids.deinit(allocator);

    for (handles) |h| {
        if (h.engine != .brep_native) continue;
        if (@intFromPtr(h.ptr) == 0) continue;

        const solid: *BrepSolid = @ptrCast(@alignCast(h.ptr));
        try step_solids.append(allocator, .{
            .t_arena = &solid.t_arena,
            .g_arena = &solid.g_arena,
            .solid_id = solid.solid_id,
        });
    }

    if (step_solids.items.len == 0) return error.NoGeometry;
    return locus_step.buildStepBuffer(allocator, step_solids.items);
}

fn extractAllVertices(allocator: std.mem.Allocator, handles: []const geom.GeometryHandle) ![]const locus_math.Vec3 {
    var pts = std.ArrayListUnmanaged(locus_math.Vec3).empty;
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    for (handles) |h| {
        if (@intFromPtr(h.ptr) == 0) continue;
        const solid: *BrepSolid = @ptrCast(@alignCast(h.ptr));
        const s = solid.t_arena.solids.items[@backingInt(solid.solid_id)];

        for (0..s.shells_len) |s_off| {
            const shell_idx = solid.t_arena.solid_shells.items[s.shells_start + s_off];
            const shell = solid.t_arena.shells.items[@backingInt(shell_idx)];

            for (0..shell.faces_len) |f_off| {
                const face_idx = solid.t_arena.shell_faces.items[shell.faces_start + f_off];
                const face = solid.t_arena.faces.items[@backingInt(face_idx)];

                for (0..face.loops_len) |l_off| {
                    const loop_idx = solid.t_arena.face_loops.items[face.loops_start + l_off];
                    const loop = solid.t_arena.loops.items[@backingInt(loop_idx)];
                    var curr = loop.first_half_edge;

                    while (true) {
                        const he = solid.t_arena.half_edges.items[@backingInt(curr)];
                        const v = solid.t_arena.vertices.items[@backingInt(he.start_vertex)];
                        const pt_idx = @backingInt(v.point);

                        // Deduplicate points before passing them to Quickhull
                        if (!seen.contains(pt_idx)) {
                            try seen.put(pt_idx, {});
                            try pts.append(allocator, solid.g_arena.points.items[pt_idx]);
                        }

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
    for (handles) |h| if (@intFromPtr(h.ptr) == 0) return null;
    const pts = extractAllVertices(backend_allocator, handles) catch return null;
    defer backend_allocator.free(pts);

    if (pts.len < 4) return null;
    const first: *BrepSolid = @ptrCast(@alignCast(handles[0].ptr));
    const solid = BrepSolid.create(backend_allocator, first.env) catch return null;

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

fn cubeImpl(config: *const engine_config.EngineConfig, x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    const solid = BrepSolid.create(backend_allocator, mathEnv(config)) catch return null;
    solid.solid_id = locus_gen.generateCube(backend_allocator, &solid.t_arena, &solid.g_arena, x, y, z, center) catch {
        solid.destroy();
        return null;
    };
    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn cylinderImpl(config: *const engine_config.EngineConfig, r1: f64, r2: f64, height: f64, center: bool, segments: i32) ?geom.GeometryHandle {
    _ = r2;
    _ = segments;
    const solid = BrepSolid.create(backend_allocator, mathEnv(config)) catch return null;
    solid.solid_id = locus_gen.generateCylinder(backend_allocator, &solid.t_arena, &solid.g_arena, r1, height, center) catch {
        solid.destroy();
        return null;
    };
    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn sphereImpl(config: *const engine_config.EngineConfig, radius: f64, segments: i32) ?geom.GeometryHandle {
    _ = segments;
    const solid = BrepSolid.create(backend_allocator, mathEnv(config)) catch return null;
    solid.solid_id = locus_gen.generateSphere(backend_allocator, &solid.t_arena, &solid.g_arena, radius) catch {
        solid.destroy();
        return null;
    };
    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn squareImpl(config: *const engine_config.EngineConfig, x: f64, y: f64, center: bool) ?geom.CrossSectionHandle {
    const solid = BrepSolid.create(backend_allocator, mathEnv(config)) catch return null;
    solid.solid_id = locus_gen.generateSquare(backend_allocator, &solid.t_arena, &solid.g_arena, x, y, center) catch {
        solid.destroy();
        return null;
    };
    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn circleImpl(config: *const engine_config.EngineConfig, radius: f64, segments: i32) ?geom.CrossSectionHandle {
    const solid = BrepSolid.create(backend_allocator, mathEnv(config)) catch return null;
    solid.solid_id = locus_gen.generateCircle(backend_allocator, &solid.t_arena, &solid.g_arena, radius, segments) catch {
        solid.destroy();
        return null;
    };
    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn polygonImpl(config: *const engine_config.EngineConfig, allocator: std.mem.Allocator, pts: []const [2]f64) ?geom.CrossSectionHandle {
    _ = allocator;
    const solid = BrepSolid.create(backend_allocator, mathEnv(config)) catch return null;
    solid.solid_id = locus_gen.generatePolygon(backend_allocator, &solid.t_arena, &solid.g_arena, pts) catch {
        solid.destroy();
        return null;
    };
    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn polyhedronImpl(config: *const engine_config.EngineConfig, allocator: std.mem.Allocator, pts: []const [3]f64, faces: []const [3]u32) ?geom.GeometryHandle {
    _ = allocator;
    const solid = BrepSolid.create(backend_allocator, mathEnv(config)) catch return null;
    solid.solid_id = locus_gen.buildPolyhedron(backend_allocator, &solid.t_arena, &solid.g_arena, pts, faces) catch {
        solid.destroy();
        return null;
    };
    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn polygonsEvenOddImpl(config: *const engine_config.EngineConfig, allocator: std.mem.Allocator, contours: []const []const [2]f64) ?geom.CrossSectionHandle {
    _ = allocator;
    const solid = BrepSolid.create(backend_allocator, mathEnv(config)) catch return null;
    solid.solid_id = locus_gen.generatePolygonsEvenOdd(backend_allocator, &solid.t_arena, &solid.g_arena, contours) catch {
        solid.destroy();
        return null;
    };
    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn extrudeImpl(cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
    _ = slices;
    _ = twist_degrees;
    _ = scale_x;
    _ = scale_y;
    if (@intFromPtr(cs.ptr) == 0) return null;

    const src_solid: *BrepSolid = @ptrCast(@alignCast(cs.ptr));
    const env = src_solid.env;
    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    dest_solid.solid_id = locus_sweeps.extrudeFace(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_solid.t_arena, &src_solid.g_arena, @as(locus_topo_types.FaceIndex, @fromBackingInt(@backingInt(src_solid.solid_id))), .{ 0, 0, height }, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn revolveImpl(cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
    if (@intFromPtr(cs.ptr) == 0) return null;

    const src_solid: *BrepSolid = @ptrCast(@alignCast(cs.ptr));
    const env = src_solid.env;
    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    dest_solid.solid_id = locus_sweeps.revolveFace(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_solid.t_arena, @as(locus_topo_types.FaceIndex, @fromBackingInt(@backingInt(src_solid.solid_id))), @intCast(segments), revolve_degrees, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn translateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const src_solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_solid.env;
    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    dest_solid.solid_id = locus_trans.translateSolid(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_solid.t_arena, &src_solid.g_arena, src_solid.solid_id, x, y, z, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn rotateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const src_solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_solid.env;
    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    dest_solid.solid_id = locus_trans.rotateSolid(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_solid.t_arena, &src_solid.g_arena, src_solid.solid_id, x, y, z, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn scaleImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const src_solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_solid.env;
    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    dest_solid.solid_id = locus_trans.scaleSolid(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_solid.t_arena, &src_solid.g_arena, src_solid.solid_id, x, y, z, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn transformMatrixImpl(a: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const src_solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_solid.env;
    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    dest_solid.solid_id = locus_trans.transformMatrixSolid(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_solid.t_arena, &src_solid.g_arena, src_solid.solid_id, mat, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn crossSectionTransformImpl(cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
    if (@intFromPtr(cs.ptr) == 0) return null;
    const src_solid: *BrepSolid = @ptrCast(@alignCast(cs.ptr));
    const env = src_solid.env;
    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    const mat3d = [12]f64{
        mat[0], mat[1], 0.0, mat[2],
        mat[3], mat[4], 0.0, mat[5],
        0.0,    0.0,    1.0, 0.0,
    };

    dest_solid.solid_id = locus_trans.transformMatrixSolid(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_solid.t_arena, &src_solid.g_arena, src_solid.solid_id, mat3d, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn mirrorImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const src_solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_solid.env;
    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    dest_solid.solid_id = locus_trans.mirrorSolid(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_solid.t_arena, &src_solid.g_arena, src_solid.solid_id, nx, ny, nz, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn offsetImpl(cs: geom.CrossSectionHandle, delta: f64, join_type: u8) ?geom.CrossSectionHandle {
    _ = join_type;
    _ = delta;
    // Not implemented for B-Rep yet. Report failure instead of returning the unchanged
    // sketch, which would be silently wrong geometry.
    _ = cs;
    return null;
}

fn booleanImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    // Real check: a Manifold pointer reinterpreted as a BrepSolid silently yields garbage.
    if (a.engine != .brep_native or b.engine != .brep_native) return null;
    if (@intFromPtr(a.ptr) == 0 or @intFromPtr(b.ptr) == 0) return null;
    const src_a: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_a.env;
    const src_b: *BrepSolid = @ptrCast(@alignCast(b.ptr));

    const locus_op: locus_bool.BooleanOp = switch (op) {
        .union_op => .union_op,
        .difference_op => .difference,
        .intersection_op => .intersection,
    };

    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    dest_solid.solid_id = locus_bool.computeBoolean(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_a.t_arena, &src_a.g_arena, src_a.solid_id, &src_b.t_arena, &src_b.g_arena, src_b.solid_id, locus_op, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn batchBooleanImpl(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    _ = allocator;
    if (objs.len == 0) return null;

    for (objs) |obj| if (obj.engine != .brep_native) return null;

    var acc = objs[0];
    for (objs[1..]) |obj| {
        // One failed step fails the whole batch; skipping it would drop an operand silently.
        const res = booleanImpl(acc, obj, op) orelse {
            if (acc.ptr != objs[0].ptr) destructImpl(acc);
            return null;
        };
        if (acc.ptr != objs[0].ptr) destructImpl(acc);
        acc = res;
    }
    // Never hand back a borrowed input: the caller owns (and will destroy) the result.
    if (acc.ptr == objs[0].ptr) return cloneImpl(objs[0]);
    return acc;
}

fn minkowskiImpl(a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
    if (a.engine != .brep_native or b.engine != .brep_native) return null;
    if (@intFromPtr(a.ptr) == 0 or @intFromPtr(b.ptr) == 0) return null;
    const src_a: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_a.env;
    const src_b: *BrepSolid = @ptrCast(@alignCast(b.ptr));

    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    dest_solid.solid_id = locus_mink.minkowskiSumConvex(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_a.t_arena, &src_a.g_arena, src_a.solid_id, &src_b.t_arena, &src_b.g_arena, src_b.solid_id, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn crossSectionBooleanImpl(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: kernel.BooleanOp) ?geom.CrossSectionHandle {
    if (a.engine != .brep_native or b.engine != .brep_native) return null;
    if (@intFromPtr(a.ptr) == 0 or @intFromPtr(b.ptr) == 0) return null;

    const src_a: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_a.env;
    const src_b: *BrepSolid = @ptrCast(@alignCast(b.ptr));

    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    const locus_op: locus_bool.BooleanOp = switch (op) {
        .union_op => .union_op,
        .difference_op => .difference,
        .intersection_op => .intersection,
    };

    dest_solid.solid_id = locus_bool2d.crossSectionBoolean(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_a.t_arena, &src_a.g_arena, src_a.solid_id, &src_b.t_arena, &src_b.g_arena, src_b.solid_id, locus_op, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn trimByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset: f64) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const src_solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_solid.env;
    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    dest_solid.solid_id = locus_slicing.trimByPlane(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, &src_solid.t_arena, &src_solid.g_arena, src_solid.solid_id, nx, ny, nz, offset, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn splitByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset: f64) geom.SolidPair {
    if (@intFromPtr(a.ptr) == 0) return .{ .first = null, .second = null };
    const src_solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_solid.env;

    // On failure both halves are null: returning the whole input as one "half" was wrong geometry.
    const dest_a = BrepSolid.create(backend_allocator, env) catch return .{ .first = null, .second = null };
    const dest_b = BrepSolid.create(backend_allocator, env) catch {
        dest_a.destroy();
        return .{ .first = null, .second = null };
    };

    const pair = locus_slicing.splitByPlane(backend_allocator, &dest_a.t_arena, &dest_a.g_arena, &dest_b.t_arena, &dest_b.g_arena, &src_solid.t_arena, &src_solid.g_arena, src_solid.solid_id, nx, ny, nz, offset, env) catch {
        dest_a.destroy();
        dest_b.destroy();
        return .{ .first = null, .second = null };
    };

    dest_a.solid_id = pair.first;
    dest_b.solid_id = pair.second;

    return .{ .first = geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_a) }, .second = geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_b) } };
}

fn hullImpl(a: geom.GeometryHandle) ?geom.GeometryHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    return buildHullFromHandles(&[_]geom.GeometryHandle{a});
}

fn batchHullImpl(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle) ?geom.GeometryHandle {
    _ = allocator;
    if (objs.len == 0) return null;
    for (objs) |obj| if (obj.engine != .brep_native) return null;
    return buildHullFromHandles(objs);
}

fn loftImpl(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, height: f64) ?geom.GeometryHandle {
    if (a.engine != .brep_native or b.engine != .brep_native) return null;
    if (@intFromPtr(a.ptr) == 0 or @intFromPtr(b.ptr) == 0) return null;

    const src_a: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_a.env;
    const src_b: *BrepSolid = @ptrCast(@alignCast(b.ptr));

    const pts_a = locus_bool2d.extractPolygon(backend_allocator, &src_a.t_arena, &src_a.g_arena, src_a.solid_id) catch return null;
    defer backend_allocator.free(pts_a);

    const pts_b = locus_bool2d.extractPolygon(backend_allocator, &src_b.t_arena, &src_b.g_arena, src_b.solid_id) catch return null;
    defer backend_allocator.free(pts_b);

    const dest_solid = BrepSolid.create(backend_allocator, env) catch return null;

    dest_solid.solid_id = locus_sweeps.loftPolygons(backend_allocator, &dest_solid.t_arena, &dest_solid.g_arena, pts_a, pts_b, height, env) catch {
        dest_solid.destroy();
        return null;
    };

    return geom.GeometryHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_solid) };
}

fn decomposeImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?[]geom.GeometryHandle {
    // B-Rep decomposition is not implemented: the single "component" is a copy of
    // the input, because the caller takes ownership of every returned handle.
    const part = cloneImpl(handle) orelse return null;
    var res = allocator.alloc(geom.GeometryHandle, 1) catch {
        destructImpl(part);
        return null;
    };
    res[0] = part;
    return res;
}

fn sliceImpl(a: geom.GeometryHandle, height: f64) ?geom.CrossSectionHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const src_solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = src_solid.env;

    var mesh = locus_tess.Mesh{};
    defer mesh.deinit(backend_allocator);
    locus_tess.tessellateSolid(backend_allocator, &src_solid.t_arena, &src_solid.g_arena, src_solid.solid_id, &mesh, env) catch return null;

    const contours = locus_slicing.sliceMeshToContours(backend_allocator, &mesh, height) catch return null;
    defer {
        for (contours) |c| backend_allocator.free(c);
        backend_allocator.free(contours);
    }

    if (contours.len == 0) return null;

    const dest_cs = BrepSolid.create(backend_allocator, env) catch return null;
    dest_cs.solid_id = locus_gen.generatePolygonsEvenOdd(backend_allocator, &dest_cs.t_arena, &dest_cs.g_arena, contours) catch {
        dest_cs.destroy();
        return null;
    };

    return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_cs) };
}

fn projectImpl(a: geom.GeometryHandle) ?geom.CrossSectionHandle {
    if (@intFromPtr(a.ptr) == 0) return null;
    const src_solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));

    const dest_cs = BrepSolid.create(backend_allocator, src_solid.env) catch return null;

    if (locus_proj.projectSolid(
        backend_allocator,
        &dest_cs.t_arena,
        &dest_cs.g_arena,
        &src_solid.t_arena,
        &src_solid.g_arena,
        src_solid.solid_id,
    ) catch null) |cs_id| {
        dest_cs.solid_id = cs_id;
        return geom.CrossSectionHandle{ .engine = .brep_native, .ptr = @ptrCast(dest_cs) };
    }

    dest_cs.destroy();
    return null;
}

fn genusImpl(handle: geom.GeometryHandle) i32 {
    if (@intFromPtr(handle.ptr) == 0) return 0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    return locus_prop.genus(backend_allocator, &solid.t_arena, solid.solid_id);
}

fn boundingBoxImpl(handle: geom.GeometryHandle) ?geom.BoundingBox {
    if (@intFromPtr(handle.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    if (locus_prop.boundingBox(&solid.t_arena, &solid.g_arena, solid.solid_id)) |bb| {
        return geom.BoundingBox{ .min = bb.min, .max = bb.max };
    }
    return null;
}

fn volumeImpl(handle: geom.GeometryHandle) f64 {
    if (@intFromPtr(handle.ptr) == 0) return 0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    const env = solid.env;
    return locus_prop.volume(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, env);
}

fn surfaceAreaImpl(handle: geom.GeometryHandle) f64 {
    if (@intFromPtr(handle.ptr) == 0) return 0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    const env = solid.env;
    return locus_prop.surfaceArea(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, env);
}

fn crossSectionAreaImpl(handle: geom.CrossSectionHandle) f64 {
    if (@intFromPtr(handle.ptr) == 0) return 0.0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    return locus_prop.crossSectionArea(&solid.t_arena, &solid.g_arena, solid.solid_id);
}

fn crossSectionNumVertsImpl(handle: geom.CrossSectionHandle) usize {
    if (@intFromPtr(handle.ptr) == 0) return 0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    return solid.t_arena.vertices.items.len;
}

/// Locus does not expose sketch contours yet; null tells the caller this engine can't
/// answer, so the user gets a clear error instead of a wrong `false`.
fn crossSectionContainsPointImpl(handle: geom.CrossSectionHandle, pt: [2]f64, tolerance: f64) ?bool {
    _ = handle;
    _ = pt;
    _ = tolerance;
    return null;
}

/// Unknown for B-Rep sketches (no contour access yet); callers treat null as "can't tell".
fn crossSectionIsConvexImpl(handle: geom.CrossSectionHandle) ?bool {
    _ = handle;
    return null;
}

fn crossSectionBoundsImpl(handle: geom.CrossSectionHandle) geom.Rect2D {
    if (@intFromPtr(handle.ptr) == 0) return .{ .min = .{ 0, 0 }, .max = .{ 0, 0 } };
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    const bb = locus_prop.crossSectionBounds(&solid.t_arena, &solid.g_arena, solid.solid_id);
    return .{ .min = .{ bb.min[0], bb.min[1] }, .max = .{ bb.max[0], bb.max[1] } };
}

fn queryFacesImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle, direction: [3]f64, tolerance: f64) ?[]geom.FaceHandle {
    if (@intFromPtr(handle.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));

    const l_faces = (locus_insp.queryFaces(allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, direction, tolerance) catch return null) orelse return null;
    defer allocator.free(l_faces); // also when the copy below fails (it used to leak)
    const handles = allocator.alloc(geom.FaceHandle, l_faces.len) catch return null;
    for (l_faces, handles) |f, *h| h.* = .{ .index = f.index, .normal = f.normal, .centroid = f.centroid };
    return handles;
}

fn containsPointImpl(a: geom.GeometryHandle, pt: [3]f64) bool {
    if (@intFromPtr(a.ptr) == 0) return false;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = solid.env;
    return locus_bool.isPointInsideSolid(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, pt, env);
}

fn minGapImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, sl: f64) f64 {
    _ = sl;
    if (a.engine != .brep_native or b.engine != .brep_native) return 0.0;
    if (@intFromPtr(a.ptr) == 0 or @intFromPtr(b.ptr) == 0) return 0.0;

    const solid_a: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = solid_a.env;
    const solid_b: *BrepSolid = @ptrCast(@alignCast(b.ptr));

    return locus_query.minGap(backend_allocator, &solid_a.t_arena, &solid_a.g_arena, solid_a.solid_id, &solid_b.t_arena, &solid_b.g_arena, solid_b.solid_id, env);
}

fn rayCastImpl(alloc: std.mem.Allocator, a: geom.GeometryHandle, o: [3]f64, e: [3]f64) ?[]geom.RayHit {
    if (@intFromPtr(a.ptr) == 0) return null;
    const solid: *BrepSolid = @ptrCast(@alignCast(a.ptr));
    const env = solid.env;

    if (locus_query.rayCast(alloc, &solid.t_arena, &solid.g_arena, solid.solid_id, o, e, env) catch null) |hits| {
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
    const env = solid.env;

    var mesh = locus_tess.Mesh{};
    defer mesh.deinit(backend_allocator);

    locus_tess.tessellateSolid(backend_allocator, &solid.t_arena, &solid.g_arena, solid.solid_id, &mesh, env) catch return null;
    return copyMesh(allocator, &mesh) catch null;
}

/// The tessellation in `allocator`'s memory; on failure nothing stays allocated (the
/// vertices used to leak when the triangles' allocation failed).
pub fn copyMesh(allocator: std.mem.Allocator, mesh: *const locus_tess.Mesh) !geom.Mesh {
    const vert_props = try allocator.alloc(f32, mesh.vertices.items.len * 3);
    errdefer allocator.free(vert_props);
    for (mesh.vertices.items, 0..) |v, i| {
        for (0..3) |axis| vert_props[i * 3 + axis] = @floatCast(v[axis]);
    }
    const tri_verts = try allocator.alloc(u32, mesh.triangles.items.len * 3);
    for (mesh.triangles.items, 0..) |t, i| {
        for (0..3) |corner| tri_verts[i * 3 + corner] = t[corner];
    }
    return .{ .vert_props = vert_props, .tri_verts = tri_verts, .num_prop = 3 };
}

fn numVertsImpl(handle: geom.GeometryHandle) usize {
    std.debug.assert(handle.engine == .brep_native);
    if (@intFromPtr(handle.ptr) == 0) return 0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    return solid.t_arena.vertices.items.len;
}

fn numTrisImpl(handle: geom.GeometryHandle) usize {
    std.debug.assert(handle.engine == .brep_native);
    if (@intFromPtr(handle.ptr) == 0) return 0;
    const solid: *BrepSolid = @ptrCast(@alignCast(handle.ptr));
    return solid.t_arena.faces.items.len;
}

fn simplifyImpl(a: geom.GeometryHandle, tolerance: f64) ?geom.GeometryHandle {
    _ = tolerance;
    // No-op for B-Rep, but must still return a NEW handle (single-owner rule, see kernel.zig).
    return cloneImpl(a);
}

fn setMaterialImpl(a: geom.GeometryHandle, material_id: u32) ?geom.GeometryHandle {
    _ = material_id;
    // Materials are not stored on B-Rep solids yet; return a copy, never the input.
    return cloneImpl(a);
}

/// Deep copy via an identity translation (locus has no dedicated copy operation).
fn cloneImpl(a: geom.GeometryHandle) ?geom.GeometryHandle {
    return translateImpl(a, 0.0, 0.0, 0.0);
}

fn cloneCrossSectionImpl(cs: geom.CrossSectionHandle) ?geom.CrossSectionHandle {
    const identity = [6]f64{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0 };
    return crossSectionTransformImpl(cs, identity);
}

/// B-Rep solids are validated by Locus as they are built; there is no deferred status.
fn problemImpl(a: geom.GeometryHandle) ?[]const u8 {
    if (@intFromPtr(a.ptr) == 0) return "the kernel returned no solid";
    return null;
}

pub const driver = struct {
    pub const problemFn = problemImpl;
    pub const cubeFn = cubeImpl;
    pub const cylinderFn = cylinderImpl;
    pub const sphereFn = sphereImpl;
    pub const booleanFn = booleanImpl;
    pub const batchBooleanFn = batchBooleanImpl;
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
    pub const batchHullFn = batchHullImpl;
    pub const loftFn = loftImpl;
    pub const decomposeFn = decomposeImpl;
    pub const trimByPlaneFn = trimByPlaneImpl;
    pub const splitByPlaneFn = splitByPlaneImpl;
    pub const crossSectionBooleanFn = crossSectionBooleanImpl;
    pub const genusFn = genusImpl;
    pub const transformMatrixFn = transformMatrixImpl;
    pub const minkowskiFn = minkowskiImpl;
    pub const offsetFn = offsetImpl;
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
    pub const cloneFn = cloneImpl;
    pub const cloneCrossSectionFn = cloneCrossSectionImpl;
    pub const destructFn = destructImpl;
    pub const destructCrossSectionFn = destructCrossSectionImpl;
    pub const setMaterialFn = setMaterialImpl;
};
