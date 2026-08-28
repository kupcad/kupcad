const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");
const transforms = @import("transforms.zig");
const booleans = @import("booleans.zig");
const slicing = @import("slicing.zig");

test "Fuzz: Geometry Generation, Transforms, and Raycasting" {
    const alloc = std.testing.allocator;

    // Initialize a deterministic Pseudo-Random Number Generator (PRNG)
    // Using std.Random.DefaultPrng ensures compatibility with modern Zig
    var prng = std.Random.DefaultPrng.init(0xCADCAD);
    const random = prng.random();

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    for (0..100) |_| {
        // 1. Generate random dimensions [0.1, 100.0]
        const dx = random.float(f64) * 100.0 + 0.1;
        const dy = random.float(f64) * 100.0 + 0.1;
        const dz = random.float(f64) * 100.0 + 0.1;

        // 2. Generate a base shape randomly (Cube or Cylinder)
        const is_cube = random.boolean();
        const solid_id = if (is_cube)
            try generators.generateCube(alloc, &t_arena, &g_arena, dx, dy, dz, true)
        else
            try generators.generateCylinder(alloc, &t_arena, &g_arena, dx / 2.0, dz, true);

        // 3. Apply a wild random translation [-500.0, 500.0]
        const tx = random.float(f64) * 1000.0 - 500.0;
        const ty = random.float(f64) * 1000.0 - 500.0;
        const tz = random.float(f64) * 1000.0 - 500.0;
        _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, solid_id, tx, ty, tz);

        // 4. Apply a wild random rotation [0.0, 360.0]
        const rx = random.float(f64) * 360.0;
        const ry = random.float(f64) * 360.0;
        const rz = random.float(f64) * 360.0;
        _ = try transforms.rotateSolid(alloc, &t_arena, &g_arena, solid_id, rx, ry, rz);

        // 5. Apply a random non-uniform scale [0.1, 5.0]
        const sx = random.float(f64) * 4.9 + 0.1;
        const sy = random.float(f64) * 4.9 + 0.1;
        const sz = random.float(f64) * 4.9 + 0.1;
        _ = try transforms.scaleSolid(alloc, &t_arena, &g_arena, solid_id, sx, sy, sz);

        // 6. Bombard the resulting deformed geometry with 50 random raycasts
        for (0..50) |_| {
            // Generate points anywhere in a massive bounding box
            const px = random.float(f64) * 2000.0 - 1000.0;
            const py = random.float(f64) * 2000.0 - 1000.0;
            const pz = random.float(f64) * 2000.0 - 1000.0;

            // The assertion here isn't the boolean result, but rather the invariant:
            // "No matter how distorted the shape or extreme the point, Raycasting MUST NOT panic or trap."
            _ = booleans.isPointInsideSolid(&t_arena, &g_arena, solid_id, .{ px, py, pz });
        }

        // 7. Clear arenas for the next fuzz loop so we don't run out of memory
        t_arena.clearRetainingCapacity();
        g_arena.clearRetainingCapacity(alloc);
    }
}

test "Fuzz: Plane Slicing and Boolean Stability" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xCAFECAFE);
    const random = prng.random();

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    for (0..50) |_| {
        // 1. Generate a random base shape
        const solid_id = if (random.boolean())
            try generators.generateCube(alloc, &t_arena, &g_arena, random.float(f64) * 50.0 + 10.0, random.float(f64) * 50.0 + 10.0, random.float(f64) * 50.0 + 10.0, true)
        else
            try generators.generateCylinder(alloc, &t_arena, &g_arena, random.float(f64) * 25.0 + 5.0, random.float(f64) * 50.0 + 10.0, true);

        // 2. Randomly orient and offset it
        _ = try transforms.rotateSolid(alloc, &t_arena, &g_arena, solid_id, random.float(f64) * 360.0, random.float(f64) * 360.0, random.float(f64) * 360.0);
        _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, solid_id, random.float(f64) * 100.0 - 50.0, random.float(f64) * 100.0 - 50.0, random.float(f64) * 100.0 - 50.0);

        // 3. Generate a random slicing plane normal vector
        var nx = random.float(f64) * 2.0 - 1.0;
        var ny = random.float(f64) * 2.0 - 1.0;
        var nz = random.float(f64) * 2.0 - 1.0;
        const mag = @sqrt(nx * nx + ny * ny + nz * nz);
        if (mag < 0.001) {
            nx = 0;
            ny = 0;
            nz = 1;
        } else {
            nx /= mag;
            ny /= mag;
            nz /= mag;
        }

        // 4. Generate a random slicing offset cutting near the origin
        const offset = random.float(f64) * 50.0 - 25.0;

        // 5. Perform the slice.
        // We use `catch continue` because incredibly thin micro-slices (e.g., cutting exactly 1e-7 units off a corner)
        // might trigger topological rejections. We are fuzzing to ensure the engine NEVER panics, loops infinitely, or leaks memory.
        if (slicing.splitByPlane(alloc, &t_arena, &g_arena, solid_id, nx, ny, nz, offset)) |_| {} else |_| {}

        t_arena.clearRetainingCapacity();
        g_arena.clearRetainingCapacity(alloc);
    }
}
