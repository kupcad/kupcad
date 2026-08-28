const std = @import("std");
const driver = @import("driver.zig");
const kernel = @import("../../kernel.zig");
const geom = @import("../../geometry_handle.zig");

test "Driver: End-to-End API Calls" {
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const cyl_handle = driver.driver.cylinderFn(5, 5, 15, true, 32) orelse return error.CylinderFailed;
    defer driver.driver.destructFn(cyl_handle);

    const sphere_handle = driver.driver.sphereFn(5) orelse return error.SphereFailed;
    defer driver.driver.destructFn(sphere_handle);

    _ = driver.driver.translateFn(cube_handle, 10.0, 0.0, 0.0) orelse return error.TranslateFailed;

    const mesh_data = driver.driver.getMeshFn(std.testing.allocator, cube_handle) orelse return error.MeshingFailed;
    defer std.testing.allocator.free(mesh_data.vert_props);
    defer std.testing.allocator.free(mesh_data.tri_verts);

    try std.testing.expect(mesh_data.vert_props.len > 0);
}

test "Driver: Measurements (Volume, Surface Area, Bounding Box, Contains)" {
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const bbox = driver.driver.boundingBoxFn(cube_handle) orelse return error.BBoxFailed;
    try std.testing.expectApproxEqAbs(-5.0, bbox.min[0], 1e-6);
    try std.testing.expectApproxEqAbs(5.0, bbox.max[0], 1e-6);

    const vol = driver.driver.volumeFn(cube_handle);
    try std.testing.expectApproxEqAbs(1000.0, vol, 1e-6);

    const area = driver.driver.surfaceAreaFn(cube_handle);
    try std.testing.expectApproxEqAbs(600.0, area, 1e-6);

    const is_inside = driver.driver.containsPointFn(cube_handle, .{ 0, 0, 0 });
    const is_outside = driver.driver.containsPointFn(cube_handle, .{ 20, 0, 0 });
    try std.testing.expect(is_inside);
    try std.testing.expect(!is_outside);
}

test "Driver: Custom Matrix Transformations" {
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const translation_matrix = [12]f64{
        1, 0, 0, 20,
        0, 1, 0, 0,
        0, 0, 1, 0,
    };
    _ = driver.driver.transformMatrixFn(cube_handle, translation_matrix) orelse return error.TransformFailed;

    const bbox = driver.driver.boundingBoxFn(cube_handle) orelse return error.BBoxFailed;
    try std.testing.expectApproxEqAbs(25.0, bbox.max[0], 1e-6);
}

test "Driver: Trim by Plane (Half-Space Slicing)" {
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    _ = driver.driver.trimByPlaneFn(cube_handle, 0, 0, 1, 0.0) orelse return error.TrimFailed;

    const bbox = driver.driver.boundingBoxFn(cube_handle) orelse return error.BBoxFailed;
    try std.testing.expectApproxEqAbs(0.0, bbox.max[2], 1e-6);
    try std.testing.expectApproxEqAbs(-5.0, bbox.min[2], 1e-6);

    const vol = driver.driver.volumeFn(cube_handle);
    try std.testing.expectApproxEqAbs(500.0, vol, 1e-5);
}

test "Driver: Polyhedron Import (Mesh to B-Rep)" {
    const pts = [_][3]f64{
        .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 },
    };
    const faces = [_][3]u32{
        .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 4 },
    };
    const poly_handle = driver.driver.polyhedronFn(std.testing.allocator, &pts, &faces) orelse return error.PolyhedronFailed;
    defer driver.driver.destructFn(poly_handle);

    try std.testing.expectApproxEqAbs(333.333333, driver.driver.volumeFn(poly_handle), 1e-4);
}

test "Driver: Revolve 2D Profile" {
    const cs_handle = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(cs_handle);

    // Revolve creates a new disjoint solid, so we destruct both
    const rev_handle = driver.driver.revolveFn(cs_handle, 36, 360.0) orelse return error.RevolveFailed;
    defer driver.driver.destructFn(rev_handle);

    const expected_area = 1800.0 * @sin(10.0 * std.math.pi / 180.0);
    const expected_vol = expected_area * 10.0;
    try std.testing.expectApproxEqAbs(expected_vol, driver.driver.volumeFn(rev_handle), 1e-4);
}

test "Driver: 2D Operations (Boolean, Transform)" {
    const sq1 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    const sq2 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    // B merges into A, so B still exists independently and must be destructed
    defer driver.driver.destructCrossSectionFn(sq2);

    const mat = [6]f64{ 1, 0, 5, 0, 1, 5 };
    _ = driver.driver.crossSectionTransformFn(sq2, mat) orelse return error.TransformFailed;

    const union_2d = driver.driver.crossSectionBooleanFn(sq1, sq2, .union_op) orelse return error.BooleanFailed;

    // Extrude reuses `union_2d` (which is `sq1`) in place. Defer once on the final output!
    const final_solid = driver.driver.extrudeFn(union_2d, 10, 0, 0, 1, 1) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(final_solid);

    try std.testing.expectApproxEqAbs(1750.0, driver.driver.volumeFn(final_solid), 1e-4);
}

test "Driver: Mirror Solid" {
    const cube_handle = driver.driver.cubeFn(10, 10, 10, false) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const mirrored_handle = driver.driver.mirrorFn(cube_handle, 1, 0, 0) orelse return error.MirrorFailed;
    const bbox = driver.driver.boundingBoxFn(mirrored_handle) orelse return error.BBoxFailed;

    try std.testing.expectApproxEqAbs(-10.0, bbox.min[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, bbox.max[0], 1e-6);

    const vol = driver.driver.volumeFn(mirrored_handle);
    try std.testing.expectApproxEqAbs(1000.0, vol, 1e-5);
}

test "Driver: Polygons Even-Odd" {
    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    const contours = [_][]const [2]f64{ &outer, &inner };

    const cs_handle = driver.driver.polygonsEvenOddFn(std.testing.allocator, &contours) orelse return error.EvenOddFailed;
    // Extrude modifies cs_handle in-place. Defer the destruction on the returned handle.
    const solid_handle = driver.driver.extrudeFn(cs_handle, 10, 0, 0, 1, 1) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(solid_handle);

    const solid_ptr: *driver.BrepSolid = @ptrCast(@alignCast(solid_handle.ptr));
    const s = solid_ptr.t_arena.solids.items[solid_ptr.solid_id];
    const shell = solid_ptr.t_arena.shells.items[solid_ptr.t_arena.solid_shells.items[s.shells_start]];
    try std.testing.expectEqual(@as(usize, 10), shell.faces_len);
}

test "Driver: Slice Solid to 2D" {
    // Create an angled/shifted cylinder
    const cyl = driver.driver.cylinderFn(5.0, 5.0, 20.0, true, 32) orelse return error.Cyl;
    defer driver.driver.destructFn(cyl);

    // Slice cleanly at Z=0
    const cs = driver.driver.sliceFn(cyl, 0.0) orelse return error.Slice;

    // Extrude it back. 'cs' is consumed and mutated into 'res', so we only destruct 'res'.
    const res = driver.driver.extrudeFn(cs, 10.0, 0, 0, 1.0, 1.0) orelse return error.Extrude;
    defer driver.driver.destructFn(res);

    const vol = driver.driver.volumeFn(res);
    // The generator currently hardcodes 16 segments.
    // 16-gon area = 8 * r^2 * sin(pi/8) = 76.536686 -> Vol = 765.366
    try std.testing.expectApproxEqAbs(765.366, vol, 1.0);
}

test "Driver: Project Solid to 2D Silhouette" {
    // Create a 10x10x10 cube, and shift it heavily so X and Y span [0, 10]
    const cube = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube);

    _ = driver.driver.translateFn(cube, 5, 5, 5);

    // Project top/bottom planes and unify them
    const cs = driver.driver.projectFn(cube) orelse return error.Project;

    // Extrude to check boundary footprint integrity. 'cs' is consumed and mutated into 'res'.
    const res = driver.driver.extrudeFn(cs, 10.0, 0, 0, 1.0, 1.0) orelse return error.Extrude;
    defer driver.driver.destructFn(res);

    const vol = driver.driver.volumeFn(res);
    try std.testing.expectApproxEqAbs(1000.0, vol, 1e-4);
}

test "Driver: Convex Hull (Single and Batch)" {
    // 1. Single Hull (Hull of a cube is just the cube itself)
    const cube1 = driver.driver.cubeFn(10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube1);

    const hull1 = driver.driver.hullFn(cube1) orelse return error.Hull;
    defer driver.driver.destructFn(hull1);

    const vol1 = driver.driver.volumeFn(hull1);
    // B-Rep Quickhull triangulation causes extremely minor floating point rounding
    try std.testing.expectApproxEqAbs(1000.0, vol1, 1e-4);

    // 2. Batch Hull
    const cube2 = driver.driver.cubeFn(10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube2);
    _ = driver.driver.translateFn(cube2, 20, 0, 0); // shift by 20 on X

    const handles = [_]geom.GeometryHandle{ cube1, cube2 };
    const batch_hull = driver.driver.batchHullFn(std.testing.allocator, &handles) orelse return error.BatchHull;
    defer driver.driver.destructFn(batch_hull);

    const bbox = driver.driver.boundingBoxFn(batch_hull) orelse return error.BBox;
    // Min X is -5 (from cube1), Max X is 25 (from cube2)
    try std.testing.expectApproxEqAbs(-5.0, bbox.min[0], 1e-4);
    try std.testing.expectApproxEqAbs(25.0, bbox.max[0], 1e-4);

    // Volume should enclose both cubes and the space between them (30x10x10)
    const vol_batch = driver.driver.volumeFn(batch_hull);
    try std.testing.expectApproxEqAbs(3000.0, vol_batch, 1e-4);
}

test "Driver: Spatial Queries (queryFaces)" {
    const cube = driver.driver.cubeFn(10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube);

    const faces = driver.driver.queryFacesFn(std.testing.allocator, cube, .{ 0, 0, 1 }, 1e-4) orelse return error.Query;
    defer std.testing.allocator.free(faces);

    try std.testing.expectEqual(@as(usize, 1), faces.len);
    try std.testing.expectApproxEqAbs(0.0, faces[0].normal[0], 1e-5);
    try std.testing.expectApproxEqAbs(0.0, faces[0].normal[1], 1e-5);
    try std.testing.expectApproxEqAbs(1.0, faces[0].normal[2], 1e-5);

    // Centroid of +Z face on centered 10x10x10 cube is (0,0,5)
    try std.testing.expectApproxEqAbs(0.0, faces[0].centroid[0], 1e-5);
    try std.testing.expectApproxEqAbs(0.0, faces[0].centroid[1], 1e-5);
    try std.testing.expectApproxEqAbs(5.0, faces[0].centroid[2], 1e-5);
}

test "Driver: Raycasting" {
    const sphere = driver.driver.sphereFn(10.0) orelse return error.Sphere;
    defer driver.driver.destructFn(sphere);

    // Shoot ray from Z=20 down to Z=-20 directly through the center
    const hits = driver.driver.rayCastFn(std.testing.allocator, sphere, .{ 0, 0, 20 }, .{ 0, 0, -20 }) orelse return error.RayCast;
    defer std.testing.allocator.free(hits);

    // Should hit top and bottom. Exact distance to top is ~10.0.
    try std.testing.expect(hits.len >= 2);
    try std.testing.expectApproxEqAbs(10.0, hits[0].distance, 0.5); // 0.5 tolerance for chordal sag
}

test "Driver: Minimum Gap" {
    const cube1 = driver.driver.cubeFn(10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube1);

    const cube2 = driver.driver.cubeFn(10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube2);

    _ = driver.driver.translateFn(cube2, 20, 0, 0); // 10 unit gap from face to face (-5..5 vs 15..25)

    const gap = driver.driver.minGapFn(cube1, cube2, 100.0);
    try std.testing.expectApproxEqAbs(10.0, gap, 1e-4);
}

test "Driver: 2D CrossSection Area and Bounding Box" {
    // Create a 10x20 centered square
    const sq = driver.driver.squareFn(10.0, 20.0, true) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(sq);

    const area = driver.driver.crossSectionAreaFn(sq);
    const bounds = driver.driver.crossSectionBoundsFn(sq);

    // Shoelace formula should evaluate area = 200.0
    try std.testing.expectApproxEqAbs(200.0, area, 1e-4);

    // Vertices traverse [-5, -10] to [5, 10]
    try std.testing.expectApproxEqAbs(-5.0, bounds.min[0], 1e-4);
    try std.testing.expectApproxEqAbs(-10.0, bounds.min[1], 1e-4);
    try std.testing.expectApproxEqAbs(5.0, bounds.max[0], 1e-4);
    try std.testing.expectApproxEqAbs(10.0, bounds.max[1], 1e-4);
}

test "Driver: 2D Polygon Even-Odd Area and Bounds" {
    // Outer 20x20 square (Area = 400) with an inner 10x10 square hole (Area = 100)
    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    const contours = [_][]const [2]f64{ &outer, &inner };

    const cs_handle = driver.driver.polygonsEvenOddFn(std.testing.allocator, &contours) orelse return error.EvenOddFailed;
    defer driver.driver.destructCrossSectionFn(cs_handle);

    const area = driver.driver.crossSectionAreaFn(cs_handle);
    const bounds = driver.driver.crossSectionBoundsFn(cs_handle);

    // Total active area = 400 - 100 = 300.0
    try std.testing.expectApproxEqAbs(300.0, area, 1e-4);

    // Outer bounding box is [-10, -10] to [10, 10]
    try std.testing.expectApproxEqAbs(-10.0, bounds.min[0], 1e-4);
    try std.testing.expectApproxEqAbs(10.0, bounds.max[0], 1e-4);
}
