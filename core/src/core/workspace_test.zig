const std = @import("std");
const testing = std.testing;
const workspace = @import("workspace.zig");

test "Workspace: Kahn's Algorithm sorts dependencies bottom-up" {
    var ws = workspace.Workspace.init(testing.allocator);
    defer ws.deinit();

    // main imports math and hardware
    _ = try ws.addModule("main.kup", "import \"math.kup\"\nimport \"hardware.kup\"");

    // hardware imports math
    _ = try ws.addModule("hardware.kup", "import \"math.kup\"");

    // math imports nothing (Leaf)
    _ = try ws.addModule("math.kup", "def add(a, b) a + b end");

    try ws.linkDependencies();

    const sorted = try ws.sortModules();
    defer testing.allocator.free(sorted);

    try testing.expectEqual(@as(usize, 3), sorted.len);

    // math must be compiled first
    try testing.expectEqualStrings("math.kup", ws.modules.items[@backingInt(sorted[0])].path);
    // hardware relies on math, so it comes second
    try testing.expectEqualStrings("hardware.kup", ws.modules.items[@backingInt(sorted[1])].path);
    // main relies on both, so it comes last
    try testing.expectEqualStrings("main.kup", ws.modules.items[@backingInt(sorted[2])].path);
}

test "Workspace: Kahn's Algorithm detects circular dependencies" {
    var ws = workspace.Workspace.init(testing.allocator);
    defer ws.deinit();

    // A -> B -> C -> A
    _ = try ws.addModule("a.kup", "import \"b.kup\"");
    _ = try ws.addModule("b.kup", "import \"c.kup\"");
    _ = try ws.addModule("c.kup", "import \"a.kup\"");

    try ws.linkDependencies();

    const result = ws.sortModules();
    try testing.expectError(error.CircularDependency, result);
}

test "Workspace: correctly populates Module Export Tables" {
    var ws = workspace.Workspace.init(testing.allocator);
    defer ws.deinit();

    const source =
        \\export { ThreadedInsert, Screw } from "hardware.kup"
        \\export { Box } from "housing.kup"
    ;

    const id = try ws.addModule("main.kup", source);
    try ws.linkDependencies();

    const mod = &ws.modules.items[@backingInt(id)];

    // It should have extracted 3 exported symbols!
    try testing.expectEqual(@as(usize, 3), mod.exports.count());
    try testing.expect(mod.exports.contains("ThreadedInsert"));
    try testing.expect(mod.exports.contains("Screw"));
    try testing.expect(mod.exports.contains("Box"));
}

test "Workspace: failed add/update leave the workspace unchanged" {
    const limits = @import("limits.zig");
    var ws = workspace.Workspace.init(testing.allocator);
    defer ws.deinit();

    const id = try ws.addModule("main.kup", "import \"lib.kup\"");
    const too_big = try testing.allocator.alloc(u8, limits.MAX_SOURCE_BYTES + 1);
    defer testing.allocator.free(too_big);
    @memset(too_big, ' ');

    try testing.expectError(error.SourceTooLarge, ws.addModule("big.kup", too_big));
    try testing.expect(!ws.path_to_id.contains("big.kup"));
    try testing.expectEqual(@as(usize, 1), ws.modules.items.len);

    try testing.expectError(error.SourceTooLarge, ws.updateModuleSource(id, too_big));
    try testing.expectEqualStrings("import \"lib.kup\"", ws.modules.items[@backingInt(id)].source);

    // The old AST is still usable for linking.
    _ = try ws.addModule("lib.kup", "");
    try ws.linkDependencies();
    try testing.expectEqual(@as(usize, 1), ws.modules.items[@backingInt(id)].deps.items.len);
}
