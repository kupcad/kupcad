//! Engine-agnostic geometry kernel facade.
//!
//! OWNERSHIP RULE (single owner): every function here that returns a
//! GeometryHandle / CrossSectionHandle (or a slice of them) returns NEW
//! handles owned by the caller. Input handles are only borrowed: drivers must
//! never return, consume or destroy an input, even on fallback/no-op paths
//! (use clone instead). Violating this makes two owners (e.g. the DAG cache and
//! a GC'd ObjGeometry) destroy the same pointer.
//!
//! ENGINE RULE: operands of multi-input operations must come from the same
//! engine. Mismatches are rejected at runtime (null / 0 result), never via
//! std.debug.assert, which is compiled out in ReleaseFast.

const std = @import("std");
const geom = @import("geometry_handle.zig");
const manifold_driver = @import("engines/manifold/driver.zig");
const brep_driver = @import("engines/brep/driver.zig");
const EngineConfig = @import("../core/engine_config.zig").EngineConfig;

/// Material slots carried on solids (the Manifold engine stores them as a vertex property).
/// Slot 0 is the default material and user material `id` (an index into VM.materials) is
/// slot `id + 1`, so parts without a material never alias the first user material.
pub const DEFAULT_MATERIAL_SLOT: u32 = 0;

pub fn materialSlot(material_id: u32) u32 {
    return material_id + 1;
}

/// What an engine may not have yet. Callers check `supports` before the kernel call, so a
/// script that needs a missing one gets an error naming it, never a generic failure or a
/// stand-in answer (a volume of 0, an untwisted extrusion, an empty mesh).
pub const Feature = enum {
    transform,
    boolean,
    extrude,
    revolve,
    loft,
    sketch_boolean,
    curved_hull,
    sphere,
    cone,
    extrude_twist,
    extrude_scale,
    offset,
    minkowski,
    trim_by_plane,
    slice,
    project,
    decompose,
    volume,
    surface_area,
    genus,
    bounding_box,
    sketch_measure,
    contains_point,
    ray_cast,
    min_gap,
    faces,
    mesh,
    materials,
    /// An empty shape: a union of nothing, an intersection with nothing.
    empty,

    /// What the engine can't do, as it reads after "can't": "the brep engine can't
    /// measure volume yet".
    pub fn describe(self: Feature) []const u8 {
        return switch (self) {
            .empty => "make an empty shape (union([]), an intersection with nothing)",
            .transform => "move, turn, scale or mirror shapes (translate, rotate, scale, mirror, transform)",
            .boolean => "combine solids (union, difference, intersection)",
            .extrude => "extrude sketches",
            .revolve => "revolve sketches",
            .loft => "loft sketches",
            .sketch_boolean => "combine sketches (union, difference, intersection)",
            .curved_hull => "take the hull of a curved solid (a sphere's, a cylinder's)",
            .sphere => "make exact spheres",
            .cone => "make cones (a cylinder with r1 different from r2)",
            .extrude_twist => "twist an extrusion (extrude twist:, helix)",
            .extrude_scale => "taper an extrusion (extrude scale:)",
            .offset => "offset sketches",
            .minkowski => "take Minkowski sums (minkowski, fillet_edges)",
            .trim_by_plane => "cut solids by a plane (trim_by_plane, split_by_plane)",
            .slice => "slice solids",
            .project => "project solids",
            .decompose => "decompose solids into parts",
            .volume => "measure volume",
            .surface_area => "measure surface area",
            .genus => "count holes (genus)",
            .bounding_box => "measure bounding boxes (bbox, align, center, resize)",
            .sketch_measure => "measure sketches (bbox, align, center)",
            .contains_point => "test whether a point is inside (contains?)",
            .ray_cast => "cast rays",
            .min_gap => "measure gaps (min_gap)",
            .faces => "select faces (on_face)",
            .mesh => "tessellate solids for STL, glTF or the viewport (STEP export works)",
            .materials => "keep materials",
        };
    }

    /// The script methods that need the feature, for `kupcad check` to warn before a
    /// B-Rep script runs. Features that depend on the values (a cone, a curved hull) or
    /// come from operators (`a - b`) have none.
    pub fn methods(self: Feature) []const []const u8 {
        return switch (self) {
            .transform => &.{ "translate", "rotate", "scale", "mirror", "transform", "align", "center", "resize" },
            .boolean => &.{ "union", "difference", "intersection" },
            .extrude => &.{ "extrude", "helix" },
            .revolve => &.{ "revolve", "torus" },
            .loft => &.{"loft"},
            .sphere => &.{"sphere"},
            .offset => &.{"offset"},
            .minkowski => &.{ "minkowski", "fillet_edges" },
            .trim_by_plane => &.{ "trim_by_plane", "split_by_plane" },
            .slice => &.{"slice"},
            .project => &.{"project"},
            .decompose => &.{"decompose"},
            .volume => &.{ "volume", "empty?" },
            .surface_area => &.{"surface_area"},
            .genus => &.{"genus"},
            .bounding_box => &.{"bbox"},
            .contains_point => &.{"contains?"},
            .ray_cast => &.{"ray_cast"},
            .min_gap => &.{"min_gap"},
            .faces => &.{"on_face"},
            .mesh => &.{ "export_stl", "export_gltf" },
            .sketch_boolean, .curved_hull, .cone, .extrude_twist, .extrude_scale, .sketch_measure, .materials, .empty => &.{},
        };
    }
};

/// Whether the solid has faces that aren't flat. A mesh has none; a B-Rep sphere or cylinder
/// does, which matters where the engine handles only flat faces (`curved_hull`).
pub inline fn hasCurvedFaces(handle: geom.GeometryHandle) bool {
    return switch (handle.engine) {
        .manifold => false,
        .brep_native => brep_driver.hasCurvedFaces(handle),
    };
}

pub fn supports(engine: geom.EngineType, feature: Feature) bool {
    return switch (engine) {
        .manifold => manifold_driver.supports(feature),
        .brep_native => brep_driver.supports(feature),
    };
}

pub const BooleanOp = enum {
    union_op,
    difference_op,
    intersection_op,
};

fn ReturnType(comptime T: type) type {
    switch (@typeInfo(T)) {
        .@"fn" => |func| return func.return_type.?,
        else => @compileError("Expected function type"),
    }
}

/// True when every handle in `handles` was produced by `engine`.
pub fn allSameEngine(engine: geom.EngineType, handles: []const geom.GeometryHandle) bool {
    for (handles) |h| if (h.engine != engine) return false;
    return true;
}

inline fn dispatch(comptime fn_name: []const u8, handle: anytype, args: anytype) ReturnType(@TypeOf(@field(manifold_driver.driver, fn_name))) {
    switch (handle.engine) {
        .manifold => return @call(.auto, @field(manifold_driver.driver, fn_name), .{handle} ++ args),
        .brep_native => return @call(.auto, @field(brep_driver.driver, fn_name), .{handle} ++ args),
    }
}

// Solids are created under the active config (`CAD.config`); everything derived from one
// keeps the settings it was created with.

/// The solid with nothing in it. Only Manifold has one (kernel.supports(engine, .empty)).
pub inline fn empty(config: *const EngineConfig) ?geom.GeometryHandle {
    return switch (config.engine) {
        .manifold => manifold_driver.driver.emptyFn(),
        .brep_native => null,
    };
}

pub inline fn emptySketch(config: *const EngineConfig) ?geom.CrossSectionHandle {
    return switch (config.engine) {
        .manifold => manifold_driver.driver.emptySketchFn(),
        .brep_native => null,
    };
}

pub inline fn cube(config: *const EngineConfig, x: f64, y: f64, z: f64, center: bool) ?geom.GeometryHandle {
    switch (config.engine) {
        .manifold => return manifold_driver.driver.cubeFn(x, y, z, center),
        .brep_native => return brep_driver.driver.cubeFn(config, x, y, z, center),
    }
}

pub inline fn cylinder(config: *const EngineConfig, r1: f64, r2: f64, height: f64, center: bool, segments: i32) ?geom.GeometryHandle {
    switch (config.engine) {
        .manifold => return manifold_driver.driver.cylinderFn(r1, r2, height, center, segments),
        .brep_native => return brep_driver.driver.cylinderFn(config, r1, r2, height, center, segments),
    }
}

pub inline fn sphere(config: *const EngineConfig, radius: f64, segments: i32) ?geom.GeometryHandle {
    switch (config.engine) {
        .manifold => return manifold_driver.driver.sphereFn(radius, segments),
        .brep_native => return brep_driver.driver.sphereFn(config, radius, segments),
    }
}

pub inline fn square(config: *const EngineConfig, x: f64, y: f64, center: bool) ?geom.CrossSectionHandle {
    switch (config.engine) {
        .manifold => return manifold_driver.driver.squareFn(x, y, center),
        .brep_native => return brep_driver.driver.squareFn(config, x, y, center),
    }
}

pub inline fn circle(config: *const EngineConfig, radius: f64, segments: i32) ?geom.CrossSectionHandle {
    switch (config.engine) {
        .manifold => return manifold_driver.driver.circleFn(radius, segments),
        .brep_native => return brep_driver.driver.circleFn(config, radius, segments),
    }
}

pub inline fn polygon(config: *const EngineConfig, allocator: std.mem.Allocator, pts: [][2]f64) ?geom.CrossSectionHandle {
    switch (config.engine) {
        .manifold => return manifold_driver.driver.polygonFn(allocator, pts),
        .brep_native => return brep_driver.driver.polygonFn(config, allocator, pts),
    }
}

pub inline fn polyhedron(config: *const EngineConfig, allocator: std.mem.Allocator, points: []const [3]f64, faces: []const [3]u32) ?geom.GeometryHandle {
    switch (config.engine) {
        .manifold => return manifold_driver.driver.polyhedronFn(allocator, points, faces),
        .brep_native => return brep_driver.driver.polyhedronFn(config, allocator, points, faces),
    }
}

pub inline fn polygonsEvenOdd(config: *const EngineConfig, allocator: std.mem.Allocator, contours: []const []const [2]f64) ?geom.CrossSectionHandle {
    switch (config.engine) {
        .manifold => return manifold_driver.driver.polygonsEvenOddFn(allocator, contours),
        .brep_native => return brep_driver.driver.polygonsEvenOddFn(config, allocator, contours),
    }
}

pub inline fn translate(handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    return dispatch("translateFn", handle, .{ x, y, z });
}

pub inline fn rotate(handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    return dispatch("rotateFn", handle, .{ x, y, z });
}

pub inline fn scale(handle: geom.GeometryHandle, x: f64, y: f64, z: f64) ?geom.GeometryHandle {
    return dispatch("scaleFn", handle, .{ x, y, z });
}

pub inline fn mirror(handle: geom.GeometryHandle, nx: f64, ny: f64, nz: f64) ?geom.GeometryHandle {
    return dispatch("mirrorFn", handle, .{ nx, ny, nz });
}

pub inline fn transformMatrix(handle: geom.GeometryHandle, mat: [12]f64) ?geom.GeometryHandle {
    return dispatch("transformMatrixFn", handle, .{mat});
}

pub inline fn boolean(a: geom.GeometryHandle, b: geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle {
    if (a.engine != b.engine) return null;
    return dispatch("booleanFn", a, .{ b, op });
}

pub inline fn setMaterial(handle: geom.GeometryHandle, material_id: u32) ?geom.GeometryHandle {
    return dispatch("setMaterialFn", handle, .{material_id});
}

pub inline fn extrude(cs: geom.CrossSectionHandle, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?geom.GeometryHandle {
    return dispatch("extrudeFn", cs, .{ height, slices, twist_degrees, scale_x, scale_y });
}

pub inline fn revolve(cs: geom.CrossSectionHandle, segments: i32, revolve_degrees: f64) ?geom.GeometryHandle {
    return dispatch("revolveFn", cs, .{ segments, revolve_degrees });
}

pub inline fn offset(cs: geom.CrossSectionHandle, delta: f64, join_type: u8) ?geom.CrossSectionHandle {
    return dispatch("offsetFn", cs, .{ delta, join_type });
}

pub inline fn crossSectionBoolean(a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, op: BooleanOp) ?geom.CrossSectionHandle {
    if (a.engine != b.engine) return null;
    return dispatch("crossSectionBooleanFn", a, .{ b, op });
}

pub inline fn crossSectionArea(handle: geom.CrossSectionHandle) f64 {
    return dispatch("crossSectionAreaFn", handle, .{});
}

pub inline fn crossSectionBounds(handle: geom.CrossSectionHandle) geom.Rect2D {
    return dispatch("crossSectionBoundsFn", handle, .{});
}

/// How many vertices a sketch's contours have.
pub inline fn crossSectionNumVerts(handle: geom.CrossSectionHandle) usize {
    return dispatch("crossSectionNumVertsFn", handle, .{});
}

/// Whether `pt` lies in the sketch's region, boundary included (within `tolerance`).
/// Null when the engine cannot answer.
/// Why `handle` is not a valid solid, or null if it is. Every freshly computed result is
/// checked (dag_evaluator), so invalid meshes surface as errors instead of empty exports.
pub inline fn problem(handle: geom.GeometryHandle) ?[]const u8 {
    return dispatch("problemFn", handle, .{});
}

pub inline fn crossSectionContainsPoint(handle: geom.CrossSectionHandle, pt: [2]f64, tolerance: f64) ?bool {
    return dispatch("crossSectionContainsPointFn", handle, .{ pt, tolerance });
}

/// Whether the sketch is a single convex outline; null when the engine can't tell.
pub inline fn crossSectionIsConvex(handle: geom.CrossSectionHandle) ?bool {
    return dispatch("crossSectionIsConvexFn", handle, .{});
}

pub inline fn crossSectionTransform(cs: geom.CrossSectionHandle, mat: [6]f64) ?geom.CrossSectionHandle {
    return dispatch("crossSectionTransformFn", cs, .{mat});
}

pub inline fn hull(handle: geom.GeometryHandle) ?geom.GeometryHandle {
    return dispatch("hullFn", handle, .{});
}

pub inline fn minkowski(a: geom.GeometryHandle, b: geom.GeometryHandle) ?geom.GeometryHandle {
    if (a.engine != b.engine) return null;
    return dispatch("minkowskiFn", a, .{b});
}

pub inline fn trimByPlane(handle: geom.GeometryHandle, nx: f64, ny: f64, nz: f64, offset_dist: f64) ?geom.GeometryHandle {
    return dispatch("trimByPlaneFn", handle, .{ nx, ny, nz, offset_dist });
}

pub inline fn slice(handle: geom.GeometryHandle, height: f64) ?geom.CrossSectionHandle {
    return dispatch("sliceFn", handle, .{height});
}

pub inline fn project(handle: geom.GeometryHandle) ?geom.CrossSectionHandle {
    return dispatch("projectFn", handle, .{});
}

pub inline fn genus(handle: geom.GeometryHandle) i32 {
    return dispatch("genusFn", handle, .{});
}

pub inline fn boundingBox(handle: geom.GeometryHandle) ?geom.BoundingBox {
    return dispatch("boundingBoxFn", handle, .{});
}

pub inline fn volume(handle: geom.GeometryHandle) f64 {
    return dispatch("volumeFn", handle, .{});
}

pub inline fn surfaceArea(handle: geom.GeometryHandle) f64 {
    return dispatch("surfaceAreaFn", handle, .{});
}

pub inline fn containsPoint(handle: geom.GeometryHandle, pt: [3]f64) bool {
    return dispatch("containsPointFn", handle, .{pt});
}

pub inline fn minGap(a: geom.GeometryHandle, b: geom.GeometryHandle, sl: f64) f64 {
    if (a.engine != b.engine) return 0.0;
    return dispatch("minGapFn", a, .{ b, sl });
}

pub inline fn numVerts(handle: geom.GeometryHandle) usize {
    return dispatch("numVertsFn", handle, .{});
}

/// How many triangles the solid's mesh has, without building the mesh; null for an engine
/// that has no mesh of its own (kernel.supports(engine, .mesh)).
pub inline fn numTris(handle: geom.GeometryHandle) ?usize {
    return dispatch("numTrisFn", handle, .{});
}

/// Feeds `handle`'s mesh (positions and triangles) to `hasher`; false when the engine
/// has no mesh of it (supports(engine, .mesh)).
pub fn hashMesh(hasher: *std.hash.Wyhash, allocator: std.mem.Allocator, handle: geom.GeometryHandle) error{MeshExtractionFailed}!bool {
    if (!supports(handle.engine, .mesh)) return false;
    const mesh = getMesh(allocator, handle) orelse return error.MeshExtractionFailed;
    defer allocator.free(mesh.vert_props);
    defer allocator.free(mesh.tri_verts);
    hasher.update(std.mem.sliceAsBytes(mesh.vert_props));
    hasher.update(std.mem.sliceAsBytes(mesh.tri_verts));
    return true;
}

/// Deep copy; the caller owns the returned handle.
pub inline fn clone(handle: geom.GeometryHandle) ?geom.GeometryHandle {
    return dispatch("cloneFn", handle, .{});
}

pub fn destruct(handle: geom.GeometryHandle) void {
    dispatch("destructFn", handle, .{});
}

pub inline fn destructCrossSection(handle: geom.CrossSectionHandle) void {
    dispatch("destructCrossSectionFn", handle, .{});
}

pub inline fn batchBoolean(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle, op: BooleanOp) ?geom.GeometryHandle {
    if (objs.len == 0) return null;
    // A single operand still yields a fresh handle (single-owner rule).
    if (objs.len == 1) return clone(objs[0]);
    if (!allSameEngine(objs[0].engine, objs)) return null;

    switch (objs[0].engine) {
        .manifold => return manifold_driver.driver.batchBooleanFn(allocator, objs, op),
        .brep_native => return brep_driver.driver.batchBooleanFn(allocator, objs, op),
    }
}

pub inline fn batchHull(allocator: std.mem.Allocator, objs: []const geom.GeometryHandle) ?geom.GeometryHandle {
    if (objs.len == 0) return null;
    if (objs.len == 1) return hull(objs[0]);
    if (!allSameEngine(objs[0].engine, objs)) return null;

    switch (objs[0].engine) {
        .manifold => return manifold_driver.driver.batchHullFn(allocator, objs),
        .brep_native => return brep_driver.driver.batchHullFn(allocator, objs),
    }
}

pub inline fn loft(engine: geom.EngineType, allocator: std.mem.Allocator, a: geom.CrossSectionHandle, b: geom.CrossSectionHandle, height: f64) ?geom.GeometryHandle {
    if (a.engine != engine or b.engine != engine) return null;
    switch (engine) {
        .manifold => return manifold_driver.driver.loftFn(allocator, a, b, height),
        .brep_native => return brep_driver.driver.loftFn(allocator, a, b, height),
    }
}

pub inline fn decompose(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?[]geom.GeometryHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.driver.decomposeFn(allocator, handle),
        .brep_native => return brep_driver.driver.decomposeFn(allocator, handle),
    }
}

/// Returns a new simplified handle, falling back to a copy of the input if
/// simplification fails; null only if even the copy fails.
pub inline fn simplify(handle: geom.GeometryHandle, tolerance: f64) ?geom.GeometryHandle {
    return dispatch("simplifyFn", handle, .{tolerance}) orelse clone(handle);
}

pub inline fn queryFaces(allocator: std.mem.Allocator, handle: geom.GeometryHandle, direction: [3]f64, tolerance: f64) ?[]geom.FaceHandle {
    switch (handle.engine) {
        .manifold => return manifold_driver.driver.queryFacesFn(allocator, handle, direction, tolerance),
        .brep_native => return brep_driver.driver.queryFacesFn(allocator, handle, direction, tolerance),
    }
}

pub inline fn rayCast(alloc: std.mem.Allocator, handle: geom.GeometryHandle, o: [3]f64, e: [3]f64) ?[]geom.RayHit {
    switch (handle.engine) {
        .manifold => return manifold_driver.driver.rayCastFn(alloc, handle, o, e),
        .brep_native => return brep_driver.driver.rayCastFn(alloc, handle, o, e),
    }
}

pub inline fn getMesh(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ?geom.Mesh {
    switch (handle.engine) {
        .manifold => return manifold_driver.driver.getMeshFn(allocator, handle),
        .brep_native => return brep_driver.driver.getMeshFn(allocator, handle),
    }
}

pub fn exportStep(allocator: std.mem.Allocator, handles: []const geom.GeometryHandle) ![]const u8 {
    return brep_driver.exportStep(allocator, handles);
}
