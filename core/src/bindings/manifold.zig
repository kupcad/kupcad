const std = @import("std");
const geom = @import("../kernel/geometry_handle.zig");

pub const ManifoldObj = opaque {};
pub const ManifoldBox = opaque {};
pub const ManifoldMeshGL = opaque {};
pub const ManifoldCrossSection = opaque {};
pub const ManifoldPolygons = opaque {};
pub const ManifoldSimplePolygon = opaque {};
pub const ManifoldVecObj = opaque {};

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

pub const ManifoldVec2 = extern struct { x: f32, y: f32 };
pub const ManifoldVec3 = extern struct { x: f32, y: f32, z: f32 };
pub const ManifoldManifoldPair = extern struct {
    first: ?*ManifoldObj,
    second: ?*ManifoldObj,
};

pub const ManifoldRect = extern struct {
    min: ManifoldVec2,
    max: ManifoldVec2,
};

pub const ManifoldRayHitVec = opaque {};
pub const ManifoldRayHit = extern struct {
    face_id: u64,
    distance: f32,
    position: ManifoldVec3,
    normal: ManifoldVec3,
};

extern fn manifold_alloc_manifold() ?*ManifoldObj;
extern fn manifold_delete_manifold(m: ?*ManifoldObj) void;
extern fn manifold_alloc_box() ?*ManifoldBox;
extern fn manifold_delete_box(b: ?*ManifoldBox) void;
extern fn manifold_alloc_meshgl() ?*ManifoldMeshGL;
extern fn manifold_delete_meshgl(m: ?*ManifoldMeshGL) void;
extern fn manifold_alloc_cross_section() ?*ManifoldCrossSection;
extern fn manifold_delete_cross_section(cs: ?*ManifoldCrossSection) void;
extern fn manifold_alloc_polygons() ?*ManifoldPolygons;
extern fn manifold_delete_polygons(p: ?*ManifoldPolygons) void;
extern fn manifold_alloc_manifold_vec() ?*ManifoldVecObj;
extern fn manifold_destruct_manifold_vec(ms: ?*ManifoldVecObj) void;
extern fn manifold_manifold_vec_push_back(ms: ?*ManifoldVecObj, m: ?*ManifoldObj) void;
extern fn manifold_manifold_vec_length(ms: ?*ManifoldVecObj) usize;
extern fn manifold_manifold_vec_get(mem: ?*ManifoldObj, ms: ?*ManifoldVecObj, idx: usize) ?*ManifoldObj;

extern fn manifold_cube(mem: ?*ManifoldObj, x: f32, y: f32, z: f32, center: c_int) ?*ManifoldObj;
extern fn manifold_cylinder(mem: ?*ManifoldObj, height: f32, radiusLow: f32, radiusHigh: f32, circularSegments: c_int, center: c_int) ?*ManifoldObj;
extern fn manifold_sphere(mem: ?*ManifoldObj, radius: f32, circularSegments: c_int) ?*ManifoldObj;
extern fn manifold_boolean(mem: ?*ManifoldObj, a: ?*ManifoldObj, b: ?*ManifoldObj, op: OpType) ?*ManifoldObj;
extern fn manifold_batch_boolean(mem: ?*ManifoldObj, ms: ?*ManifoldVecObj, op: OpType) ?*ManifoldObj;

extern fn manifold_translate(mem: ?*ManifoldObj, m: ?*ManifoldObj, x: f32, y: f32, z: f32) ?*ManifoldObj;
extern fn manifold_rotate(mem: ?*ManifoldObj, m: ?*ManifoldObj, x: f32, y: f32, z: f32) ?*ManifoldObj;
extern fn manifold_scale(mem: ?*ManifoldObj, m: ?*ManifoldObj, x: f32, y: f32, z: f32) ?*ManifoldObj;

extern fn manifold_mirror(mem: ?*ManifoldObj, m: ?*ManifoldObj, nx: f32, ny: f32, nz: f32) ?*ManifoldObj;
extern fn manifold_hull(mem: ?*ManifoldObj, m: ?*ManifoldObj) ?*ManifoldObj;
extern fn manifold_batch_hull(mem: ?*ManifoldObj, ms: ?*ManifoldVecObj) ?*ManifoldObj;
extern fn manifold_trim_by_plane(mem: ?*ManifoldObj, m: ?*ManifoldObj, nx: f32, ny: f32, nz: f32, offset: f32) ?*ManifoldObj;
extern fn manifold_split_by_plane(mem_first: ?*ManifoldObj, mem_second: ?*ManifoldObj, m: ?*ManifoldObj, nx: f32, ny: f32, nz: f32, offset: f32) ManifoldManifoldPair;
extern fn manifold_cross_section_boolean(mem: ?*ManifoldCrossSection, a: ?*ManifoldCrossSection, b: ?*ManifoldCrossSection, op: OpType) ?*ManifoldCrossSection;
extern fn manifold_minkowski_sum(mem: ?*ManifoldObj, a: ?*ManifoldObj, b: ?*ManifoldObj) ?*ManifoldObj;
extern fn manifold_cross_section_offset(mem: ?*ManifoldCrossSection, cs: ?*ManifoldCrossSection, delta: f32, jt: JoinType, miter_limit: f32, circular_segments: c_int) ?*ManifoldCrossSection;

extern fn manifold_cross_section_square(mem: ?*ManifoldCrossSection, x: f32, y: f32, center: c_int) ?*ManifoldCrossSection;
extern fn manifold_cross_section_circle(mem: ?*ManifoldCrossSection, radius: f32, circular_segments: c_int) ?*ManifoldCrossSection;
extern fn manifold_cross_section_to_polygons(mem: ?*ManifoldPolygons, cs: ?*ManifoldCrossSection) ?*ManifoldPolygons;
extern fn manifold_cross_section_of_polygons(mem: ?*ManifoldCrossSection, p: ?*ManifoldPolygons) ?*ManifoldCrossSection;
extern fn manifold_cross_section_area(cs: ?*const anyopaque) f32;
extern fn manifold_cross_section_bounds(cs: ?*const anyopaque) ManifoldRect;

extern fn manifold_transform(mem: ?*ManifoldObj, m: ?*ManifoldObj, x1: f32, y1: f32, z1: f32, x2: f32, y2: f32, z2: f32, x3: f32, y3: f32, z3: f32, x4: f32, y4: f32, z4: f32) ?*ManifoldObj;
extern fn manifold_cross_section_transform(mem: ?*ManifoldCrossSection, cs: ?*ManifoldCrossSection, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) ?*ManifoldCrossSection;

extern fn manifold_extrude(mem: ?*ManifoldObj, cs: ?*ManifoldPolygons, height: f32, slices: c_int, twist_degrees: f32, scale_x: f32, scale_y: f32) ?*ManifoldObj;
extern fn manifold_revolve(mem: ?*ManifoldObj, cs: ?*ManifoldPolygons, circular_segments: c_int, revolve_degrees: f32) ?*ManifoldObj;

extern fn manifold_slice(mem: ?*ManifoldPolygons, m: ?*ManifoldObj, height: f32) ?*ManifoldPolygons;
extern fn manifold_project(mem: ?*ManifoldPolygons, m: ?*ManifoldObj) ?*ManifoldPolygons;

extern fn manifold_bounding_box(mem: ?*ManifoldBox, m: ?*ManifoldObj) ?*ManifoldBox;
extern fn manifold_box_min(b: ?*ManifoldBox) ManifoldVec3;
extern fn manifold_box_max(b: ?*ManifoldBox) ManifoldVec3;
extern fn manifold_volume(m: ?*ManifoldObj) f32;
extern fn manifold_surface_area(m: ?*ManifoldObj) f32;
extern fn manifold_genus(m: ?*ManifoldObj) c_int;
extern fn manifold_decompose(mem: ?*ManifoldVecObj, m: ?*ManifoldObj) ?*ManifoldVecObj;

extern fn manifold_meshgl(mem: ?*ManifoldMeshGL, vert_props: [*]const f32, num_verts: usize, num_prop: usize, tri_verts: [*]const u32, num_tris: usize) ?*ManifoldMeshGL;
extern fn manifold_get_meshgl(mem: ?*ManifoldMeshGL, m: ?*ManifoldObj) ?*ManifoldMeshGL;
extern fn manifold_meshgl_num_prop(m: ?*ManifoldMeshGL) usize;
extern fn manifold_meshgl_vert_properties_length(m: ?*ManifoldMeshGL) usize;
extern fn manifold_meshgl_tri_length(m: ?*ManifoldMeshGL) usize;
extern fn manifold_meshgl_vert_properties(mem: [*]f32, m: ?*ManifoldMeshGL) [*]f32;
extern fn manifold_meshgl_tri_verts(mem: [*]u32, m: ?*ManifoldMeshGL) [*]u32;
extern fn manifold_of_meshgl(mem: ?*ManifoldObj, mesh: ?*ManifoldMeshGL) ?*ManifoldObj;

extern fn manifold_alloc_ray_hit_vec() ?*ManifoldRayHitVec;
extern fn manifold_delete_ray_hit_vec(v: ?*ManifoldRayHitVec) void;
extern fn manifold_ray_cast(mem: ?*ManifoldRayHitVec, m: ?*ManifoldObj, origin_x: f32, origin_y: f32, origin_z: f32, end_x: f32, end_y: f32, end_z: f32) ?*ManifoldRayHitVec;
extern fn manifold_ray_hit_vec_length(v: ?*ManifoldRayHitVec) usize;
extern fn manifold_ray_hit_vec_get(v: ?*ManifoldRayHitVec, idx: usize) ManifoldRayHit;
extern fn manifold_min_gap(m: ?*ManifoldObj, other: ?*ManifoldObj, searchLength: f32) f32;
extern fn manifold_winding_number(m: ?*ManifoldObj, x: f32, y: f32, z: f32) c_int;

extern fn manifold_simple_polygon(mem: ?*ManifoldSimplePolygon, ps: [*]const ManifoldVec2, length: usize) ?*ManifoldSimplePolygon;
extern fn manifold_polygons(mem: ?*ManifoldPolygons, ps: [*]?*ManifoldSimplePolygon, length: usize) ?*ManifoldPolygons;
extern fn manifold_alloc_simple_polygon() ?*ManifoldSimplePolygon;
extern fn manifold_delete_simple_polygon(p: ?*ManifoldSimplePolygon) void;
extern fn manifold_cross_section_of_simple_polygon(mem: ?*ManifoldCrossSection, p: ?*ManifoldSimplePolygon) ?*ManifoldCrossSection;
extern fn manifold_cross_section_even_odd_polygons(mem: ?*ManifoldCrossSection, p: ?*ManifoldPolygons) ?*ManifoldCrossSection;

extern fn manifold_simplify(mem: ?*ManifoldObj, manifold: *ManifoldObj, tolerance: f32) ?*ManifoldObj;

extern fn manifold_set_properties(mem: ?*ManifoldObj, m: ?*ManifoldObj, newNumProp: c_int, propFunc: *const fn ([*]f32, ManifoldVec3, [*]const f32, ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) ?*ManifoldObj;

// ==========================================
// Zig Idiomatic Wrappers
// ==========================================

pub fn cube(x: f64, y: f64, z: f64, center: bool) ?*ManifoldObj {
    return manifold_cube(manifold_alloc_manifold(), @floatCast(x), @floatCast(y), @floatCast(z), if (center) 1 else 0);
}

pub fn cylinder(r1: f64, r2: f64, height: f64, center: bool, segments: i32) ?*ManifoldObj {
    return manifold_cylinder(manifold_alloc_manifold(), @floatCast(height), @floatCast(r1), @floatCast(r2), @intCast(segments), if (center) 1 else 0);
}

pub fn sphere(radius: f64) ?*ManifoldObj {
    return manifold_sphere(manifold_alloc_manifold(), @floatCast(radius), 0);
}

pub fn boolean(a: ?*ManifoldObj, b: ?*ManifoldObj, op: OpType) ?*ManifoldObj {
    return manifold_boolean(manifold_alloc_manifold(), a, b, op);
}

pub fn batchBoolean(objs: []const ?*ManifoldObj, op: OpType) ?*ManifoldObj {
    if (objs.len == 0) return null;

    const vec = manifold_alloc_manifold_vec();
    defer manifold_destruct_manifold_vec(vec);

    for (objs) |obj| {
        if (obj != null) {
            manifold_manifold_vec_push_back(vec, obj);
        }
    }

    return manifold_batch_boolean(manifold_alloc_manifold(), vec, op);
}

pub fn translate(obj: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj {
    return manifold_translate(manifold_alloc_manifold(), obj, @floatCast(x), @floatCast(y), @floatCast(z));
}

pub fn rotate(obj: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj {
    return manifold_rotate(manifold_alloc_manifold(), obj, @floatCast(x), @floatCast(y), @floatCast(z));
}

pub fn scale(obj: ?*ManifoldObj, x: f64, y: f64, z: f64) ?*ManifoldObj {
    return manifold_scale(manifold_alloc_manifold(), obj, @floatCast(x), @floatCast(y), @floatCast(z));
}

pub fn mirror(obj: ?*ManifoldObj, nx: f64, ny: f64, nz: f64) ?*ManifoldObj {
    return manifold_mirror(manifold_alloc_manifold(), obj, @floatCast(nx), @floatCast(ny), @floatCast(nz));
}

pub fn hull(obj: ?*ManifoldObj) ?*ManifoldObj {
    return manifold_hull(manifold_alloc_manifold(), obj);
}

pub fn batchHull(objs: []const ?*ManifoldObj) ?*ManifoldObj {
    if (objs.len == 0) return null;

    const vec = manifold_alloc_manifold_vec();
    defer manifold_destruct_manifold_vec(vec);

    for (objs) |obj| {
        if (obj != null) {
            manifold_manifold_vec_push_back(vec, obj);
        }
    }

    return manifold_batch_hull(manifold_alloc_manifold(), vec);
}

pub fn manifoldVecLength(ms: ?*ManifoldVecObj) usize {
    return manifold_manifold_vec_length(ms);
}

pub fn manifoldVecGet(ms: ?*ManifoldVecObj, idx: usize) ?*ManifoldObj {
    return manifold_manifold_vec_get(manifold_alloc_manifold(), ms, idx);
}

pub fn decompose(obj: ?*ManifoldObj) ?*ManifoldVecObj {
    return manifold_decompose(manifold_alloc_manifold_vec(), obj);
}

pub fn trimByPlane(obj: ?*ManifoldObj, nx: f64, ny: f64, nz: f64, offset_dist: f64) ?*ManifoldObj {
    return manifold_trim_by_plane(manifold_alloc_manifold(), obj, @floatCast(nx), @floatCast(ny), @floatCast(nz), @floatCast(offset_dist));
}

pub fn splitByPlane(obj: ?*ManifoldObj, nx: f64, ny: f64, nz: f64, offset_dist: f64) [2]?*ManifoldObj {
    const pair = manifold_split_by_plane(manifold_alloc_manifold(), manifold_alloc_manifold(), obj, @floatCast(nx), @floatCast(ny), @floatCast(nz), @floatCast(offset_dist));
    return .{ pair.first, pair.second };
}

pub fn crossSectionBoolean(a: ?*ManifoldCrossSection, b: ?*ManifoldCrossSection, op: OpType) ?*ManifoldCrossSection {
    return manifold_cross_section_boolean(manifold_alloc_cross_section(), a, b, op);
}

pub fn square(x: f64, y: f64, center: bool) ?*ManifoldCrossSection {
    return manifold_cross_section_square(manifold_alloc_cross_section(), @floatCast(x), @floatCast(y), if (center) 1 else 0);
}

pub fn circle(radius: f64, segments: i32) ?*ManifoldCrossSection {
    return manifold_cross_section_circle(manifold_alloc_cross_section(), @floatCast(radius), @intCast(segments));
}

pub fn polyhedron(vert_props: []const f32, tri_verts: []const u32) ?*ManifoldObj {
    const mesh_mem = manifold_alloc_meshgl();
    defer manifold_delete_meshgl(mesh_mem);

    // num_prop = 3 (x, y, z)
    const mesh = manifold_meshgl(mesh_mem, vert_props.ptr, vert_props.len / 3, 3, tri_verts.ptr, tri_verts.len / 3);
    return manifold_of_meshgl(manifold_alloc_manifold(), mesh);
}

pub fn simplify(obj: ?*ManifoldObj, tolerance: f64) ?*ManifoldObj {
    if (obj == null) return null;

    return manifold_simplify(manifold_alloc_manifold(), obj.?, @floatCast(tolerance));
}

pub fn crossSectionEvenOddPolygons(allocator: std.mem.Allocator, contours: []const []const ManifoldVec2) ?*ManifoldCrossSection {
    var simple_polys = allocator.alloc(?*ManifoldSimplePolygon, contours.len) catch return null;
    defer allocator.free(simple_polys);

    // Convert each slice of ManifoldVec2 into a ManifoldSimplePolygon
    for (contours, 0..) |contour, i| {
        simple_polys[i] = manifold_simple_polygon(manifold_alloc_simple_polygon(), contour.ptr, contour.len);
    }

    // Ensure all simple polygons are cleaned up after constructing the composite polygon
    defer {
        for (simple_polys) |sp| manifold_delete_simple_polygon(sp);
    }

    // Build the composite polygon array
    const m_polys = manifold_polygons(manifold_alloc_polygons(), simple_polys.ptr, simple_polys.len);
    defer manifold_delete_polygons(m_polys);

    // Apply the Even-Odd winding rule to resolve holes
    return manifold_cross_section_even_odd_polygons(manifold_alloc_cross_section(), m_polys);
}

pub fn setProperties(
    obj: ?*ManifoldObj,
    num_prop: i32,
    prop_func: *const fn ([*]f32, ManifoldVec3, [*]const f32, ?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
) ?*ManifoldObj {
    return manifold_set_properties(manifold_alloc_manifold(), obj, @intCast(num_prop), prop_func, ctx);
}

pub fn transform(obj: ?*ManifoldObj, x1: f64, y1: f64, z1: f64, x2: f64, y2: f64, z2: f64, x3: f64, y3: f64, z3: f64, x4: f64, y4: f64, z4: f64) ?*ManifoldObj {
    return manifold_transform(manifold_alloc_manifold(), obj, @floatCast(x1), @floatCast(y1), @floatCast(z1), @floatCast(x2), @floatCast(y2), @floatCast(z2), @floatCast(x3), @floatCast(y3), @floatCast(z3), @floatCast(x4), @floatCast(y4), @floatCast(z4));
}
pub fn crossSectionTransform(cs: ?*ManifoldCrossSection, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) ?*ManifoldCrossSection {
    return manifold_cross_section_transform(manifold_alloc_cross_section(), cs, @floatCast(x1), @floatCast(y1), @floatCast(x2), @floatCast(y2), @floatCast(x3), @floatCast(y3));
}

pub fn crossSectionArea(cs: ?*const anyopaque) f64 {
    return @floatCast(manifold_cross_section_area(cs));
}

pub fn crossSectionBounds(cs: ?*const anyopaque) ManifoldRect {
    return manifold_cross_section_bounds(cs);
}

pub fn extrude(cs: ?*ManifoldCrossSection, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) ?*ManifoldObj {
    const polys = manifold_cross_section_to_polygons(manifold_alloc_polygons(), cs);
    defer manifold_delete_polygons(polys);
    return manifold_extrude(manifold_alloc_manifold(), polys, @floatCast(height), @intCast(slices), @floatCast(twist_degrees), @floatCast(scale_x), @floatCast(scale_y));
}

pub fn revolve(cs: ?*ManifoldCrossSection, segments: i32, revolve_degrees: f64) ?*ManifoldObj {
    const polys = manifold_cross_section_to_polygons(manifold_alloc_polygons(), cs);
    defer manifold_delete_polygons(polys);
    return manifold_revolve(manifold_alloc_manifold(), polys, @intCast(segments), @floatCast(revolve_degrees));
}

pub fn slice(obj: ?*ManifoldObj, height: f64) ?*ManifoldCrossSection {
    const polys = manifold_slice(manifold_alloc_polygons(), obj, @floatCast(height));
    defer manifold_delete_polygons(polys);
    return manifold_cross_section_of_polygons(manifold_alloc_cross_section(), polys);
}

pub fn minkowskiSum(a: ?*ManifoldObj, b: ?*ManifoldObj) ?*ManifoldObj {
    return manifold_minkowski_sum(manifold_alloc_manifold(), a, b);
}

pub fn offset(cs: ?*ManifoldCrossSection, delta: f64, jt: JoinType, miter_limit: f64, circular_segments: i32) ?*ManifoldCrossSection {
    return manifold_cross_section_offset(manifold_alloc_cross_section(), cs, @floatCast(delta), jt, @floatCast(miter_limit), @intCast(circular_segments));
}

pub fn minGap(m: ?*ManifoldObj, other: ?*ManifoldObj, search_length: f64) f64 {
    return @floatCast(manifold_min_gap(m, other, @floatCast(search_length)));
}

pub fn containsPoint(m: ?*ManifoldObj, x: f64, y: f64, z: f64) bool {
    // A non-zero winding number indicates the point is inside the solid geometry
    return manifold_winding_number(m, @floatCast(x), @floatCast(y), @floatCast(z)) != 0;
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
        .min = .{ @floatCast(min_v.x), @floatCast(min_v.y), @floatCast(min_v.z) },
        .max = .{ @floatCast(max_v.x), @floatCast(max_v.y), @floatCast(max_v.z) },
    };
}

pub fn volume(obj: ?*ManifoldObj) f64 {
    return @floatCast(manifold_volume(obj));
}
pub fn surfaceArea(obj: ?*ManifoldObj) f64 {
    return @floatCast(manifold_surface_area(obj));
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

pub fn rayCast(allocator: std.mem.Allocator, m: ?*ManifoldObj, ox: f64, oy: f64, oz: f64, ex: f64, ey: f64, ez: f64) ?[]geom.RayHit {
    const vec = manifold_ray_cast(manifold_alloc_ray_hit_vec(), m, @floatCast(ox), @floatCast(oy), @floatCast(oz), @floatCast(ex), @floatCast(ey), @floatCast(ez));
    defer if (vec != null) manifold_delete_ray_hit_vec(vec);
    if (vec == null) return null;

    const len = manifold_ray_hit_vec_length(vec);
    const hits = allocator.alloc(geom.RayHit, len) catch return null;

    // Calculate total ray length for metric conversion
    const dx = ex - ox;
    const dy = ey - oy;
    const dz = ez - oz;
    const ray_length = @sqrt(dx * dx + dy * dy + dz * dz);

    for (0..len) |i| {
        const h = manifold_ray_hit_vec_get(vec, i);
        hits[i] = .{
            .distance = @as(f64, @floatCast(h.distance)) * ray_length, // Scale normalized fraction to metric world distance!
            .position = .{ @floatCast(h.position.x), @floatCast(h.position.y), @floatCast(h.position.z) },
            .normal = .{ @floatCast(h.normal.x), @floatCast(h.normal.y), @floatCast(h.normal.z) },
        };
    }
    return hits;
}

pub fn polygon(points: []const ManifoldVec2) ?*ManifoldCrossSection {
    const p = manifold_simple_polygon(manifold_alloc_simple_polygon(), points.ptr, points.len);
    defer manifold_delete_simple_polygon(p);
    return manifold_cross_section_of_simple_polygon(manifold_alloc_cross_section(), p);
}

pub fn destruct(m: ?*ManifoldObj) void {
    if (m != null) manifold_delete_manifold(m);
}
pub fn destructCrossSection(cs: ?*ManifoldCrossSection) void {
    if (cs != null) manifold_delete_cross_section(cs);
}
pub fn destructManifoldVec(ms: ?*ManifoldVecObj) void {
    if (ms != null) manifold_destruct_manifold_vec(ms);
}
