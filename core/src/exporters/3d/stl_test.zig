const std = @import("std");
const testing = std.testing;
const stl = @import("stl.zig");
const registry = @import("../../stdlib/registry.zig");
const dag_evaluator = @import("../../vm/dag_evaluator.zig");
const VM = @import("../../vm/vm.zig").VM;

test "STL: binary triangle count cannot wrap the length check" {
    // 85_899_346 * 50 == 2^32 + 4, so in u32 math 84 + n*50 wraps to 88 and a
    // 100-byte buffer used to pass the check and then be read far out of bounds.
    // Not binary, then; as ASCII it has no facets.
    var data: [100]u8 = @splat(0);
    std.mem.writeInt(u32, data[80..84], 85_899_346, .little);
    try testing.expectError(error.InvalidStl, stl.parseStlBuffer(testing.allocator, &data));
}

test "STL: an exported cube reads back as the same cube" {
    // There used to be a second, unused STL reader and writer (formats/stl.zig).
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const handle = try dag_evaluator.evaluateDAG(&vm, try vm.dag_builder.addCube(2, 3, 4, false));

    const bytes = try stl.buildStlBuffer(testing.allocator, handle);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 84 + 12 * 50), bytes.len);
    try testing.expectEqualStrings("KupCAD Export", bytes[0.."KupCAD Export".len]);
    try testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, bytes[80..84], .little));

    var mesh = try stl.parseStlBuffer(testing.allocator, bytes);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8), mesh.points.len);
    try testing.expectEqual(@as(usize, 12), mesh.faces.len);
    var max: [3]f64 = @splat(0);
    for (mesh.points) |p| {
        for (&max, p) |*m, c| m.* = @max(m.*, c);
    }
    try testing.expectEqual([3]f64{ 2, 3, 4 }, max);
}

test "STL: ASCII files are read too" {
    const ascii =
        \\solid t
        \\facet normal 0 0 1
        \\ outer loop
        \\  vertex 0 0 0
        \\  vertex 1 0 0
        \\  vertex 0 1 0
        \\ endloop
        \\endfacet
        \\endsolid t
    ;
    var mesh = try stl.parseStlBuffer(testing.allocator, ascii);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), mesh.points.len);
    try testing.expectEqual([3]u32{ 0, 1, 2 }, mesh.faces[0]);
}

test "STL: several parts are written as their union, from the kernel's handles alone" {
    // The writer took the VM, to check the engine's features and raise; its caller does
    const kernel = @import("../../kernel/kernel.zig");
    const small = kernel.cube(&.{}, 10, 10, 10, false) orelse return error.KernelFailed;
    defer kernel.destruct(small);
    const large = kernel.cube(&.{}, 20, 20, 20, false) orelse return error.KernelFailed;
    defer kernel.destruct(large);

    try testing.expectError(error.NoGeometry, stl.buildStlOfParts(testing.allocator, &.{}));
    const bytes = try stl.buildStlOfParts(testing.allocator, &.{ small, large });
    defer testing.allocator.free(bytes);
    var mesh = try stl.parseStlBuffer(testing.allocator, bytes);
    defer mesh.deinit(testing.allocator);
    // The small cube is inside the large one: their union is the large cube
    try testing.expectEqual(@as(usize, 12), mesh.faces.len);
    var max: [3]f64 = @splat(0);
    for (mesh.points) |p| {
        for (&max, p) |*m, c| m.* = @max(m.*, c);
    }
    try testing.expectEqual([3]f64{ 20, 20, 20 }, max);
}

test "STL: an engine that can't tessellate yet is an error, not an empty file" {
    const kernel = @import("../../kernel/kernel.zig");
    const part = kernel.cube(&.{ .engine = .brep_native }, 10, 10, 10, false) orelse return error.KernelFailed;
    defer kernel.destruct(part);
    try testing.expectError(error.EngineCannotTessellate, stl.buildStlBuffer(testing.allocator, part));
}

test "STL: an empty solid is an error, not a file with no triangles" {
    // It exported as an 84-byte file that KupCAD's own importer rejects, with exit 0.
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const inner = try vm.dag_builder.addCube(1, 1, 1, false);
    const outer = try vm.dag_builder.addCube(2, 2, 2, false);
    const handle = try dag_evaluator.evaluateDAG(&vm, try vm.dag_builder.addBinary(.difference_op, inner, outer));
    try testing.expectError(error.NoGeometry, stl.buildStlBuffer(testing.allocator, handle));
}

test "STL: every exported solid reads back closed and consistently oriented" {
    // The reader welds equal positions, so a closed solid's triangles share their edges.
    const api = @import("../../api.zig");
    const mesh_check = @import("../../kernel/mesh_check.zig");
    for ([_][]const u8{
        "cube(10)",
        "sphere(5)",
        "cylinder(r: 3, h: 8)",
        "cube(10) - cylinder(r: 3, h: 30).translate(x: 5, y: 5, z: -10)",
        "cube(10) + sphere(4).translate(x: 10, y: 5, z: 5)",
        "[cube(2), sphere(1).translate(x: 5)]",
    }) |source| {
        errdefer std.debug.print("script: {s}\n", .{source});
        const bytes = try api.buildModel(testing.allocator, testing.io, source, .{ .format = .stl });
        defer testing.allocator.free(bytes);
        var mesh = try stl.parseStlBuffer(testing.allocator, bytes);
        defer mesh.deinit(testing.allocator);
        try mesh_check.expectClosed(testing.allocator, mesh.faces);
    }
}

test "STL: a vertex that is NaN or infinite is an error, in either format" {
    // The parser took any float, and the mesh it made crashed the build where the DAG
    // checks its points (found by the importer fuzz test).
    const ascii = "solid x\nfacet normal 0 0 1\nouter loop\nvertex nan 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid x\n";
    try testing.expectError(error.NonFiniteVertex, stl.parseStlBuffer(testing.allocator, ascii));
    const ascii_inf = "solid x\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex inf 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid x\n";
    try testing.expectError(error.NonFiniteVertex, stl.parseStlBuffer(testing.allocator, ascii_inf));

    var binary: [84 + 50]u8 = @splat(0);
    std.mem.writeInt(u32, binary[80..84], 1, .little);
    std.mem.writeInt(u32, binary[84 + 12 ..][0..4], @bitCast(std.math.inf(f32)), .little);
    try testing.expectError(error.NonFiniteVertex, stl.parseStlBuffer(testing.allocator, &binary));
}
