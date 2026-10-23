const std = @import("std");
const testing = std.testing;
const kernel = @import("kernel.zig");
const test_support = @import("../test_support.zig");
const geom = @import("../core/geometry_handle.zig");
const VM = @import("../vm/vm.zig").VM;
const InterpretResult = @import("../vm/vm.zig").InterpretResult;
const chunk = @import("../vm/chunk.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("../stdlib/registry.zig");

fn initVm() !VM {
    var vm = try VM.init(testing.allocator, testing.io);
    errdefer vm.deinit();
    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);
    return vm;
}

/// Compiles and runs `source` on an existing VM.
fn runOn(vm: *VM, source: []const u8) !InterpretResult {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    return vm.interpret(&out_chunk);
}

fn runScript(source: []const u8) !InterpretResult {
    var vm = try initVm();
    defer vm.deinit(); // double frees used to crash here
    return runOn(&vm, source);
}

test "Kernel Dispatcher: routes primitives to the requested engine" {
    inline for (.{ geom.EngineType.manifold, geom.EngineType.brep_native }) |engine| {
        const handle = kernel.cube(&.{ .engine = engine }, 10.0, 10.0, 10.0, true) orelse return error.DispatchFailed;
        defer kernel.destruct(handle);

        // The returned handle is tagged with, and usable by, the requested engine.
        try testing.expectEqual(engine, handle.engine);
        try testing.expectEqual(@as(usize, 8), kernel.numVerts(handle));
        // The triangle count is the mesh's, so only a mesh engine has one.
        try testing.expectEqual(@as(?usize, if (engine == .manifold) 12 else null), kernel.numTris(handle));
    }
}

test "Kernel Dispatcher: rejects mixed-engine operands at runtime" {
    // Engine tags must be checked: a handle of one engine is never fed to the other.
    const m = kernel.cube(&.{ .engine = .manifold }, 10, 10, 10, false) orelse return error.KernelFailed;
    defer kernel.destruct(m);
    const b = kernel.cube(&.{ .engine = .brep_native }, 20, 20, 20, false) orelse return error.KernelFailed;
    defer kernel.destruct(b);

    try testing.expect(kernel.boolean(b, m, .difference_op) == null);
    try testing.expect(kernel.boolean(m, b, .union_op) == null);
    try testing.expect(kernel.minkowski(m, b) == null);
    try testing.expect(kernel.batchBoolean(testing.allocator, &.{ m, b }, .union_op) == null);
    try testing.expect(kernel.batchHull(testing.allocator, &.{ b, m }) == null);
    try testing.expectEqual(@as(f64, 0.0), kernel.minGap(m, b, 1.0));
}

// --- Handle ownership (single-owner rule) ---

test "Kernel: B-Rep scripts using material/simplify do not double free" {
    // B-Rep drivers used to return their input handle, so both owners freed it.
    // (`simplify` evaluates its receiver, which the B-Rep engine can do.)
    const warnings = test_support.expectWarnings(); // B-Rep drops the material, and says so
    defer warnings.restore();
    try testing.expectEqual(InterpretResult.ok, try runScript(
        \\CAD.config(engine: :brep)
        \\part = cube(10).material(color: "#FF0000")
        \\part.simplify
    ));
    try testing.expectEqual(InterpretResult.ok, try runScript(
        \\CAD.config(engine: :brep)
        \\part = cube(10).simplify
        \\part.simplify
    ));
}

test "Kernel: ghost display list survives garbage collection" {
    // The display list must own its handle, not borrow the dag_cache's.
    var vm = try initVm();
    defer vm.deinit();

    try testing.expectEqual(InterpretResult.ok, try runOn(&vm, "cube(10).ghost\nnil"));
    try testing.expectEqual(@as(usize, 1), vm.display_list.items.len);

    // Nothing roots the ghost geometry; a GC evicts its dag_cache entry.
    vm.resetStack();
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(u32, 0), vm.dag_cache.count());

    try testing.expectApproxEqAbs(@as(f64, 1000.0), kernel.volume(vm.display_list.items[0]), 1e-6);
}

const planar = @import("planar.zig");

/// Whether `p` lies in the region of the closed `contours` (each one's last point joined
/// back to its first).
fn regionContains(contours: []const []const planar.Vec2, p: planar.Vec2, tolerance: f64) bool {
    var region = planar.RegionTest.init(p, tolerance);
    for (contours) |points| {
        if (points.len < 2) continue;
        var prev = points[points.len - 1];
        for (points) |cur| {
            region.addEdge(prev, cur);
            prev = cur;
        }
    }
    return region.contains();
}

/// A polygon's points as a ring for planar.isConvexRing.
const SliceRing = struct {
    points: []const planar.Vec2,
    pub fn len(self: SliceRing) usize {
        return self.points.len;
    }
    pub fn at(self: SliceRing, i: usize) planar.Vec2 {
        return self.points[i];
    }
};

test "Kernel planar: point in region with holes, boundary and orientation" {
    const tol = 1e-9;
    const outer_ccw = [_]planar.Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const outer_cw = [_]planar.Vec2{ .{ 0, 0 }, .{ 0, 10 }, .{ 10, 10 }, .{ 10, 0 } };
    const hole_cw = [_]planar.Vec2{ .{ 4, 4 }, .{ 4, 6 }, .{ 6, 6 }, .{ 6, 4 } };
    const square: []const []const planar.Vec2 = &.{&outer_ccw};
    const ring: []const []const planar.Vec2 = &.{ &outer_ccw, &hole_cw };

    const Case = struct { contours: []const []const planar.Vec2, p: planar.Vec2, inside: bool };
    const cases = [_]Case{
        .{ .contours = square, .p = .{ 5, 5 }, .inside = true },
        .{ .contours = square, .p = .{ 11, 5 }, .inside = false },
        .{ .contours = square, .p = .{ 5, -1e-6 }, .inside = false },
        // Orientation of a lone contour doesn't matter under the nonzero rule.
        .{ .contours = &.{&outer_cw}, .p = .{ 5, 5 }, .inside = true },
        // Boundary: edges, vertices, and a ray passing exactly through a vertex.
        .{ .contours = square, .p = .{ 10, 5 }, .inside = true },
        .{ .contours = square, .p = .{ 0, 0 }, .inside = true },
        .{ .contours = square, .p = .{ -1, 10 }, .inside = false },
        // A hole wound opposite to its outer contour is excluded, its outline is not.
        .{ .contours = ring, .p = .{ 5, 5 }, .inside = false },
        .{ .contours = ring, .p = .{ 4, 5 }, .inside = true },
        .{ .contours = ring, .p = .{ 2, 2 }, .inside = true },
        // Degenerate input: no contours, or a contour too short to have edges.
        .{ .contours = &.{}, .p = .{ 0, 0 }, .inside = false },
        .{ .contours = &.{&[_]planar.Vec2{.{ 1, 1 }}}, .p = .{ 1, 1 }, .inside = false },
    };
    for (cases) |case| {
        errdefer std.debug.print("point: {any}\n", .{case.p});
        try std.testing.expectEqual(case.inside, regionContains(case.contours, case.p, tol));
    }
    // The tolerance widens only the outline, symmetrically.
    try std.testing.expect(regionContains(square, .{ 10.0005, 5 }, 1e-3));
    try std.testing.expect(!regionContains(square, .{ 10.002, 5 }, 1e-3));
}

test "Kernel planar: isConvexRing" {
    const Case = struct { pts: []const planar.Vec2, convex: bool };
    const cases = [_]Case{
        .{ .pts = &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } }, .convex = true },
        .{ .pts = &.{ .{ 0, 0 }, .{ 0, 10 }, .{ 10, 10 }, .{ 10, 0 } }, .convex = true }, // clockwise
        .{ .pts = &.{ .{ 0, 0 }, .{ 5, 0 }, .{ 10, 0 }, .{ 10, 10 } }, .convex = true }, // collinear point
        .{ .pts = &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 5, 3 }, .{ 0, 10 } }, .convex = false }, // notch
        .{ .pts = &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 5 }, .{ 5, 5 }, .{ 5, 10 }, .{ 0, 10 } }, .convex = false }, // L
        .{ .pts = &.{ .{ 0, 0 }, .{ 1, 1 } }, .convex = false },
        .{ .pts = &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 } }, .convex = false }, // all collinear
    };
    for (cases) |case| {
        errdefer std.debug.print("points: {any}\n", .{case.pts});
        try std.testing.expectEqual(case.convex, planar.isConvexRing(SliceRing{ .points = case.pts }));
    }
}
