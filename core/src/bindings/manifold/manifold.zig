const std = @import("std");

pub const ManifoldObj = opaque {};
pub const ManifoldBox = opaque {};
pub const ManifoldMeshGL = opaque {};
pub const ManifoldCrossSection = opaque {};
pub const ManifoldPolygons = opaque {};

pub const OpType = enum(c_int) {
    add = 0,
    subtract = 1,
    intersect = 2,
};

pub const JoinType = enum(c_int) {
    square = 0,
    round = 1,
    miter = 2,
    bevel = 3,
};

pub const ManifoldVec3 = extern struct { x: f64, y: f64, z: f64 };
pub const ManifoldManifoldPair = extern struct {
    first: ?*ManifoldObj,
    second: ?*ManifoldObj,
};

extern "C" fn manifold_alloc_manifold() ?*ManifoldObj;
extern "C" fn manifold_delete_manifold(m: ?*ManifoldObj) void;
extern "C" fn manifold_alloc_box() ?*ManifoldBox;
extern "C" fn manifold_delete_box(b: ?*ManifoldBox) void;
extern "C" fn manifold_alloc_meshgl() ?*ManifoldMeshGL;
extern "C" fn manifold_delete_meshgl(m: ?*ManifoldMeshGL) void;
extern "C" fn manifold_alloc_cross_section() ?*ManifoldCrossSection;
extern "C" fn manifold_delete_cross_section(cs: ?*ManifoldCrossSection) void;
extern "C" fn manifold_alloc_polygons() ?*ManifoldPolygons;
extern "C" fn manifold_delete_polygons(p: ?*ManifoldPolygons) void;

extern "C" fn manifold_cube(mem: ?*ManifoldObj, x: f64, y: f64, z: f64, center: c_int) ?*ManifoldObj;
extern "C" fn manifold_cylinder(mem: ?*ManifoldObj, height: f64, radiusLow: f64, radiusHigh: f64, circularSegments: c_int, center: c_int) ?*ManifoldObj;
extern "C" fn manifold_sphere(mem: ?*ManifoldObj, radius: f64, circularSegments: c_int) ?*ManifoldObj;
extern "C" fn manifold_boolean(mem: ?*ManifoldObj, a: ?*ManifoldObj, b: ?*ManifoldObj, op: OpType) ?*ManifoldObj;

extern "C" fn manifold_translate(mem: ?*ManifoldObj, m: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj;
extern "C" fn manifold_rotate(mem: ?*ManifoldObj, m: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj;
extern "C" fn manifold_scale(mem: ?*ManifoldObj, m: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj;

extern "C" fn manifold_mirror(mem: ?*ManifoldObj, m: ?*ManifoldObj, nx: f64, ny: f64, nz: f64) ?*ManifoldObj;
extern "C" fn manifold_hull(mem: ?*ManifoldObj, m: ?*ManifoldObj) ?*ManifoldObj;
extern "C" fn manifold_trim_by_plane(mem: ?*ManifoldObj, m: ?*ManifoldObj, nx: f64, ny: f64, nz: f64, offset: f64) ?*ManifoldObj;
extern "C" fn manifold_split_by_plane(mem_first: ?*ManifoldObj, mem_second: ?*ManifoldObj, m: ?*ManifoldObj, nx: f64, ny: f64, nz: f64, offset: f64) ManifoldManifoldPair;
extern "C" fn manifold_cross_section_boolean(mem: ?*ManifoldCrossSection, a: ?*ManifoldCrossSection, b: ?*ManifoldCrossSection, op: OpType) ?*ManifoldCrossSection;
extern "C" fn manifold_minkowski_sum(mem: ?*ManifoldObj, a: ?*ManifoldObj, b: ?*ManifoldObj) ?*ManifoldObj;
extern "C" fn manifold_cross_section_offset(mem: ?*ManifoldCrossSection, cs: ?*ManifoldCrossSection, delta: f64, jt: JoinType, miter_limit: f64, circular_segments: c_int) ?*ManifoldCrossSection;

extern "C" fn manifold_cross_section_square(mem: ?*ManifoldCrossSection, x: f64, y: f64, center: c_int) ?*ManifoldCrossSection;
extern "C" fn manifold_cross_section_circle(mem: ?*ManifoldCrossSection, radius: f64, circular_segments: c_int) ?*ManifoldCrossSection;
extern "C" fn manifold_cross_section_to_polygons(mem: ?*ManifoldPolygons, cs: ?*ManifoldCrossSection) ?*ManifoldPolygons;
extern "C" fn manifold_cross_section_of_polygons(mem: ?*ManifoldCrossSection, p: ?*ManifoldPolygons) ?*ManifoldCrossSection;

extern "C" fn manifold_extrude(mem: ?*ManifoldObj, cs: ?*ManifoldPolygons, height: f64, slices: c_int, twist_degrees: f64, scale_x: f64, scale_y: f64) ?*ManifoldObj;
extern "C" fn manifold_revolve(mem: ?*ManifoldObj, cs: ?*ManifoldPolygons, circular_segments: c_int, revolve_degrees: f64) ?*ManifoldObj;

extern "C" fn manifold_slice(mem: ?*ManifoldPolygons, m: ?*ManifoldObj, height: f64) ?*ManifoldPolygons;
extern "C" fn manifold_project(mem: ?*ManifoldPolygons, m: ?*ManifoldObj) ?*ManifoldPolygons;

extern "C" fn manifold_bounding_box(mem: ?*ManifoldBox, m: ?*ManifoldObj) ?*ManifoldBox;
extern "C" fn manifold_box_min(b: ?*ManifoldBox) ManifoldVec3;
extern "C" fn manifold_box_max(b: ?*ManifoldBox) ManifoldVec3;
extern "C" fn manifold_volume(m: ?*ManifoldObj) f64;
extern "C" fn manifold_surface_area(m: ?*ManifoldObj) f64;
extern "C" fn manifold_genus(m: ?*ManifoldObj) c_int;

extern "C" fn manifold_get_meshgl(mem: ?*ManifoldMeshGL, m: ?*ManifoldObj) ?*ManifoldMeshGL;
extern "C" fn manifold_meshgl_num_prop(m: ?*ManifoldMeshGL) usize;
extern "C" fn manifold_meshgl_vert_properties_length(m: ?*ManifoldMeshGL) usize;
extern "C" fn manifold_meshgl_tri_length(m: ?*ManifoldMeshGL) usize;
extern "C" fn manifold_meshgl_vert_properties(mem: [*]f32, m: ?*ManifoldMeshGL) [*]f32;
extern "C" fn manifold_meshgl_tri_verts(mem: [*]u32, m: ?*ManifoldMeshGL) [*]u32;

// ==========================================
// Zig Idiomatic Wrappers
// ==========================================

pub fn cube(x: f64, y: f64, z: f64, center: bool) ?*ManifoldObj {
    return manifold_cube(manifold_alloc_manifold(), x, y, z, if (center) 1 else 0);
}

pub fn cylinder(radius: f64, height: f64, center: bool) ?*ManifoldObj {
    return manifold_cylinder(manifold_alloc_manifold(), height, radius, radius, 0, if (center) 1 else 0);
}

pub fn sphere(radius: f64) ?*ManifoldObj {
    return manifold_sphere(manifold_alloc_manifold(), radius, 0);
}

pub fn boolean(a: ?*ManifoldObj, b: ?*ManifoldObj, op: OpType) ?*ManifoldObj {
    return manifold_boolean(manifold_alloc_manifold(), a, b, op);
}

pub fn translate(obj: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj {
    return manifold_translate(manifold_alloc_manifold(), obj, x, y, z);
}

pub fn rotate(obj: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj {
    return manifold_rotate(manifold_alloc_manifold(), obj, x, y, z);
}

pub fn scale(obj: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj {
    return manifold_scale(manifold_alloc_manifold(), obj, x, y, z);
}

pub fn mirror(obj: ?*ManifoldObj, nx: f64, ny: f64, nz: f64) ?*ManifoldObj {
    return manifold_mirror(manifold_alloc_manifold(), obj, nx, ny, nz);
}

pub fn hull(obj: ?*ManifoldObj) ?*ManifoldObj {
    return manifold_hull(manifold_alloc_manifold(), obj);
}

pub fn trimByPlane(obj: ?*ManifoldObj, nx: f64, ny: f64, nz: f64, offset_dist: f64) ?*ManifoldObj {
    return manifold_trim_by_plane(manifold_alloc_manifold(), obj, nx, ny, nz, offset_dist);
}

pub fn splitByPlane(obj: ?*ManifoldObj, nx: f64, ny: f64, nz: f64, offset_dist: f64) [2]?*ManifoldObj {
    const pair = manifold_split_by_plane(manifold_alloc_manifold(), manifold_alloc_manifold(), obj, nx, ny, nz, offset_dist);
    return .{ pair.first, pair.second };
}

pub fn crossSectionBoolean(a: ?*ManifoldCrossSection, b: ?*ManifoldCrossSection, op: OpType) ?*ManifoldCrossSection {
    return manifold_cross_section_boolean(manifold_alloc_cross_section(), a, b, op);
}

pub fn square(x: f64, y: f64, center: bool) ?*ManifoldCrossSection {
    return manifold_cross_section_square(manifold_alloc_cross_section(), x, y, if (center) 1 else 0);
}

pub fn circle(radius: f64, segments: i32) ?*ManifoldCrossSection {
    return manifold_cross_section_circle(manifold_alloc_cross_section(), radius, @intCast(segments));
}

pub fn extrude(cs: ?*ManifoldCrossSection, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?*ManifoldObj {
    const polys = manifold_cross_section_to_polygons(manifold_alloc_polygons(), cs);
    defer manifold_delete_polygons(polys);
    return manifold_extrude(manifold_alloc_manifold(), polys, height, @intCast(slices), twist_degrees, scale_x, scale_y);
}

pub fn revolve(cs: ?*ManifoldCrossSection, segments: i32, revolve_degrees: f64) ?*ManifoldObj {
    const polys = manifold_cross_section_to_polygons(manifold_alloc_polygons(), cs);
    defer manifold_delete_polygons(polys);
    return manifold_revolve(manifold_alloc_manifold(), polys, @intCast(segments), revolve_degrees);
}

pub fn slice(obj: ?*ManifoldObj, height: f64) ?*ManifoldCrossSection {
    const polys = manifold_slice(manifold_alloc_polygons(), obj, height);
    defer manifold_delete_polygons(polys);
    return manifold_cross_section_of_polygons(manifold_alloc_cross_section(), polys);
}

pub fn minkowskiSum(a: ?*ManifoldObj, b: ?*ManifoldObj) ?*ManifoldObj {
    return manifold_minkowski_sum(manifold_alloc_manifold(), a, b);
}

pub fn offset(cs: ?*ManifoldCrossSection, delta: f64, jt: JoinType, miter_limit: f64, circular_segments: i32) ?*ManifoldCrossSection {
    return manifold_cross_section_offset(manifold_alloc_cross_section(), cs, delta, jt, miter_limit, @intCast(circular_segments));
}

pub fn project(obj: ?*ManifoldObj) ?*ManifoldCrossSection {
    const polys = manifold_project(manifold_alloc_polygons(), obj);
    defer manifold_delete_polygons(polys);
    return manifold_cross_section_of_polygons(manifold_alloc_cross_section(), polys);
}

pub fn boundingBox(obj: ?*ManifoldObj) struct { min: [3]f64, max: [3]f64 } {
    const box_mem = manifold_alloc_box();
    defer manifold_delete_box(box_mem);
    const box_ptr = manifold_bounding_box(box_mem, obj);
    if (box_ptr == null) return .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 0 } };
    const min_v = manifold_box_min(box_ptr);
    const max_v = manifold_box_max(box_ptr);
    return .{
        .min = .{ min_v.x, min_v.y, min_v.z },
        .max = .{ max_v.x, max_v.y, max_v.z },
    };
}

pub fn volume(obj: ?*ManifoldObj) f64 {
    return manifold_volume(obj);
}
pub fn surfaceArea(obj: ?*ManifoldObj) f64 {
    return manifold_surface_area(obj);
}
pub fn genus(obj: ?*ManifoldObj) i32 {
    return manifold_genus(obj);
}

pub fn allocMeshGL() ?*ManifoldMeshGL {
    return manifold_alloc_meshgl();
}
pub fn deleteMeshGL(m: ?*ManifoldMeshGL) void {
    manifold_delete_meshgl(m);
}
pub fn getMeshGL(mem: ?*ManifoldMeshGL, m: ?*ManifoldObj) ?*ManifoldMeshGL {
    return manifold_get_meshgl(mem, m);
}
pub fn meshGLNumProp(m: ?*ManifoldMeshGL) usize {
    return manifold_meshgl_num_prop(m);
}
pub fn meshGLVertPropertiesLength(m: ?*ManifoldMeshGL) usize {
    return manifold_meshgl_vert_properties_length(m);
}
pub fn meshGLTriLength(m: ?*ManifoldMeshGL) usize {
    return manifold_meshgl_tri_length(m);
}
pub fn meshGLVertProperties(mem: [*]f32, m: ?*ManifoldMeshGL) [*]f32 {
    return manifold_meshgl_vert_properties(mem, m);
}
pub fn meshGLTriVerts(mem: [*]u32, m: ?*ManifoldMeshGL) [*]u32 {
    return manifold_meshgl_tri_verts(mem, m);
}

pub fn destruct(m: ?*ManifoldObj) void {
    if (m != null) manifold_delete_manifold(m);
}
pub fn destructCrossSection(cs: ?*ManifoldCrossSection) void {
    if (cs != null) manifold_delete_cross_section(cs);
}
