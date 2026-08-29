const std = @import("std");
const driver = @import("driver.zig");
const kernel = @import("../../kernel.zig");
const geom = @import("../../geometry_handle.zig");
const step_exporter = @import("../../../exporters/3d/step.zig");

// --- Primitives & Lifecycle Tests ---

test "Driver: End-to-End API Calls" {
    // Verifies creation, transformation, and destruction of basic 3D B-Rep primitives
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const cyl_handle = driver.driver.cylinderFn(5, 5, 15, true, 32) orelse return error.CylinderFailed;
    defer driver.driver.destructFn(cyl_handle);

    const sphere_handle = driver.driver.sphereFn(5) orelse return error.SphereFailed;
    defer driver.driver.destructFn(sphere_handle);

    // Ensure translation succeeds on a valid B-Rep handle
    _ = driver.driver.translateFn(cube_handle, 10.0, 0.0, 0.0) orelse return error.TranslateFailed;

    // Verify tessellation output generation for viewport rendering
    const mesh_data = driver.driver.getMeshFn(std.testing.allocator, cube_handle) orelse return error.MeshingFailed;
    defer std.testing.allocator.free(mesh_data.vert_props);
    defer std.testing.allocator.free(mesh_data.tri_verts);

    try std.testing.expect(mesh_data.vert_props.len > 0);
}

test "Driver: Measurements (Volume, Surface Area, Bounding Box, Contains)" {
    // Tests mass properties and spatial point-in-solid inclusion on a centered 10x10x10 cube
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    // 1. Bounding Box (-5 to +5 on all axes)
    const bbox = driver.driver.boundingBoxFn(cube_handle) orelse return error.BBoxFailed;
    try std.testing.expectApproxEqAbs(-5.0, bbox.min[0], 1e-6);
    try std.testing.expectApproxEqAbs(5.0, bbox.max[0], 1e-6);

    // 2. Physical Volume (10^3 = 1000.0)
    const vol = driver.driver.volumeFn(cube_handle);
    try std.testing.expectApproxEqAbs(1000.0, vol, 1e-6);

    // 3. Surface Area (6 faces * 100 = 600.0)
    const area = driver.driver.surfaceAreaFn(cube_handle);
    try std.testing.expectApproxEqAbs(600.0, area, 1e-6);

    // 4. Point Inclusion Raycasting
    const is_inside = driver.driver.containsPointFn(cube_handle, .{ 0, 0, 0 });
    const is_outside = driver.driver.containsPointFn(cube_handle, .{ 20, 0, 0 });
    try std.testing.expect(is_inside);
    try std.testing.expect(!is_outside);
}

// --- Transformations & Slicing ---

test "Driver: Custom Matrix Transformations" {
    // Verifies 4x4 row-major affine transformation matrix application
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    // Translate +20 along the X-axis via matrix
    const translation_matrix = [12]f64{
        1, 0, 0, 20,
        0, 1, 0, 0,
        0, 0, 1, 0,
    };
    _ = driver.driver.transformMatrixFn(cube_handle, translation_matrix) orelse return error.TransformFailed;

    const bbox = driver.driver.boundingBoxFn(cube_handle) orelse return error.BBoxFailed;
    // New X bounds: [-5 + 20, 5 + 20] = [15, 25]
    try std.testing.expectApproxEqAbs(25.0, bbox.max[0], 1e-6);
}

test "Driver: Trim by Plane (Half-Space Slicing)" {
    // Slices a centered 10x10x10 cube in half at Z=0, retaining the negative half-space
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    _ = driver.driver.trimByPlaneFn(cube_handle, 0, 0, 1, 0.0) orelse return error.TrimFailed;

    const bbox = driver.driver.boundingBoxFn(cube_handle) orelse return error.BBoxFailed;
    try std.testing.expectApproxEqAbs(0.0, bbox.max[2], 1e-6);
    try std.testing.expectApproxEqAbs(-5.0, bbox.min[2], 1e-6);

    // Half of the original volume (1000 / 2 = 500)
    const vol = driver.driver.volumeFn(cube_handle);
    try std.testing.expectApproxEqAbs(500.0, vol, 1e-5);
}

test "Driver: Mirror Solid" {
    // Tests geometric reflection and topological face chirality inversion across the YZ plane
    const cube_handle = driver.driver.cubeFn(10, 10, 10, false) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    // Reflection across plane normal [1, 0, 0]
    const mirrored_handle = driver.driver.mirrorFn(cube_handle, 1, 0, 0) orelse return error.MirrorFailed;
    const bbox = driver.driver.boundingBoxFn(mirrored_handle) orelse return error.BBoxFailed;

    // Original X span: [0, 10] -> Mirrored X span: [-10, 0]
    try std.testing.expectApproxEqAbs(-10.0, bbox.min[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, bbox.max[0], 1e-6);

    const vol = driver.driver.volumeFn(mirrored_handle);
    try std.testing.expectApproxEqAbs(1000.0, vol, 1e-5);
}

// --- Mesh & Sweeps Import/Generation ---

test "Driver: Polyhedron Import (Mesh to B-Rep)" {
    // Verifies conversion of raw indexed mesh triangles into a valid Half-Edge solid
    const pts = [_][3]f64{
        .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 },
    };
    const faces = [_][3]u32{
        .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 4 },
    };
    const poly_handle = driver.driver.polyhedronFn(std.testing.allocator, &pts, &faces) orelse return error.PolyhedronFailed;
    defer driver.driver.destructFn(poly_handle);

    // Pyramid Volume = (1/3) * Base * Height = (1/3) * 100 * 10 = 333.3333...
    try std.testing.expectApproxEqAbs(333.333333, driver.driver.volumeFn(poly_handle), 1e-4);
}

test "Driver: Revolve 2D Profile" {
    // Revolves a 10x10 square profile 360 degrees around the Z-axis
    const cs_handle = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(cs_handle);

    const rev_handle = driver.driver.revolveFn(cs_handle, 36, 360.0) orelse return error.RevolveFailed;
    defer driver.driver.destructFn(rev_handle);

    const expected_area = 1800.0 * @sin(10.0 * std.math.pi / 180.0);
    const expected_vol = expected_area * 10.0;
    try std.testing.expectApproxEqAbs(expected_vol, driver.driver.volumeFn(rev_handle), 1e-4);
}

// --- 2D Cross Sections & Booleans ---

test "Driver: 2D Operations (Boolean, Transform)" {
    // Tests 2D matrix transformation, cross-section boolean union, and subsequent 3D extrusion
    const sq1 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    const sq2 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(sq2);

    // Shift sq2 by (+5, +5)
    const mat = [6]f64{ 1, 0, 5, 0, 1, 5 };
    _ = driver.driver.crossSectionTransformFn(sq2, mat) orelse return error.TransformFailed;

    // Union of two 10x10 squares overlapping by a 5x5 region (Combined Area = 100 + 100 - 25 = 175)
    const union_2d = driver.driver.crossSectionBooleanFn(sq1, sq2, .union_op) orelse return error.BooleanFailed;

    // Extrude 2D union by height = 10 (Expected Volume = 175 * 10 = 1750)
    const final_solid = driver.driver.extrudeFn(union_2d, 10, 0, 0, 1, 1) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(final_solid);

    try std.testing.expectApproxEqAbs(1750.0, driver.driver.volumeFn(final_solid), 1e-4);
}

test "Driver: 2D CrossSection Area and Bounding Box" {
    // Evaluates 2D area and bounding box calculations on a 10x20 centered square
    const sq = driver.driver.squareFn(10.0, 20.0, true) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(sq);

    const area = driver.driver.crossSectionAreaFn(sq);
    const bounds = driver.driver.crossSectionBoundsFn(sq);

    // Shoelace formula area (10 * 20 = 200.0)
    try std.testing.expectApproxEqAbs(200.0, area, 1e-4);

    // Centered bounds: X [-5, 5], Y [-10, 10]
    try std.testing.expectApproxEqAbs(-5.0, bounds.min[0], 1e-4);
    try std.testing.expectApproxEqAbs(-10.0, bounds.min[1], 1e-4);
    try std.testing.expectApproxEqAbs(5.0, bounds.max[0], 1e-4);
    try std.testing.expectApproxEqAbs(10.0, bounds.max[1], 1e-4);
}

test "Driver: Polygons Even-Odd" {
    // Tests creation of a multi-contour 2D profile (20x20 outer square with a 10x10 inner hole)
    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    const contours = [_][]const [2]f64{ &outer, &inner };

    const cs_handle = driver.driver.polygonsEvenOddFn(std.testing.allocator, &contours) orelse return error.EvenOddFailed;
    const solid_handle = driver.driver.extrudeFn(cs_handle, 10, 0, 0, 1, 1) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(solid_handle);

    const solid_ptr: *driver.BrepSolid = @ptrCast(@alignCast(solid_handle.ptr));
    const s = solid_ptr.t_arena.solids.items[solid_ptr.solid_id];
    const shell = solid_ptr.t_arena.shells.items[solid_ptr.t_arena.solid_shells.items[s.shells_start]];

    // Extruded hollow prism yields 10 faces (1 top with hole, 1 bottom with hole, 4 outer walls, 4 inner walls)
    try std.testing.expectEqual(@as(usize, 10), shell.faces_len);
}

// --- Projections & Slicing ---

test "Driver: Slice Solid to 2D" {
    // Slices a 3D cylinder at Z=0 to generate a 2D cross section, then re-extrudes it to verify topology
    const cyl = driver.driver.cylinderFn(5.0, 5.0, 20.0, true, 32) orelse return error.Cyl;
    defer driver.driver.destructFn(cyl);

    const cs = driver.driver.sliceFn(cyl, 0.0) orelse return error.Slice;

    const res = driver.driver.extrudeFn(cs, 10.0, 0, 0, 1.0, 1.0) orelse return error.Extrude;
    defer driver.driver.destructFn(res);

    const vol = driver.driver.volumeFn(res);
    // 16-segment regular polygon slice re-extruded to height=10
    try std.testing.expectApproxEqAbs(765.366, vol, 1.0);
}

test "Driver: Project Solid to 2D Silhouette" {
    // Flattens a 3D cube into a 2D silhouette footprint and re-extrudes to verify area retention
    const cube = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube);

    _ = driver.driver.translateFn(cube, 5, 5, 5);

    const cs = driver.driver.projectFn(cube) orelse return error.Project;

    const res = driver.driver.extrudeFn(cs, 10.0, 0, 0, 1.0, 1.0) orelse return error.Extrude;
    defer driver.driver.destructFn(res);

    const vol = driver.driver.volumeFn(res);
    // Silhouette area = 100 * height 10 = 1000.0
    try std.testing.expectApproxEqAbs(1000.0, vol, 1e-4);
}

// --- Convex Hulls & Queries ---

test "Driver: Convex Hull (Single and Batch)" {
    // 1. Single Hull (Hull of a cube remains a cube)
    const cube1 = driver.driver.cubeFn(10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube1);

    const hull1 = driver.driver.hullFn(cube1) orelse return error.Hull;
    defer driver.driver.destructFn(hull1);

    const vol1 = driver.driver.volumeFn(hull1);
    try std.testing.expectApproxEqAbs(1000.0, vol1, 1e-4);

    // 2. Batch Hull (Wraps two separated cubes into a unified bounding capsule)
    const cube2 = driver.driver.cubeFn(10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube2);
    _ = driver.driver.translateFn(cube2, 20, 0, 0); // Shift X by +20

    const handles = [_]geom.GeometryHandle{ cube1, cube2 };
    const batch_hull = driver.driver.batchHullFn(std.testing.allocator, &handles) orelse return error.BatchHull;
    defer driver.driver.destructFn(batch_hull);

    const bbox = driver.driver.boundingBoxFn(batch_hull) orelse return error.BBox;
    // Bounding X spans from -5 (cube1) to +25 (cube2)
    try std.testing.expectApproxEqAbs(-5.0, bbox.min[0], 1e-4);
    try std.testing.expectApproxEqAbs(25.0, bbox.max[0], 1e-4);

    // Enclosing volume = 30 * 10 * 10 = 3000.0
    const vol_batch = driver.driver.volumeFn(batch_hull);
    try std.testing.expectApproxEqAbs(3000.0, vol_batch, 1e-4);
}

test "Driver: Spatial Queries (queryFaces)" {
    // Tests directional face selection and centroid extraction
    const cube = driver.driver.cubeFn(10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube);

    const faces = driver.driver.queryFacesFn(std.testing.allocator, cube, .{ 0, 0, 1 }, 1e-4) orelse return error.Query;
    defer std.testing.allocator.free(faces);

    try std.testing.expectEqual(@as(usize, 1), faces.len);
    try std.testing.expectApproxEqAbs(0.0, faces[0].normal[0], 1e-5);
    try std.testing.expectApproxEqAbs(0.0, faces[0].normal[1], 1e-5);
    try std.testing.expectApproxEqAbs(1.0, faces[0].normal[2], 1e-5);

    // Centroid of top face on centered 10x10x10 cube is (0, 0, 5)
    try std.testing.expectApproxEqAbs(0.0, faces[0].centroid[0], 1e-5);
    try std.testing.expectApproxEqAbs(0.0, faces[0].centroid[1], 1e-5);
    try std.testing.expectApproxEqAbs(5.0, faces[0].centroid[2], 1e-5);
}

test "Driver: Raycasting" {
    // Tests ray-surface intersection against a B-Rep sphere
    const sphere = driver.driver.sphereFn(10.0) orelse return error.Sphere;
    defer driver.driver.destructFn(sphere);

    // Shoot ray from Z=20 down to Z=-20 directly through origin
    const hits = driver.driver.rayCastFn(std.testing.allocator, sphere, .{ 0, 0, 20 }, .{ 0, 0, -20 }) orelse return error.RayCast;
    defer std.testing.allocator.free(hits);

    // Expect hits on top (Z=10) and bottom (Z=-10) surfaces
    try std.testing.expect(hits.len >= 2);
    try std.testing.expectApproxEqAbs(10.0, hits[0].distance, 0.5); // Tolerance accommodates tessellation sag
}

test "Driver: Minimum Gap" {
    // Tests shortest vertex distance calculation across two distinct handles
    const cube1 = driver.driver.cubeFn(10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube1);

    const cube2 = driver.driver.cubeFn(10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube2);

    _ = driver.driver.translateFn(cube2, 20, 0, 0); // 10 unit gap between face X=5 and X=15

    const gap = driver.driver.minGapFn(cube1, cube2, 100.0);
    try std.testing.expectApproxEqAbs(10.0, gap, 1e-4);
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

test "Driver: splitByPlane deeply clones arenas avoiding double-free corruption" {
    const cube = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    const pair = driver.driver.splitByPlaneFn(cube, 0.0, 0.0, 1.0, 0.0);
    try std.testing.expect(pair.first != null);
    try std.testing.expect(pair.second != null);

    // Destroy second half immediately to trigger potential double-free
    driver.driver.destructFn(pair.second.?);

    const cutter = driver.driver.cubeFn(5.0, 5.0, 20.0, true) orelse return error.CutterFailed;
    defer driver.driver.destructFn(cutter);

    // Test that the remaining half can safely undergo further CSG boolean operations
    const result = driver.driver.booleanFn(pair.first.?, cutter, .difference_op) orelse return error.BoolFailed;
    defer driver.driver.destructFn(result);

    const vol = driver.driver.volumeFn(result);
    try std.testing.expect(vol > 0.0); // Assert graph is alive and computable
}

test "Isolation: Extrude Offset Polygon (hex_mount)" {
    const alloc = std.testing.allocator;
    var pts = [_][2]f64{ .{ -10, -17.32 }, .{ 10, -17.32 }, .{ 20, 0 }, .{ 10, 17.32 }, .{ -10, 17.32 }, .{ -20, 0 } };

    // offsetFn and extrudeFn mutate the handle IN-PLACE.
    // We only defer destruction on the final solid handle to prevent double-free segfaults.
    const poly = driver.driver.polygonFn(alloc, &pts) orelse return error.Fail;
    const offset_poly = driver.driver.offsetFn(poly, 1.5, 0) orelse return error.Fail;
    const solid = driver.driver.extrudeFn(offset_poly, 6.0, 0, 0, 1, 1) orelse return error.Fail;
    defer driver.driver.destructFn(solid);

    try std.testing.expect(driver.driver.volumeFn(solid) > 0);
}

test "Isolation: Minkowski Sum + Split By Plane (flat_bumper)" {
    const cube = driver.driver.cubeFn(4.0, 12.0, 6.0, true) orelse return error.Fail;
    const sph = driver.driver.sphereFn(2.0) orelse return error.Fail;

    // minkowskiFn merges sph into cube. It mutates cube in-place.
    const bumper_soft = driver.driver.minkowskiFn(cube, sph) orelse return error.Fail;
    defer driver.driver.destructFn(sph); // sph was merged, but its wrapper still exists

    // splitByPlaneFn mutates bumper_soft (which is cube) into the first half.
    // It allocates a completely new wrapper for the second half.
    const split_parts = driver.driver.splitByPlaneFn(bumper_soft, 1.0, 0.0, 0.0, 1.0);
    try std.testing.expect(split_parts.first != null);
    try std.testing.expect(split_parts.second != null);

    defer driver.driver.destructFn(split_parts.first.?); // Frees the `cube` wrapper
    defer driver.driver.destructFn(split_parts.second.?); // Frees the newly cloned wrapper

    try std.testing.expect(driver.driver.volumeFn(split_parts.first.?) > 0);
}

test "Isolation: Batch Hull Spheres (arm_body)" {
    const alloc = std.testing.allocator;

    const s1 = driver.driver.sphereFn(6.0) orelse return error.Fail;
    defer driver.driver.destructFn(s1);

    const s2 = driver.driver.sphereFn(4.0) orelse return error.Fail;
    defer driver.driver.destructFn(s2);
    _ = driver.driver.translateFn(s2, 50.0, 0.0, 0.0); // IN PLACE

    const s3 = driver.driver.sphereFn(4.0) orelse return error.Fail;
    defer driver.driver.destructFn(s3);
    _ = driver.driver.translateFn(s3, 50.0, 10.0, 0.0); // IN PLACE

    const handles = [_]geom.GeometryHandle{ s1, s2, s3 };
    const arm_body = driver.driver.batchHullFn(alloc, &handles) orelse return error.Fail;
    defer driver.driver.destructFn(arm_body); // Batch hull creates a NEW solid wrapper

    try std.testing.expect(driver.driver.volumeFn(arm_body) > 0);
}

test "Isolation: Boolean Difference with Multiple Cylinders (mounting_holes)" {
    const base = driver.driver.cubeFn(40.0, 40.0, 10.0, true) orelse return error.Fail;
    defer driver.driver.destructFn(base);

    const c1 = driver.driver.cylinderFn(1.6, 1.6, 20.0, true, 16) orelse return error.Fail;
    defer driver.driver.destructFn(c1);
    _ = driver.driver.translateFn(c1, 15.0, 0.0, 0.0); // IN PLACE

    const c2 = driver.driver.cylinderFn(1.6, 1.6, 20.0, true, 16) orelse return error.Fail;
    defer driver.driver.destructFn(c2);
    _ = driver.driver.translateFn(c2, -15.0, 0.0, 0.0); // IN PLACE

    // union_op merges c2 into c1, mutates c1 in-place.
    const holes = driver.driver.booleanFn(c1, c2, .union_op) orelse return error.Fail;

    // difference_op merges holes (which is c1) into base, mutates base in-place.
    const result = driver.driver.booleanFn(base, holes, .difference_op) orelse return error.Fail;

    try std.testing.expect(driver.driver.volumeFn(result) > 0);
}

test "Driver: STEP Export of CSG Boolean Result" {
    const alloc = std.testing.allocator;

    // 1. Create a cube with a hole in it
    const base = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(base);

    const hole = driver.driver.cylinderFn(2.5, 2.5, 20.0, true, 16) orelse return error.CylFailed;
    defer driver.driver.destructFn(hole);

    const result = driver.driver.booleanFn(base, hole, .difference_op) orelse return error.BoolFailed;

    // 2. Export to STEP
    const handles = [_]geom.GeometryHandle{result};
    const step_bytes = try step_exporter.buildStepBuffer(alloc, &handles);
    defer alloc.free(step_bytes);

    // 3. Verify ISO 10303-21 formatting and topology records
    try std.testing.expect(std.mem.indexOf(u8, step_bytes, "ISO-10303-21;") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_bytes, "MANIFOLD_SOLID_BREP") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_bytes, "CLOSED_SHELL") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_bytes, "ADVANCED_FACE") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_bytes, "EDGE_LOOP") != null);
}

test "Driver: Multiple Sequential Plane Trims" {
    // Tests that the dynamic bounding boxes and deep-cloning hold up
    // over multiple successive slicing operations without crashing or degrading the arena.
    const cube = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube);

    // Trim +Z
    _ = driver.driver.trimByPlaneFn(cube, 0.0, 0.0, 1.0, 2.0) orelse return error.TrimFailed;
    // Trim +X
    _ = driver.driver.trimByPlaneFn(cube, 1.0, 0.0, 0.0, 2.0) orelse return error.TrimFailed;
    // Trim +Y
    _ = driver.driver.trimByPlaneFn(cube, 0.0, 1.0, 0.0, 2.0) orelse return error.TrimFailed;

    const bbox = driver.driver.boundingBoxFn(cube) orelse return error.BBoxFailed;

    // Ensure bounds exist and graph traversals complete safely
    try std.testing.expect(bbox.max[0] != std.math.inf(f64));
    try std.testing.expect(bbox.max[1] != std.math.inf(f64));
    try std.testing.expect(bbox.max[2] != std.math.inf(f64));

    const vol = driver.driver.volumeFn(cube);
    // Ensure the geometry graph survived the 3 sequential booleans and can compute a volume
    try std.testing.expect(vol > 0.0);
}
