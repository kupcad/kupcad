const std = @import("std");
const testing = std.testing;
const driver = @import("driver.zig");

test "Math3D: vecDot calculates correct scalar product" {
    const a = [_]f64{ 1.0, 2.0, 3.0 };
    const b = [_]f64{ 4.0, 5.0, 6.0 };

    // 1*4 + 2*5 + 3*6 = 32
    try testing.expectEqual(@as(f64, 32.0), driver.vecDot(a, b));

    const orthogonal_a = [_]f64{ 1.0, 0.0, 0.0 };
    const orthogonal_b = [_]f64{ 0.0, 1.0, 0.0 };
    try testing.expectEqual(@as(f64, 0.0), driver.vecDot(orthogonal_a, orthogonal_b));
}

test "Math3D: vecNormalize scales vector to unit length safely" {
    const v1 = [_]f64{ 0.0, 5.0, 0.0 };
    const norm1 = driver.vecNormalize(v1);
    try testing.expectEqual(@as(f64, 0.0), norm1[0]);
    try testing.expectEqual(@as(f64, 1.0), norm1[1]);
    try testing.expectEqual(@as(f64, 0.0), norm1[2]);

    // Zero vector fallback
    const v2 = [_]f64{ 0.0, 0.0, 0.0 };
    const norm2 = driver.vecNormalize(v2);
    try testing.expectEqual(@as(f64, 0.0), norm2[0]);
    try testing.expectEqual(@as(f64, 0.0), norm2[1]);
    try testing.expectEqual(@as(f64, 0.0), norm2[2]);
}

test "Math3D: computeNormal evaluates correct right-hand normal" {
    // A triangle lying flat on the XY plane, drawn counter-clockwise
    const v0 = [_]f64{ 0.0, 0.0, 0.0 };
    const v1 = [_]f64{ 1.0, 0.0, 0.0 };
    const v2 = [_]f64{ 0.0, 1.0, 0.0 };

    const normal = driver.computeNormal(v0, v1, v2);

    // Should point exactly +Z
    try testing.expectEqual(@as(f64, 0.0), normal[0]);
    try testing.expectEqual(@as(f64, 0.0), normal[1]);
    try testing.expectEqual(@as(f64, 1.0), normal[2]);
}

test "Math3D: computeCentroid averages vertices exactly" {
    const v0 = [_]f64{ -3.0, 0.0, 0.0 };
    const v1 = [_]f64{ 3.0, 0.0, 0.0 };
    const v2 = [_]f64{ 0.0, 6.0, 9.0 };

    const centroid = driver.computeCentroid(v0, v1, v2);

    try testing.expectEqual(@as(f64, 0.0), centroid[0]);
    try testing.expectEqual(@as(f64, 2.0), centroid[1]);
    try testing.expectEqual(@as(f64, 3.0), centroid[2]);
}

test "Manifold Driver: cube generates exact volume and surface area" {
    // 10x10x10 cube
    const handle = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(handle);

    const vol = driver.driver.volumeFn(handle);
    const sa = driver.driver.surfaceAreaFn(handle);

    // Volume = 10^3 = 1000
    try testing.expectApproxEqAbs(@as(f64, 1000.0), vol, 1e-5);
    // Surface Area = 6 faces * (10*10) = 600
    try testing.expectApproxEqAbs(@as(f64, 600.0), sa, 1e-5);
}

test "Manifold Driver: cylinder generates valid geometry" {
    // Generate a cylinder with r=5, h=10. Volume = pi * r^2 * h = ~785.4
    const handle = driver.driver.cylinderFn(5.0, 5.0, 10.0, true, 0) orelse return error.CylFailed;
    defer driver.driver.destructFn(handle);

    const vol = driver.driver.volumeFn(handle);
    try testing.expect(vol > 780.0 and vol < 790.0);
}

test "Manifold Driver: sphere generates valid geometry" {
    const handle = driver.driver.sphereFn(5.0) orelse return error.SphereFailed;
    defer driver.driver.destructFn(handle);

    const vol = driver.driver.volumeFn(handle);
    // Tessellated sphere volume is slightly less than ideal 523.6mm³
    try testing.expect(vol > 450.0 and vol < 525.0);
}

test "Manifold Driver: extrude creates 3D solid from 2D profile" {
    // 1. Create a 10x10 2D square
    const sq = driver.driver.squareFn(10.0, 10.0, true) orelse return error.SqFailed;
    defer driver.driver.destructCrossSectionFn(sq);

    // 2. Extrude by 10 units (creates a 10x10x10 cube equivalent)
    const ext = driver.driver.extrudeFn(sq, 10.0, 0, 0.0, 1.0, 1.0) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(ext);

    // 3. Verify volume matches a 10x10x10 cube
    const vol = driver.driver.volumeFn(ext);
    try testing.expectApproxEqAbs(@as(f64, 1000.0), vol, 1e-5);
}

test "Manifold Driver: mirror reflects geometry correctly across plane" {
    const c = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(c);

    // Shift to X = +10. (Bounds are now X: [5, 15])
    const translated = driver.driver.translateFn(c, 10.0, 0.0, 0.0) orelse return error.TransFailed;
    defer driver.driver.destructFn(translated);

    // Mirror across the X=0 plane (Normal: [1, 0, 0])
    const mirrored = driver.driver.mirrorFn(translated, 1.0, 0.0, 0.0) orelse return error.MirrorFailed;
    defer driver.driver.destructFn(mirrored);

    const bbox = driver.driver.boundingBoxFn(mirrored) orelse return error.BBoxFailed;

    // Mirrored bounds should strictly lie on the negative X axis
    try testing.expectApproxEqAbs(@as(f64, -15.0), bbox.min[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, -5.0), bbox.max[0], 1e-5);
}

test "Manifold Driver: rayCast finds intersections and distance correctly" {
    const c = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(c);

    // Cast a ray starting at Z=10 straight down to Z=-10 through the center [0,0]
    const hits = driver.driver.rayCastFn(testing.allocator, c, .{ 0.0, 0.0, 10.0 }, .{ 0.0, 0.0, -10.0 }) orelse return error.RayFailed;
    defer testing.allocator.free(hits);

    try testing.expect(hits.len > 0);

    // The cube's top face is at Z=5.
    // Distance from [0,0,10] to [0,0,5] is 5.0 units.
    try testing.expectApproxEqAbs(@as(f64, 5.0), hits[0].distance, 1e-5);

    // Hit normal should point strictly +Z
    try testing.expectApproxEqAbs(@as(f64, 0.0), hits[0].normal[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 0.0), hits[0].normal[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 1.0), hits[0].normal[2], 1e-5);
}

test "Manifold Driver: minGap accurately calculates shortest distance between solids" {
    const c1 = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(c1);

    const c2_base = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(c2_base);

    // Translate c2 so its minimum X is at 15.0 (c1 max X is at 5.0)
    const c2 = driver.driver.translateFn(c2_base, 20.0, 0.0, 0.0) orelse return error.TransFailed;
    defer driver.driver.destructFn(c2);

    const gap = driver.driver.minGapFn(c1, c2, 100.0);

    // The exact gap should be 15.0 - 5.0 = 10.0
    try testing.expectApproxEqAbs(@as(f64, 10.0), gap, 1e-5);
}

test "Manifold Driver: getMesh securely extracts flat vertex arrays" {
    const c = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(c);

    const mesh = driver.driver.getMeshFn(testing.allocator, c) orelse return error.MeshFailed;
    defer {
        testing.allocator.free(mesh.vert_props);
        testing.allocator.free(mesh.tri_verts);
    }

    // A standard triangulated cube must have exactly 12 triangles (36 indices)
    try testing.expectEqual(@as(usize, 36), mesh.tri_verts.len);

    // Must contain at least x, y, z properties
    try testing.expect(mesh.num_prop >= 3);
}

test "Manifold Driver: translate updates bounding box correctly" {
    const handle = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(handle);

    const translated = driver.driver.translateFn(handle, 5.0, 10.0, 15.0) orelse return error.TranslateFailed;
    defer driver.driver.destructFn(translated);

    const bbox = driver.driver.boundingBoxFn(translated) orelse return error.BBoxFailed;

    // Original centered 10x10x10 bounds: min [-5, -5, -5], max [5, 5, 5]
    // Translated by [5, 10, 15]
    // Expected min: [0, 5, 10], Expected max: [10, 15, 20]
    try testing.expectApproxEqAbs(@as(f64, 0.0), bbox.min[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 5.0), bbox.min[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 10.0), bbox.min[2], 1e-5);

    try testing.expectApproxEqAbs(@as(f64, 10.0), bbox.max[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 15.0), bbox.max[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 20.0), bbox.max[2], 1e-5);
}

test "Manifold Driver: boolean difference calculates correct subtracted volume" {
    const c1 = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(c1);

    const c2 = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(c2);

    // Shift c2 exactly halfway out of c1 on the X axis
    const translated_c2 = driver.driver.translateFn(c2, 5.0, 0.0, 0.0) orelse return error.TranslateFailed;
    defer driver.driver.destructFn(translated_c2);

    // Subtract translated_c2 from c1
    const diff = driver.driver.booleanFn(c1, translated_c2, .difference_op) orelse return error.BoolFailed;
    defer driver.driver.destructFn(diff);

    // Initial volume is 1000.
    // They intersect by exactly half (5 * 10 * 10 = 500).
    // Remaining volume should be exactly 500.
    const vol = driver.driver.volumeFn(diff);
    try testing.expectApproxEqAbs(@as(f64, 500.0), vol, 1e-5);
}

test "Manifold Driver: containsPoint evaluates spatial inclusion correctly" {
    const handle = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(handle);

    // Origin is dead-center of the cube
    try testing.expect(driver.driver.containsPointFn(handle, .{ 0.0, 0.0, 0.0 }));

    // Edge/Inside
    try testing.expect(driver.driver.containsPointFn(handle, .{ 4.9, 4.9, 4.9 }));

    // Outside the 10x10x10 boundary
    try testing.expect(!driver.driver.containsPointFn(handle, .{ 10.0, 10.0, 10.0 }));
    try testing.expect(!driver.driver.containsPointFn(handle, .{ -6.0, 0.0, 0.0 }));
}

test "Manifold Driver: scale modifies geometry and volume non-uniformly" {
    const handle = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(handle);

    // Scale X by 2, Y by 3, Z by 0.5
    const scaled = driver.driver.scaleFn(handle, 2.0, 3.0, 0.5) orelse return error.ScaleFailed;
    defer driver.driver.destructFn(scaled);

    const bbox = driver.driver.boundingBoxFn(scaled) orelse return error.BBoxFailed;

    // Expected dimensions: X=20, Y=30, Z=5
    try testing.expectApproxEqAbs(@as(f64, 20.0), bbox.max[0] - bbox.min[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 30.0), bbox.max[1] - bbox.min[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 5.0), bbox.max[2] - bbox.min[2], 1e-5);

    // Volume should scale by the product of the axes (2 * 3 * 0.5 = 3) -> 1000 * 3 = 3000
    const vol = driver.driver.volumeFn(scaled);
    try testing.expectApproxEqAbs(@as(f64, 3000.0), vol, 1e-5);
}

test "Manifold Driver: queryFaces extracts exact centroid and normal for Top face" {
    // Create a 10x10x10 cube, centered at the origin
    const handle = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(handle);

    // Query the "Top" face (Direction: [0, 0, 1]) with a standard tolerance
    const faces = driver.driver.queryFacesFn(testing.allocator, handle, .{ 0.0, 0.0, 1.0 }, 1e-5) orelse return error.QueryFailed;
    defer testing.allocator.free(faces);

    try testing.expectEqual(@as(usize, 1), faces.len);

    // Verify Normal remains exactly +Z
    try testing.expectEqual(@as(f64, 0.0), faces[0].normal[0]);
    try testing.expectEqual(@as(f64, 0.0), faces[0].normal[1]);
    try testing.expectEqual(@as(f64, 1.0), faces[0].normal[2]);

    // Verify Centroid is perfectly centered at the Z bounding box extremum (Z = 5.0)
    try testing.expectApproxEqAbs(@as(f64, 0.0), faces[0].centroid[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 0.0), faces[0].centroid[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 5.0), faces[0].centroid[2], 1e-5);
}

test "Manifold Driver: queryFaces extracts exact centroid for uncentered Right face" {
    // Create an off-center 20x10x10 cube (origin at 0,0,0 stretching into +X,+Y,+Z)
    const handle = driver.driver.cubeFn(20.0, 10.0, 10.0, false) orelse return error.CubeFailed;
    defer driver.driver.destructFn(handle);

    // Query the "Right" face (Direction: [1, 0, 0])
    const faces = driver.driver.queryFacesFn(testing.allocator, handle, .{ 1.0, 0.0, 0.0 }, 1e-5) orelse return error.QueryFailed;
    defer testing.allocator.free(faces);

    try testing.expectEqual(@as(usize, 1), faces.len);

    // 3. Verify Normal is exactly +X
    try testing.expectEqual(@as(f64, 1.0), faces[0].normal[0]);
    try testing.expectEqual(@as(f64, 0.0), faces[0].normal[1]);
    try testing.expectEqual(@as(f64, 0.0), faces[0].normal[2]);

    // 4. Verify Centroid matches the exact uncentered bounding box logic.
    // The right face should be exactly at X = 20.0, with Y and Z midpoints at 5.0!
    try testing.expectApproxEqAbs(@as(f64, 20.0), faces[0].centroid[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 5.0), faces[0].centroid[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 5.0), faces[0].centroid[2], 1e-5);
}

test "Manifold Driver: rotate rotates geometry around origin" {
    const handle = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(handle);

    const translated = driver.driver.translateFn(handle, 10.0, 0.0, 0.0) orelse return error.TransFailed;
    defer driver.driver.destructFn(translated);

    // Rotate 90 degrees around Z axis. Point [10, 0, 0] should become [0, 10, 0]
    const rotated = driver.driver.rotateFn(translated, 0.0, 0.0, 90.0) orelse return error.RotFailed;
    defer driver.driver.destructFn(rotated);

    const bbox = driver.driver.boundingBoxFn(rotated) orelse return error.BBoxFailed;

    // Y should now hold the offset (10.0), and X should be centered
    try testing.expectApproxEqAbs(@as(f64, 5.0), bbox.min[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 15.0), bbox.max[1], 1e-5);
}

test "Manifold Driver: trimByPlane cuts solid exactly in half" {
    // 10x10x10 cube from [-5, -5, -5] to [5, 5, 5]
    const handle = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(handle);

    // Normal [0, 0, 1] at offset 0 retains Z >= 0
    const trimmed = driver.driver.trimByPlaneFn(handle, 0.0, 0.0, 1.0, 0.0) orelse return error.TrimFailed;
    defer driver.driver.destructFn(trimmed);

    // Volume is exactly half (500)
    const vol = driver.driver.volumeFn(trimmed);
    try testing.expectApproxEqAbs(@as(f64, 500.0), vol, 1e-5);

    // Min Z becomes 0.0, while Max Z stays at 5.0
    const bbox = driver.driver.boundingBoxFn(trimmed) orelse return error.BBoxFailed;
    try testing.expectApproxEqAbs(@as(f64, 0.0), bbox.min[2], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 5.0), bbox.max[2], 1e-5);
}

test "Manifold Driver: hull wraps disjoint geometry securely" {
    const s1 = driver.driver.sphereFn(5.0) orelse return error.SphereFailed;
    defer driver.driver.destructFn(s1);

    const s2_base = driver.driver.sphereFn(5.0) orelse return error.SphereFailed;
    defer driver.driver.destructFn(s2_base);

    const s2 = driver.driver.translateFn(s2_base, 20.0, 0.0, 0.0) orelse return error.TransFailed;
    defer driver.driver.destructFn(s2);

    const unioned = driver.driver.booleanFn(s1, s2, .union_op) orelse return error.BoolFailed;
    defer driver.driver.destructFn(unioned);

    // Hull the two disconnected spheres (creates a capsule-like pill shape)
    const hulled = driver.driver.hullFn(unioned) orelse return error.HullFailed;
    defer driver.driver.destructFn(hulled);

    const bbox = driver.driver.boundingBoxFn(hulled) orelse return error.BBoxFailed;

    // X bounds should span from -5 to 25
    try testing.expectApproxEqAbs(@as(f64, -5.0), bbox.min[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 25.0), bbox.max[0], 1e-5);

    // Volume should be significantly greater than just the two spheres
    const union_vol = driver.driver.volumeFn(unioned);
    const hull_vol = driver.driver.volumeFn(hulled);
    try testing.expect(hull_vol > union_vol);
}

test "Manifold Driver: revolve sweeps 2D profile into 3D shape" {
    const sq = driver.driver.squareFn(10.0, 10.0, true) orelse return error.SqFailed;
    defer driver.driver.destructCrossSectionFn(sq);

    // Translate the square 20 units away from origin
    const mat = [6]f64{ 1.0, 0.0, 0.0, 1.0, 20.0, 0.0 };
    const translated_sq = driver.driver.crossSectionTransformFn(sq, mat) orelse return error.CSTransFailed;
    defer driver.driver.destructCrossSectionFn(translated_sq);

    // Revolve it 360 degrees (creating a square-profile ring/torus)
    const revolved = driver.driver.revolveFn(translated_sq, 0, 360.0) orelse return error.RevFailed;
    defer driver.driver.destructFn(revolved);

    const vol = driver.driver.volumeFn(revolved);
    try testing.expect(vol > 0.0);

    // Bounding box should span symmetrically from roughly -25 to +25 on X and Y
    const bbox = driver.driver.boundingBoxFn(revolved) orelse return error.BBoxFailed;
    try testing.expect(bbox.min[0] < -20.0);
    try testing.expect(bbox.max[0] > 20.0);
}

test "Manifold Driver: slice extracts 2D cross section from 3D geometry" {
    const handle = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(handle);

    // Slice the cube directly through the middle (Z=0)
    const cs = driver.driver.sliceFn(handle, 0.0) orelse return error.SliceFailed;
    defer driver.driver.destructCrossSectionFn(cs);

    // Offset the 2D cross section inward by 1 unit
    const offset_cs = driver.driver.offsetFn(cs, -1.0, 1) orelse return error.OffsetFailed;
    defer driver.driver.destructCrossSectionFn(offset_cs);

    // Extrude the offset slice back into 3D to check it
    const ext = driver.driver.extrudeFn(offset_cs, 5.0, 0, 0.0, 1.0, 1.0) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(ext);

    // Original cube slice was 10x10. Offset by -1 makes it 8x8.
    // 8 * 8 * 5 = 320 volume.
    const vol = driver.driver.volumeFn(ext);
    try testing.expectApproxEqAbs(@as(f64, 320.0), vol, 1e-5);
}

test "Manifold Driver: splitByPlane returns valid SolidPair" {
    const handle = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(handle);

    // Split using a plane at Z=0
    const pair = driver.driver.splitByPlaneFn(handle, 0.0, 0.0, 1.0, 0.0);

    // Make sure we safely free both halves
    try testing.expect(pair.first != null);
    try testing.expect(pair.second != null);
    defer {
        driver.driver.destructFn(pair.first.?);
        driver.driver.destructFn(pair.second.?);
    }

    // Each half should be exactly 500 volume
    const vol1 = driver.driver.volumeFn(pair.first.?);
    const vol2 = driver.driver.volumeFn(pair.second.?);

    try testing.expectApproxEqAbs(@as(f64, 500.0), vol1, 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 500.0), vol2, 1e-5);
}

test "Manifold Driver: simplify reduces coplanar triangle count on sliced meshes" {
    // Create a 10x10 2D square
    const sq = driver.driver.squareFn(10.0, 10.0, true) orelse return error.SqFailed;
    defer driver.driver.destructCrossSectionFn(sq);

    // Extrude by 10 units with 10 height slices (generates multi-segmented coplanar side walls)
    const ext = driver.driver.extrudeFn(sq, 10.0, 10, 0.0, 1.0, 1.0) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(ext);

    const unsimplified_mesh = driver.driver.getMeshFn(testing.allocator, ext) orelse return error.MeshFailed;
    defer {
        testing.allocator.free(unsimplified_mesh.vert_props);
        testing.allocator.free(unsimplified_mesh.tri_verts);
    }

    // Apply coplanar simplification directly through the driver interface
    const simplified = driver.driver.simplifyFn(ext, 1e-5) orelse return error.SimplifyFailed;
    defer if (simplified.ptr != ext.ptr) driver.driver.destructFn(simplified);

    const simplified_mesh = driver.driver.getMeshFn(testing.allocator, simplified) orelse return error.MeshFailed;
    defer {
        testing.allocator.free(simplified_mesh.vert_props);
        testing.allocator.free(simplified_mesh.tri_verts);
    }

    // The multi-slice mesh should contain more triangle indices than the simplified box mesh
    try testing.expect(unsimplified_mesh.tri_verts.len > simplified_mesh.tri_verts.len);
}
