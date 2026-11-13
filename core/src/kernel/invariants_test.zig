//! Geometry invariants on what the kernels make: every solid's mesh is closed and
//! consistently oriented, and its own signed volume, area, bounds and Euler characteristic
//! agree with what the kernel reports (the mesh engine's to float precision, the B-Rep
//! engine's exact measures within its chords); booleans, moves and scales keep the volumes
//! they must (inclusion-exclusion, a rigid move keeps volume, scaling by s multiplies it by
//! s³).

const std = @import("std");
const testing = std.testing;
const kernel = @import("kernel.zig");
const geom = @import("../core/geometry_handle.zig");
const mesh_check = @import("mesh_check.zig");
const support = @import("../test_support.zig");

/// The kernel measures in doubles, the exported mesh's positions are floats (about 7 digits).
const RELATIVE_TOLERANCE = 1e-6;
/// What the B-Rep scripts start with: the exact engine, every circle cut into 64 segments.
const BREP_PRELUDE = "CAD.config(engine: :brep, resolution: {segments: 64})\n";
/// How far a mesh's measures are from the exact solid's at 64 segments a turn: a polygon
/// of n sides holds (n / 2π) sin(2π / n) of its circle's disc, a share ε short; a surface
/// curved both ways is a polygon revolved, its section's area, its centroid's distance
/// from the axis and the turn each at most ε short (a sphere's mesh is 2.5ε short).
const CHORDS_64: f64 = 3.0 * (1.0 - 64.0 / (2.0 * std.math.pi) * @sin(2.0 * std.math.pi / 64.0));

/// What the B-Rep engine builds (M1–M4): its exact measures against its own mesh's. One
/// closed surface each (the genus check counts one): a void's two surfaces are checked by
/// the volumes below.
const BREP_SHAPES = [_][]const u8{
    "cube(2)",
    "cube(2, center: true).rotate(x: 30, y: 20)",
    "sphere(3)",
    "cylinder(r: 1, h: 4)",
    "cylinder(r1: 2, r2: 0.5, h: 3)",
    "torus(major_r: 5, minor_r: 1)",
    "(circle(3) - circle(1)).extrude(2)",
    "square(2).translate(x: 3).revolve(270)",
    "square(2).sweep(arc(center: [10, 0], r: 10, start: 180, sweep: 90))",
    "(square(10) - circle(r: 2).translate(5, 5)).offset(1).extrude(1)",
    "polygon([[0, 0], [4, 0], [4, 3]], round_r: 0.5).extrude(2)",
    "cube(2).mirror([1, 0, 0])",
    "sphere(2).scale(2).translate(1, 2, 3)",
    "cube(1).hull(cube(1).translate(x: 3, y: 1))",
    "text(\"Hi\", size: 5).extrude(1)",
    // Booleans of flat solids (M4): exact, so their meshes are the solids
    "cube(2) + cube(2).translate(1, 1, 1)",
    "(cube(2) & cube(2).translate(1, 1, 1)).rotate(30, 40, 50)",
    "cube(4) - cube(2).translate(1, 1, -1)",
    "(square(10).extrude(5) - cube(2, 2, 7).translate(4, 4, -1)).rotate(z: 30)",
    "union([cube(2), cube(2).translate(1, 1, 1), cube(2).translate(2, 2, 2)])",
    "cube(4).rotate(30, 40, 50).trim_by_plane(1, 1, 0, 1)",
};

/// One of each kind of operation the kernel performs.
const SHAPES = [_][]const u8{
    "cube(2)",
    "cube(2, center: true).rotate(x: 30, y: 20)",
    "sphere(3)",
    "cylinder(r: 1, h: 4)",
    "cylinder(r1: 2, r2: 0.5, h: 3)",
    "torus(major_r: 5, minor_r: 1)",
    "cube(3, round_r: 0.5)",
    "cube(3, chamfer: 0.4)",
    "cube(4) - sphere(2.5).translate(x: 2, y: 2, z: 2)",
    "cube(4) & sphere(2.5)",
    "union([cube(1), cube(1).translate(x: 0.5), sphere(0.7)])",
    "[cube(1), cube(1).translate(x: 3)]",
    "(circle(3) - circle(1)).extrude(2)",
    "square(2).translate(x: 3).revolve(270)",
    "square(1, center: true).extrude(4, twist: 90)",
    "cube(1).hull(sphere(1).translate(x: 3))",
    "cube(4).minkowski(sphere(0.5, segments: 16))",
    "cube(2).offset(0.2)",
    "(cube(4) - cylinder(r: 1, h: 6).translate(2, 2, -1)).offset(-0.3)",
    "cube(4).shell(0.5)",
    "cube(2).mirror([1, 0, 0])",
    "cube(2).scale(2)",
    "text(\"Hi\", size: 5).extrude(1)",
};

/// Each sweep and constructor with a parameter that has a sign, as a pair: the parameter one
/// way and the other way (or a mesh wound outward and inward), which makes the mirror image.
/// The profiles are symmetric across the x axis, so a twist one way is the other twist of
/// the same profile, turned.
const MIRRORED = [_][2][]const u8{
    .{ "square(1).translate(x: 2).revolve(90)", "square(1).translate(x: 2).revolve(-90)" },
    .{ "square(1).translate(x: 2).revolve(360)", "square(1).translate(x: 2).revolve(-360)" },
    .{ "square(1, center: true).translate(x: 3).extrude(5, twist: 90)", "square(1, center: true).translate(x: 3).extrude(5, twist: -90)" },
    .{ "square(2, center: true).extrude(5, twist: 45, scale: 0.5)", "square(2, center: true).extrude(5, twist: -45, scale: 0.5)" },
    .{ "square(1, center: true).translate(x: 3).helix(h: 10, twist: 360)", "square(1, center: true).translate(x: 3).helix(h: 10, twist: -360)" },
    .{ "square(1, center: true).translate(x: 3).helix(h: 10, turns: 2)", "square(1, center: true).translate(x: 3).helix(h: 10, turns: -2)" },
    .{ "square(1).loft(square(2), 3)", "square(1).loft(square(2), -3)" },
    .{ "cube(1, 2, 3).scale(2, 1, 1)", "cube(1, 2, 3).scale(-2, 1, 1)" },
    .{ "cube(1, 2, 3).rotate(x: 30)", "cube(1, 2, 3).rotate(x: -30)" },
    .{ "polyhedron([[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]], [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]])", "polyhedron([[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]], [[0, 1, 2], [0, 3, 1], [0, 2, 3], [1, 3, 2]])" },
};

test "invariants: a parameter's other sign makes the mirror image, as much volume and more than none" {
    // A negative revolve was inside out (a volume of -3.75), and a clockwise twist another
    // solid than the counter-clockwise one (8.2 against 11.1)
    for (MIRRORED) |pair| {
        errdefer std.debug.print("scripts: {s} | {s}\n", .{ pair[0], pair[1] });
        var volumes: [2]f64 = undefined;
        for (pair, &volumes) |source, *volume| {
            var vm = try support.initVm();
            defer vm.deinit();
            var script: std.Io.Writer.Allocating = .init(testing.allocator);
            defer script.deinit();
            try script.writer.print("r = {s}", .{source});
            try testing.expectEqual(.ok, try support.runOn(&vm, script.written()));
            const handle = try vm.ensureConcrete(vm.globals.get("r") orelse return error.MissingGlobal);
            try expectConsistent(handle);
            volume.* = kernel.volume(handle);
        }
        try testing.expectApproxEqRel(volumes[0], volumes[1], RELATIVE_TOLERANCE);
    }
}

test "invariants: every solid is closed, and its mesh measures what the kernel reports" {
    for (SHAPES) |source| {
        errdefer std.debug.print("script: {s}\n", .{source});
        var vm = try support.initVm();
        defer vm.deinit();
        var script: std.Io.Writer.Allocating = .init(testing.allocator);
        defer script.deinit();
        try script.writer.print("r = union([{s}].flatten)", .{source});
        try testing.expectEqual(.ok, try support.runOn(&vm, script.written()));
        const handle = try vm.ensureConcrete(vm.globals.get("r") orelse return error.MissingGlobal);
        try expectConsistent(handle);
    }
}

test "invariants on the B-Rep engine: every solid's mesh is closed, its measures the exact ones within its chords" {
    for (BREP_SHAPES) |source| {
        errdefer std.debug.print("script: {s}\n", .{source});
        var vm = try support.initVm();
        defer vm.deinit();
        var script: std.Io.Writer.Allocating = .init(testing.allocator);
        defer script.deinit();
        try script.writer.print("{s}r = {s}", .{ BREP_PRELUDE, source });
        errdefer if (vm.last_error) |m| std.debug.print("error: {s}\n", .{m});
        try testing.expectEqual(.ok, try support.runOn(&vm, script.written()));
        const handle = try vm.ensureConcrete(vm.globals.get("r") orelse return error.MissingGlobal);
        try testing.expectEqual(.brep_native, handle.engine);
        try expectConsistentWithin(handle, CHORDS_64);
    }
}

test "invariants: booleans, moves and scales keep the volumes they must" {
    // a ∪ b + a ∩ b = a + b; a - b = a - a ∩ b; a rigid move keeps volume; scale 2 is 8x.
    try support.expectScripts(&.{
        .{ .src =
        \\a = cube(3)
        \\b = sphere(2).translate(x: 3, y: 1, z: 1)
        \\r = ((a + b).volume + (a & b).volume - a.volume - b.volume).abs < 1e-9 * a.volume
        , .expected = .{ .boolean = true } },
        .{ .src =
        \\a = cube(3)
        \\b = sphere(2).translate(x: 3, y: 1, z: 1)
        \\r = ((a - b).volume - (a.volume - (a & b).volume)).abs < 1e-9 * a.volume
        , .expected = .{ .boolean = true } },
        .{ .src =
        \\a = torus(major_r: 4, minor_r: 1) - cube(2)
        \\moved = a.rotate(x: 37, y: 11, z: 5).translate(x: 3, y: -2, z: 9).mirror([1, 1, 0])
        \\r = (moved.volume - a.volume).abs < 1e-9 * a.volume
        , .expected = .{ .boolean = true } },
        .{ .src =
        \\a = cylinder(r: 1, h: 2) + cube(1)
        \\r = (a.scale(2).volume - 8 * a.volume).abs < 1e-9 * a.volume
        , .expected = .{ .boolean = true } },
    });
}

test "invariants on the B-Rep engine: booleans of flat solids keep the volumes they must, exactly" {
    // As on the mesh engine above, on Locus's own booleans (M4), to rounding: a void, a
    // chain, a turned operand, a cut and its other side
    try support.expectScripts(&.{
        .{ .src = BREP_PRELUDE ++
        \\a = cube(3)
        \\b = cube(2).rotate(20, 30, 40).translate(2, 1, 1)
        \\r = ((a + b).volume + (a & b).volume - a.volume - b.volume).abs < 1e-9 * a.volume
        , .expected = .{ .boolean = true } },
        .{ .src = BREP_PRELUDE ++
        \\a = cube(3)
        \\b = cube(2).rotate(20, 30, 40).translate(2, 1, 1)
        \\r = ((a - b).volume - (a.volume - (a & b).volume)).abs < 1e-9 * a.volume
        , .expected = .{ .boolean = true } },
        .{ .src = BREP_PRELUDE ++
        \\a = cube(4) - cube(2).translate(1, 1, 1)
        \\r = (a.volume - 56).abs < 1e-9 && (a.rotate(37, 11, 5).translate(3, -2, 9).mirror([1, 1, 0]).volume - 56).abs < 1e-9
        , .expected = .{ .boolean = true } },
        .{ .src = BREP_PRELUDE ++
        \\a = union([cube(2), cube(2).translate(1, 1, 1), cube(2).translate(2, 2, 2)])
        \\r = (a.scale(2).volume - 8 * a.volume).abs < 1e-9 * a.volume
        , .expected = .{ .boolean = true } },
        .{ .src = BREP_PRELUDE ++
        \\a = cube(4).rotate(30, 40, 50)
        \\parts = a.split_by_plane(1, 1, 0, 1)
        \\r = (parts[0].volume + parts[1].volume - a.volume).abs < 1e-9 * a.volume
        , .expected = .{ .boolean = true } },
    });
}

/// The mesh is closed and oriented, and its volume, area, bounds and genus are the kernel's.
fn expectConsistent(handle: geom.GeometryHandle) !void {
    return expectConsistentWithin(handle, RELATIVE_TOLERANCE);
}

/// `expectConsistent`, the mesh's volume and area within `relative` of the kernel's and its
/// box within that share of the box's diagonal (a chord's sagitta is less).
fn expectConsistentWithin(handle: geom.GeometryHandle, relative: f64) !void {
    const mesh = kernel.getMesh(testing.allocator, handle) orelse return error.NoMesh;
    defer testing.allocator.free(mesh.vert_props);
    defer testing.allocator.free(mesh.tri_verts);

    const positions = try testing.allocator.alloc(f32, mesh.vert_props.len / mesh.num_prop * 3);
    defer testing.allocator.free(positions);
    for (0..positions.len / 3) |v| @memcpy(positions[v * 3 ..][0..3], mesh.vert_props[v * mesh.num_prop ..][0..3]);
    const welded = try mesh_check.weld(testing.allocator, positions, mesh.tri_verts);
    defer welded.deinit(testing.allocator);
    try mesh_check.expectClosed(testing.allocator, welded.mesh());
    const triangles = welded.triangles;

    var signed_volume: f64 = 0;
    var area: f64 = 0;
    var box: geom.BoundingBox = .{ .min = @splat(std.math.inf(f64)), .max = @splat(-std.math.inf(f64)) };
    var used: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer used.deinit(testing.allocator);
    for (triangles) |t| {
        var p: [3]@Vector(3, f64) = undefined;
        for (&p, t) |*corner, index| {
            try used.put(testing.allocator, index, {});
            const q = positions[index * 3 ..][0..3];
            corner.* = .{ q[0], q[1], q[2] };
            for (0..3) |k| {
                box.min[k] = @min(box.min[k], q[k]);
                box.max[k] = @max(box.max[k], q[k]);
            }
        }
        const c = cross(p[1] - p[0], p[2] - p[0]);
        area += @sqrt(@reduce(.Add, c * c)) / 2;
        signed_volume += @reduce(.Add, p[0] * cross(p[1], p[2])) / 6;
    }

    const volume = kernel.volume(handle);
    try testing.expect(volume > 0);
    errdefer std.debug.print("volume {d} against the mesh's {d}, area {d} against {d}\n", .{ volume, signed_volume, kernel.surfaceArea(handle), area });
    try testing.expectApproxEqRel(volume, signed_volume, relative);
    try testing.expectApproxEqRel(kernel.surfaceArea(handle), area, relative);
    const kernel_box = kernel.boundingBox(handle) orelse return error.NoBounds;
    var diagonal: f64 = 0;
    for (0..3) |k| diagonal += (kernel_box.max[k] - kernel_box.min[k]) * (kernel_box.max[k] - kernel_box.min[k]);
    const reach = @max(1e-6, relative * @sqrt(diagonal));
    for (0..3) |k| {
        try testing.expectApproxEqAbs(kernel_box.min[k], box.min[k], reach);
        try testing.expectApproxEqAbs(kernel_box.max[k], box.max[k], reach);
    }
    // Euler: V - E + F = 2 - 2g for one closed surface, each edge shared by two triangles.
    const vertices: i64 = @intCast(used.count());
    const faces: i64 = @intCast(triangles.len);
    const euler = vertices - @divExact(3 * faces, 2) + faces;
    try testing.expectEqual(@as(i64, kernel.genus(handle)), 1 - @divExact(euler, 2));
}

fn cross(a: @Vector(3, f64), b: @Vector(3, f64)) @Vector(3, f64) {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
