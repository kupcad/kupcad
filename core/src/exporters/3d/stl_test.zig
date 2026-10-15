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

test "STL: an engine that can't tessellate yet is an error, not an empty file" {
    const kernel = @import("../../kernel/kernel.zig");
    const part = kernel.cube(&.{ .engine = .brep_native }, 10, 10, 10, false) orelse return error.KernelFailed;
    defer kernel.destruct(part);
    try testing.expectError(error.EngineCannotTessellate, stl.buildStlBuffer(testing.allocator, part));
}
