//! The Locus B-Rep engine's kernel driver: `driver` maps each kernel operation onto Locus
//! (solids and sketches as `BrepSolid`, a Locus body), and `supports` says which ones Locus
//! implements so far, so the others become errors instead of wrong geometry. Also writes
//! STEP (`exportStep`).

const std = @import("std");
const kernel = @import("../../kernel.zig");
const geom = @import("../../../core/geometry_handle.zig");
const engine_config = @import("../../../core/engine_config.zig");
const locus = @import("locus");
const parallel_binding = @import("../../../bindings/parallel.zig");

/// The threads Locus's operations may split work over: oneTBB's (src/bindings/parallel.zig).
pub const parallel = parallel_binding.parallel;

/// What Locus allocates its bodies with. The driver interface carries no allocator, so this
/// is libc's general-purpose allocator.
const backend_allocator = std.heap.c_allocator;

/// Where every operation on this thread sends the body after each of its phases, as JSON
/// (Locus's trace, architecture §12): set by `kupcad dev brep-trace` around one script's
/// run (tools/dev/brep_trace.zig), null otherwise. The driver interface carries no options
/// of the host's, so the sink is the thread's.
threadlocal var trace_sink: ?locus.diagnostics.Trace = null;

/// Sets the trace sink of every operation on this thread, until set to null again.
pub fn setTrace(sink: ?locus.diagnostics.Trace) void {
    trace_sink = sink;
}

/// Why the last operation on this thread returned null, as Locus's first finding, until
/// `takeFailureImpl` reads it: the driver interface answers a failure with null, and this
/// carries the reason into the script's error (dag_evaluator's kernelFailed). Empty after a
/// failure with no finding (memory).
threadlocal var last_failure: [FAILURE_BYTES]u8 = undefined;
threadlocal var last_failure_len: usize = 0;
const FAILURE_BYTES = 256;

fn remember(diag: *const locus.Diagnostics) void {
    last_failure_len = 0;
    const finding = diag.first() orelse return;
    var w: std.Io.Writer = .fixed(&last_failure);
    // Cut at the buffer's end: what fits is the message
    finding.format(&w) catch {};
    last_failure_len = w.buffered().len;
}

/// The reason the last operation failed, once; valid until the next operation.
fn takeFailureImpl() ?[]const u8 {
    if (last_failure_len == 0) return null;
    defer last_failure_len = 0;
    return last_failure[0..last_failure_len];
}

const Affine = locus.math.mat.Affine;
const Body = locus.Body;
/// A trace sink, as `setTrace` takes it.
pub const Trace = locus.diagnostics.Trace;

/// A solid or a sketch of the B-Rep engine: a Locus body with the limits it was built under.
pub const BrepSolid = struct {
    body: Body,
    /// The bounds on Locus's iterations, from the settings the part was built under.
    limits: locus.Limits,

    /// Takes `body` into a new handle; on failure the body is freed.
    pub fn create(body: Body, bounds: locus.Limits) !*BrepSolid {
        const self = backend_allocator.create(BrepSolid) catch |e| {
            var b = body;
            b.deinit();
            return e;
        };
        self.* = .{ .body = body, .limits = bounds };
        return self;
    }

    pub fn destroy(self: *BrepSolid) void {
        self.body.deinit();
        backend_allocator.destroy(self);
    }

    /// An independent copy: the same body, index for index.
    pub fn clone(self: *const BrepSolid) !*BrepSolid {
        return create(try self.body.clone(backend_allocator), self.limits);
    }

    fn options(self: *const BrepSolid) locus.Options {
        return .{ .limits = self.limits, .parallel = parallel, .trace = trace_sink };
    }
};

/// The Locus tolerance for solids built under `config`: every distance tolerance follows
/// the one `tolerance` (its `zone`); the angular one compares unit directions and never
/// scales with the model.
pub fn tolerance(config: *const engine_config.EngineConfig) locus.Tolerance {
    return locus.Tolerance.fromZone(config.tolerance);
}

/// The bounds on Locus's iterations under `config`.
pub fn limits(config: *const engine_config.EngineConfig) locus.Limits {
    return .{ .newton_trials = config.brep.max_newton_trials, .marching_steps = config.brep.max_marching_steps };
}

pub fn exportStep(allocator: std.mem.Allocator, handles: []const geom.GeometryHandle) ![]const u8 {
    var bodies = std.ArrayList(*const Body).empty;
    defer bodies.deinit(allocator);
    for (handles) |h| {
        // Never skipped: a part left out is a wrong file (callers refuse mesh parts first,
        // exporters/export.zig requireExactParts).
        if (h.engine != .brep_native) return error.NotExactGeometry;
        try bodies.append(allocator, &solidOf(h.ptr).body);
    }
    if (bodies.items.len == 0) return error.NoGeometry;
    return locus.io.step_write.write(allocator, bodies.items);
}

/// Whether any face of the solid lies on a curved surface. The hull is built from the
/// solid's vertices, which is the true hull only when every face is flat.
pub fn hasCurvedFaces(handle: geom.GeometryHandle) bool {
    const body = &solidOf(handle.ptr).body;
    for (body.faces.items) |f| {
        if (!f.flags.tombstone and f.surface.kind != .plane) return true;
    }
    return false;
}

/// What Locus implements so far: boxes, cylinders, cones, spheres, polyhedra, sketches
/// (square, circle, polygon, even-odd polygons), their booleans and offsets, their extrusions (no twist or taper) and
/// revolutions (of a sketch on one side of the axis), their volume, area, genus and box
/// (a sketch's area and box too), hulls of flat-faced solids, every rigid move, uniform scale and mirror, and STEP
/// export. Everything else is refused before the driver runs
/// (kernel.Feature), never answered with a stand-in.
pub fn supports(feature: kernel.Feature) bool {
    return switch (feature) {
        .transform, .sphere, .cone, .extrude, .revolve, .volume, .surface_area, .genus, .bounding_box, .sketch_measure, .sketch_boolean, .offset => true,
        .boolean,
        .loft,
        .sketch_hull,
        .curved_hull,
        .extrude_twist,
        .extrude_scale,
        .minkowski,
        .trim_by_plane,
        .slice,
        .project,
        .decompose,
        .sketch_contours,
        .contains_point,
        .ray_cast,
        .min_gap,
        .faces,
        .mesh,
        .materials,
        .empty,
        => false,
    };
}

pub const driver = struct {
    pub const problemFn = problemImpl;
    pub const takeFailureFn = takeFailureImpl;
    pub const emptyFn = emptyImpl;
    pub const emptySketchFn = emptySketchImpl;
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
    pub const crossSectionBooleanFn = crossSectionBooleanImpl;
    pub const crossSectionHullFn = crossSectionHullImpl;
    pub const crossSectionBatchBooleanFn = crossSectionBatchBooleanImpl;
    pub const erodeFn = erodeImpl;
    pub const genusFn = genusImpl;
    pub const transformMatrixFn = transformMatrixImpl;
    pub const minkowskiFn = minkowskiImpl;
    pub const offsetFn = offsetImpl;
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
    pub const cloneFn = cloneImpl;
    pub const cloneCrossSectionFn = cloneCrossSectionImpl;
    pub const destructFn = destructImpl;
    pub const destructCrossSectionFn = destructCrossSectionImpl;
    pub const setMaterialFn = setMaterialImpl;
};

// --- building ---

/// A new handle of kind `Handle` around the body `make` builds (given the allocator, the
/// tolerance, then `args`, then the diagnostics); null when Locus refuses, nothing kept.
fn build(comptime Handle: type, config: *const engine_config.EngineConfig, comptime make: anytype, args: anytype) ?Handle {
    var diag = locus.Diagnostics.init(backend_allocator);
    defer diag.deinit();
    const body = @call(.auto, make, .{ backend_allocator, tolerance(config) } ++ args ++ .{&diag}) catch {
        remember(&diag);
        return null;
    };
    const solid = BrepSolid.create(body, limits(config)) catch return null;
    return .{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

/// The solid at `ptr` under `affine`, as a new handle of kind `Handle`; null when Locus
/// refuses (a non-uniform scale of a curved part), nothing kept.
fn transformed(comptime Handle: type, ptr: *anyopaque, affine: Affine) ?Handle {
    const src = solidOf(ptr);
    var diag = locus.Diagnostics.init(backend_allocator);
    defer diag.deinit();
    const body = locus.construct.transform.transform(backend_allocator, &src.body, &affine, src.options(), &diag) catch {
        remember(&diag);
        return null;
    };
    const solid = BrepSolid.create(body, src.limits) catch return null;
    return .{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn solidOf(ptr: *anyopaque) *BrepSolid {
    return @ptrCast(@alignCast(ptr));
}

fn cubeImpl(config: *const engine_config.EngineConfig, x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    return build(geom.GeometryHandle, config, locus.construct.primitives.box, .{ x, y, z, center });
}

/// A cylinder, or a cone when the radii differ (an apex where one is 0); the exact surface
/// needs no `segments`.
fn cylinderImpl(config: *const engine_config.EngineConfig, r1: f64, r2: f64, height: f64, center: bool, segments: i32) ?geom.GeometryHandle {
    _ = segments;
    if (r2 == r1) return build(geom.GeometryHandle, config, locus.construct.primitives.cylinder, .{ r1, height, center });
    return build(geom.GeometryHandle, config, locus.construct.primitives.cone, .{ r1, r2, height, center });
}

/// The exact sphere: two hemispheres; `segments` is the mesh engine's.
fn sphereImpl(config: *const engine_config.EngineConfig, radius: f64, segments: i32) ?geom.GeometryHandle {
    _ = segments;
    return build(geom.GeometryHandle, config, locus.construct.primitives.sphere, .{radius});
}

fn squareImpl(config: *const engine_config.EngineConfig, x: f64, y: f64, center: bool) ?geom.CrossSectionHandle {
    return build(geom.CrossSectionHandle, config, locus.construct.primitives.square, .{ x, y, center });
}

/// An exact circle: `segments` is the mesh engine's and the tessellation's, not the shape's.
fn circleImpl(config: *const engine_config.EngineConfig, radius: f64, segments: i32) ?geom.CrossSectionHandle {
    _ = segments;
    return build(geom.CrossSectionHandle, config, locus.construct.primitives.circle, .{radius});
}

/// The face an outline encloses, whichever way it runs (Locus turns a clockwise one around,
/// as Manifold fills either by the even-odd rule).
fn polygonImpl(config: *const engine_config.EngineConfig, allocator: std.mem.Allocator, pts: []const [2]f64) ?geom.CrossSectionHandle {
    _ = allocator;
    return build(geom.CrossSectionHandle, config, locus.construct.primitives.polygon, .{pts});
}

fn polyhedronImpl(config: *const engine_config.EngineConfig, allocator: std.mem.Allocator, pts: []const [3]f64, faces: []const [3]u32) ?geom.GeometryHandle {
    _ = allocator;
    return build(geom.GeometryHandle, config, locus.construct.primitives.polyhedron, .{ pts, faces });
}

fn polygonsEvenOddImpl(config: *const engine_config.EngineConfig, allocator: std.mem.Allocator, contours: []const []const [2]f64) ?geom.CrossSectionHandle {
    _ = allocator;
    return build(geom.CrossSectionHandle, config, locus.construct.primitives.polygonsEvenOdd, .{contours});
}

// --- transforms ---

fn translateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    return transformed(geom.GeometryHandle, a.ptr, Affine.translate(.{ x, y, z }));
}

/// Rotations about x, then y, then z, in degrees, as the mesh engine's.
fn rotateImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    return transformed(geom.GeometryHandle, a.ptr, Affine.rotateXyzDegrees(x, y, z));
}

fn scaleImpl(a: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    return transformed(geom.GeometryHandle, a.ptr, Affine.scaleBy(.{ x, y, z }));
}

/// The kernel's 3×4 matrix is column-major: the images of the axes, then the translation.
fn transformMatrixImpl(a: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
    return transformed(geom.GeometryHandle, a.ptr, Affine.fromColumns(mat));
}

fn crossSectionTransformImpl(cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
    return transformed(geom.CrossSectionHandle, cs.ptr, Affine.fromColumns2d(mat));
}

/// Reflection in the plane through the origin with normal `(nx, ny, nz)`.
fn mirrorImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle {
    const n = locus.math.vec.normalized(.{ nx, ny, nz }) orelse return null;
    return transformed(geom.GeometryHandle, a.ptr, Affine.mirror(n));
}

// --- hulls ---

/// The convex hull of the solids' vertices, as a new solid with the first one's settings.
/// Only the points the hull's faces use become its vertices.
fn hullOf(handles: []const geom.GeometryHandle) ?geom.GeometryHandle {
    if (handles.len == 0) return null;
    for (handles) |h| if (h.engine != .brep_native) return null;
    var pts = std.ArrayList(locus.math.vec.Vec3).empty;
    defer pts.deinit(backend_allocator);
    for (handles) |h| {
        const body = &solidOf(h.ptr).body;
        for (body.vertices.items) |v| {
            if (v.tombstone) continue;
            pts.append(backend_allocator, body.geometry.point(v.point)) catch return null;
        }
    }
    const first = solidOf(handles[0].ptr);
    var diag = locus.Diagnostics.init(backend_allocator);
    defer diag.deinit();
    const body = locus.construct.hull.hull(backend_allocator, first.body.tol, pts.items, &diag) catch {
        remember(&diag);
        return null;
    };
    const solid = BrepSolid.create(body, first.limits) catch return null;
    return .{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn hullImpl(a: geom.GeometryHandle) ?geom.GeometryHandle {
    return hullOf(&.{a});
}

fn batchHullImpl(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle) ?geom.GeometryHandle {
    _ = allocator;
    return hullOf(objs);
}

// --- not implemented for B-Rep yet: each is refused before the driver (supports), and
// answers null here, never a stand-in ---

fn emptyImpl(config: *const engine_config.EngineConfig) ?geom.GeometryHandle {
    _ = config;
    return null;
}

fn emptySketchImpl(config: *const engine_config.EngineConfig) ?geom.CrossSectionHandle {
    _ = config;
    return null;
}

/// The sketch swept up by `height`: exact, so `slices` is the mesh engine's; a twist or a
/// taper is refused before the driver (supports(.extrude_twist, .extrude_scale) are false).
fn extrudeImpl(cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
    _ = slices;
    if (twist_degrees != 0 or scale_x != 1 or scale_y != 1) return null;
    const src = solidOf(cs.ptr);
    var diag = locus.Diagnostics.init(backend_allocator);
    defer diag.deinit();
    const body = locus.construct.sweep.extrude(backend_allocator, &src.body, .{ 0, 0, height }, src.options(), &diag) catch {
        remember(&diag);
        return null;
    };
    const solid = BrepSolid.create(body, src.limits) catch return null;
    return .{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

/// The sketch stood up (its x the radius, its y the height) and turned about z by
/// `revolve_degrees`, as the mesh engine's Revolve places it; exact, so `segments` is the
/// mesh engine's. A sketch crossing the axis is refused (the mesh engine clips it there),
/// until the 2D kernel can cut it.
fn revolveImpl(cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
    _ = segments;
    const src = solidOf(cs.ptr);
    var diag = locus.Diagnostics.init(backend_allocator);
    defer diag.deinit();
    const stand_up = Affine.rotate(locus.math.vec.X3, std.math.pi / 2.0);
    var profile = locus.construct.transform.transform(backend_allocator, &src.body, &stand_up, src.options(), &diag) catch {
        remember(&diag);
        return null;
    };
    defer profile.deinit();
    const body = locus.construct.sweep.revolve(backend_allocator, &profile, locus.math.vec.ZERO3, locus.math.vec.Z3, std.math.degreesToRadians(revolve_degrees), src.options(), &diag) catch {
        remember(&diag);
        return null;
    };
    const solid = BrepSolid.create(body, src.limits) catch return null;
    return .{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn erodeImpl(a: geom.GeometryHandle, radius: f64, segments: i32) ?geom.GeometryHandle {
    _ = a;
    _ = radius;
    _ = segments;
    return null;
}

fn crossSectionHullImpl(allocator: std.mem.Allocator, sketches: []const geom.CrossSectionHandle) ?geom.CrossSectionHandle {
    _ = allocator;
    _ = sketches;
    return null;
}

/// The sketch grown or shrunk by `delta`, its corners joined as `join_type` says (the
/// kernel's codes: 0 square, 1 round, 2 miter, 3 bevel); round joins are exact arcs, so
/// `segments` is the mesh engine's.
fn offsetImpl(cs: geom.CrossSectionHandle, delta: f64, join_type: u8, segments: i32, miter_limit: f64) ?geom.CrossSectionHandle {
    _ = segments;
    const src = solidOf(cs.ptr);
    var diag = locus.Diagnostics.init(backend_allocator);
    defer diag.deinit();
    const join: locus.sketch.offset.Join = switch (join_type) {
        0 => .square,
        2 => .miter,
        3 => .bevel,
        else => .round,
    };
    const body = locus.sketch.offset.offset(backend_allocator, &src.body, delta, join, miter_limit, src.options(), &diag) catch {
        remember(&diag);
        return null;
    };
    const solid = BrepSolid.create(body, src.limits) catch return null;
    return .{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn booleanImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    _ = a;
    _ = b;
    _ = op;
    return null;
}

/// A batch of one is that solid, copied (the caller owns the result); any more is a boolean.
fn batchBooleanImpl(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle, op: kernel.BooleanOp) ?geom.GeometryHandle {
    _ = allocator;
    _ = op;
    if (objs.len != 1 or objs[0].engine != .brep_native) return null;
    return cloneImpl(objs[0]);
}

fn minkowskiImpl(a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
    _ = a;
    _ = b;
    return null;
}

/// The sketches combined by Locus's overlay: the first less the others for a difference,
/// their union, or what all of them hold. The result keeps the first sketch's settings.
fn crossSectionBatchBooleanImpl(allocator: std.mem.Allocator, sketches: []const geom.CrossSectionHandle, op: kernel.BooleanOp) ?geom.CrossSectionHandle {
    const bodies = allocator.alloc(*const Body, sketches.len) catch return null;
    defer allocator.free(bodies);
    for (sketches, bodies) |s, *body| body.* = &solidOf(s.ptr).body;
    const first = solidOf(sketches[0].ptr);
    var diag = locus.Diagnostics.init(backend_allocator);
    defer diag.deinit();
    const which: locus.sketch.boolean.Op = switch (op) {
        .union_op => .@"union",
        .difference_op => .difference,
        .intersection_op => .intersection,
    };
    const body = locus.sketch.boolean.boolean(backend_allocator, bodies, which, first.options(), &diag) catch {
        remember(&diag);
        return null;
    };
    const solid = BrepSolid.create(body, first.limits) catch return null;
    return .{ .engine = .brep_native, .ptr = @ptrCast(solid) };
}

fn crossSectionBooleanImpl(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: kernel.BooleanOp) ?geom.CrossSectionHandle {
    return crossSectionBatchBooleanImpl(backend_allocator, &.{ a, b }, op);
}

fn trimByPlaneImpl(a: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset: f64) ?geom.GeometryHandle {
    _ = a;
    _ = nx;
    _ = ny;
    _ = nz;
    _ = offset;
    return null;
}

fn loftImpl(allocator: std.mem.Allocator, a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, height: f64) ?geom.GeometryHandle {
    _ = allocator;
    _ = a;
    _ = b;
    _ = height;
    return null;
}

/// Decomposition is not implemented: the one "part" is a copy of the input, because the
/// caller takes ownership of every returned handle.
fn decomposeImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?[]geom.GeometryHandle {
    const part = cloneImpl(handle) orelse return null;
    const res = allocator.alloc(geom.GeometryHandle, 1) catch {
        destructImpl(part);
        return null;
    };
    res[0] = part;
    return res;
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

/// The genus over every shell, as the mesh engine counts it (1 − χ/2); a body the
/// checker would refuse has none, and reports 0 as an empty mesh does.
fn genusImpl(handle: geom.GeometryHandle) i32 {
    var diag = locus.Diagnostics.init(backend_allocator);
    defer diag.deinit();
    return locus.measure.mass.genus(&solidOf(handle.ptr).body, &diag) catch 0;
}

/// The exact box of the part's edges and faces.
fn boundingBoxImpl(handle: geom.GeometryHandle) ?geom.BoundingBox {
    const box = locus.measure.bbox.bodyBounds(&solidOf(handle.ptr).body) catch return null;
    if (box.isEmpty()) return null;
    return .{ .min = box.min, .max = box.max };
}

/// The mass properties of the body at `ptr`, exact to the quadrature's agreement; a
/// failure (the interface has no error) measures as nothing, like an empty mesh.
fn massOf(ptr: *anyopaque) locus.measure.mass.Mass {
    const src = solidOf(ptr);
    var diag = locus.Diagnostics.init(backend_allocator);
    defer diag.deinit();
    return locus.measure.mass.mass(&src.body, src.options(), &diag) catch .{ .volume = 0, .area = 0, .volume_error = 0, .area_error = 0 };
}

fn volumeImpl(handle: geom.GeometryHandle) f64 {
    return massOf(handle.ptr).volume;
}

fn surfaceAreaImpl(handle: geom.GeometryHandle) f64 {
    return massOf(handle.ptr).area;
}

fn crossSectionAreaImpl(handle: geom.CrossSectionHandle) f64 {
    return massOf(handle.ptr).area;
}

fn crossSectionNumVertsImpl(handle: geom.CrossSectionHandle) usize {
    return solidOf(handle.ptr).body.counts().vertices;
}

/// Locus does not expose sketch contours yet; null tells the caller this engine can't
/// answer, so the user gets a clear error instead of a wrong `false`.
fn crossSectionContainsPointImpl(handle: geom.CrossSectionHandle, pt: [2]f64, tol: f64) ?bool {
    _ = handle;
    _ = pt;
    _ = tol;
    return null;
}

fn crossSectionContoursImpl(handle: geom.CrossSectionHandle, allocator: std.mem.Allocator) ?geom.Contours {
    _ = handle;
    _ = allocator;
    return null;
}

fn crossSectionIsConvexImpl(handle: geom.CrossSectionHandle) ?bool {
    _ = handle;
    return null;
}

fn crossSectionBoundsImpl(handle: geom.CrossSectionHandle) ?geom.Rect2D {
    const box = locus.measure.bbox.bodyBounds(&solidOf(handle.ptr).body) catch return null;
    if (box.isEmpty()) return null;
    return .{ .min = .{ box.min[0], box.min[1] }, .max = .{ box.max[0], box.max[1] } };
}

fn queryFacesImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle, direction: [3]f64, tol: f64) ?[]geom.FaceHandle {
    _ = allocator;
    _ = handle;
    _ = direction;
    _ = tol;
    return null;
}

fn containsPointImpl(allocator: std.mem.Allocator, a: geom.GeometryHandle, config: *const engine_config.EngineConfig, pt: [3]f64) ?bool {
    _ = allocator;
    _ = a;
    _ = config;
    _ = pt;
    return null;
}

fn minGapImpl(a: geom.GeometryHandle, b: geom.GeometryHandle, sl: f64) f64 {
    _ = a;
    _ = b;
    _ = sl;
    return 0;
}

fn rayCastImpl(alloc: std.mem.Allocator, a: geom.GeometryHandle, o: [3]f64, e: [3]f64) ?[]geom.RayHit {
    _ = alloc;
    _ = a;
    _ = o;
    _ = e;
    return null;
}

/// Tessellation is M3's: an empty mesh, as before, so a viewer draws nothing rather than
/// fails (exports refuse through supports(.mesh)).
fn getMeshImpl(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh {
    _ = handle;
    const vert_props = allocator.alloc(f32, 0) catch return null;
    const tri_verts = allocator.alloc(u32, 0) catch {
        allocator.free(vert_props);
        return null;
    };
    return .{ .vert_props = vert_props, .tri_verts = tri_verts, .num_prop = 3 };
}

fn numVertsImpl(handle: geom.GeometryHandle) usize {
    return solidOf(handle.ptr).body.counts().vertices;
}

/// A B-Rep solid has faces, not triangles; a mesh of it exists only once tessellated.
fn numTrisImpl(handle: geom.GeometryHandle) ?usize {
    _ = handle;
    return null;
}

fn simplifyImpl(a: geom.GeometryHandle, tol: f64) ?geom.GeometryHandle {
    _ = tol;
    // No-op for B-Rep, but must still return a NEW handle (single-owner rule, see kernel.zig).
    return cloneImpl(a);
}

fn setMaterialImpl(a: geom.GeometryHandle, material_id: u32) ?geom.GeometryHandle {
    _ = material_id;
    // Materials are not stored on B-Rep solids yet; return a copy, never the input.
    return cloneImpl(a);
}

fn cloneImpl(a: geom.GeometryHandle) ?geom.GeometryHandle {
    const copy = solidOf(a.ptr).clone() catch return null;
    return .{ .engine = .brep_native, .ptr = @ptrCast(copy) };
}

/// A B-Rep sketch is a BrepSolid too, so its copy is a solid's.
fn cloneCrossSectionImpl(a: geom.CrossSectionHandle) ?geom.CrossSectionHandle {
    const copy = cloneImpl(.{ .engine = a.engine, .ptr = a.ptr }) orelse return null;
    return .{ .engine = copy.engine, .ptr = copy.ptr };
}

fn destructImpl(handle: geom.GeometryHandle) void {
    std.debug.assert(handle.engine == .brep_native);
    if (@intFromPtr(handle.ptr) != 0) solidOf(handle.ptr).destroy();
}

fn destructCrossSectionImpl(handle: geom.CrossSectionHandle) void {
    std.debug.assert(handle.engine == .brep_native);
    if (@intFromPtr(handle.ptr) != 0) solidOf(handle.ptr).destroy();
}

/// B-Rep solids are validated by Locus as they are built; there is no deferred status.
fn problemImpl(a: geom.GeometryHandle) ?[]const u8 {
    _ = a;
    return null;
}
