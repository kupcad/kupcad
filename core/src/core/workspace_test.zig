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
    try testing.expectEqualStrings("math.kup", ws.modules.items[@intFromEnum(sorted[0])].path);
    // hardware relies on math, so it comes second
    try testing.expectEqualStrings("hardware.kup", ws.modules.items[@intFromEnum(sorted[1])].path);
    // main relies on both, so it comes last
    try testing.expectEqualStrings("main.kup", ws.modules.items[@intFromEnum(sorted[2])].path);
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
