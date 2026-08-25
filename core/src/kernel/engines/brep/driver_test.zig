const std = @import("std");
const testing = std.testing;
const driver = @import("driver.zig");
const step = @import("../../../exporters/3d/step.zig");
const geom = @import("../../geometry_handle.zig");

test "B-Rep Native: Generate Cube and Export STEP" {
    // 1. Generate the native DOD Cube
    const handle_opt = driver.driver.cubeFn(10.0, 10.0, 10.0, true);
    try testing.expect(handle_opt != null);
    const handle = handle_opt.?;
    defer driver.driver.destructFn(handle);

    // 2. Generate STEP Buffer
    const step_bytes = try step.buildStepBuffer(testing.allocator, handle);
    defer testing.allocator.free(step_bytes);

    // 3. Validate STEP payload contains standard syntax
    try testing.expect(std.mem.indexOf(u8, step_bytes, "ISO-10303-21;") != null);
    try testing.expect(std.mem.indexOf(u8, step_bytes, "CARTESIAN_POINT") != null);
    try testing.expect(std.mem.indexOf(u8, step_bytes, "MANIFOLD_SOLID_BREP") != null);
}

test "B-Rep Native: Tessellate Cube for STL/GLTF pipeline" {
    const handle_opt = driver.driver.cubeFn(10.0, 10.0, 10.0, true);
    try testing.expect(handle_opt != null);
    const handle = handle_opt.?;
    defer driver.driver.destructFn(handle);

    // 1. Extract Triangulated Mesh
    const mesh_opt = driver.driver.getMeshFn(testing.allocator, handle);
    try testing.expect(mesh_opt != null);
    const mesh = mesh_opt.?;
    defer {
        testing.allocator.free(mesh.vert_props);
        testing.allocator.free(mesh.tri_verts);
    }

    // 2. Validate Mesh Geometry
    // A cube has 8 vertices * 3 floats = 24 floats
    try testing.expectEqual(@as(usize, 24), mesh.vert_props.len);

    // 6 square faces * 2 triangles per face * 3 indices = 36 indices
    try testing.expectEqual(@as(usize, 36), mesh.tri_verts.len);
}
