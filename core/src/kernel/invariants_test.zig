//! Geometry invariants on what the Manifold kernel makes: every solid's mesh is closed and
//! consistently oriented, and its own signed volume, area, bounds and Euler characteristic
//! agree with what the kernel reports; booleans, moves and scales keep the volumes they
//! must (inclusion-exclusion, a rigid move keeps volume, scaling by s multiplies it by s³).

const std = @import("std");
const testing = std.testing;
const kernel = @import("kernel.zig");
const geom = @import("../core/geometry_handle.zig");
const mesh_check = @import("mesh_check.zig");
const support = @import("../test_support.zig");

/// The kernel measures in doubles, the exported mesh's positions are floats (about 7 digits).
const RELATIVE_TOLERANCE = 1e-6;

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

/// The mesh is closed and oriented, and its volume, area, bounds and genus are the kernel's.
fn expectConsistent(handle: geom.GeometryHandle) !void {
    const mesh = kernel.getMesh(testing.allocator, handle) orelse return error.NoMesh;
    defer testing.allocator.free(mesh.vert_props);
    defer testing.allocator.free(mesh.tri_verts);

    const positions = try testing.allocator.alloc(f32, mesh.vert_props.len / mesh.num_prop * 3);
    defer testing.allocator.free(positions);
    for (0..positions.len / 3) |v| @memcpy(positions[v * 3 ..][0..3], mesh.vert_props[v * mesh.num_prop ..][0..3]);
    const triangles = try mesh_check.weld(testing.allocator, positions, mesh.tri_verts);
    defer testing.allocator.free(triangles);
    try mesh_check.expectClosed(testing.allocator, triangles);

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
    try testing.expectApproxEqRel(volume, signed_volume, RELATIVE_TOLERANCE);
    try testing.expectApproxEqRel(kernel.surfaceArea(handle), area, RELATIVE_TOLERANCE);
    const kernel_box = kernel.boundingBox(handle) orelse return error.NoBounds;
    for (0..3) |k| {
        try testing.expectApproxEqAbs(kernel_box.min[k], box.min[k], 1e-6);
        try testing.expectApproxEqAbs(kernel_box.max[k], box.max[k], 1e-6);
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
