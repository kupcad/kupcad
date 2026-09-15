const std = @import("std");
const gltf = @import("gltf.zig");
const registry = @import("../../stdlib/registry.zig");
const dag_evaluator = @import("../../vm/dag_evaluator.zig");
const geom = @import("../../kernel/geometry_handle.zig");
const VM = @import("../../vm/vm.zig").VM;

test "GLTF: Zero-Copy GLB export generates valid binary container" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const cube_idx = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    const handle = try dag_evaluator.evaluateDAG(&vm, cube_idx);

    const handles = [_]geom.GeometryHandle{handle};
    const glb_bytes = try gltf.buildGltfBuffer(std.testing.allocator, &vm, &handles, false);
    defer std.testing.allocator.free(glb_bytes);

    // 1. Check GLB Magic Bytes "glTF"
    try std.testing.expect(glb_bytes.len > 12);
    try std.testing.expectEqualStrings("glTF", glb_bytes[0..4]);

    // 2. Check Version == 2
    var version: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&version), glb_bytes[4..8]);
    try std.testing.expectEqual(@as(u32, 2), version);
}
