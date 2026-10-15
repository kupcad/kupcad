const std = @import("std");
const testing = std.testing;
const workspace = @import("workspace.zig");

test "Workspace: Kahn's Algorithm sorts dependencies bottom-up" {
    var ws = workspace.Workspace.init(testing.allocator);
    defer ws.deinit();

    // main imports math and hardware
    _ = try ws.addModule("main.kup", "import \"./math.kup\"\nimport \"./hardware.kup\"");

    // hardware imports math
    _ = try ws.addModule("hardware.kup", "import \"./math.kup\"");

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
    _ = try ws.addModule("a.kup", "import \"./b.kup\"");
    _ = try ws.addModule("b.kup", "import \"./c.kup\"");
    _ = try ws.addModule("c.kup", "import \"./a.kup\"");

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

    const id = try ws.addModule("main.kup", "import \"./lib.kup\"");
    const too_big = try testing.allocator.alloc(u8, limits.MAX_SOURCE_BYTES + 1);
    defer testing.allocator.free(too_big);
    @memset(too_big, ' ');

    try testing.expectError(error.SourceTooLarge, ws.addModule("big.kup", too_big));
    try testing.expect(!ws.path_to_id.contains("big.kup"));
    try testing.expectEqual(@as(usize, 1), ws.modules.items.len);

    try testing.expectError(error.SourceTooLarge, ws.updateModuleSource(id, too_big));
    try testing.expectEqualStrings("import \"./lib.kup\"", ws.modules.items[@backingInt(id)].source);

    // The old AST is still usable for linking.
    _ = try ws.addModule("lib.kup", "");
    try ws.linkDependencies();
    try testing.expectEqual(@as(usize, 1), ws.modules.items[@backingInt(id)].deps.items.len);
}

test "Workspace: addModule rejects duplicates; upsertModule replaces source and AST" {
    var ws = workspace.Workspace.init(testing.allocator);
    defer ws.deinit();

    const id = try ws.addModule("main.kup", "x = 1");
    // Used to silently return the old id, so the caller's new source was dropped.
    try testing.expectError(error.DuplicateModule, ws.addModule("main.kup", "x = 2"));
    try testing.expectEqualStrings("x = 1", ws.modules.items[@backingInt(id)].source);

    const new_source = "import \"./lib.kup\"\nx = 2";
    try testing.expectEqual(id, try ws.upsertModule("main.kup", new_source));
    try testing.expectEqualStrings(new_source, ws.modules.items[@backingInt(id)].source);
    try testing.expectEqual(@as(usize, 1), ws.modules.items.len);

    // The AST must be re-parsed too, so dependency linking sees the new import.
    const lib_id = try ws.upsertModule("lib.kup", "y = 1");
    try ws.linkDependencies();
    const deps = ws.modules.items[@backingInt(id)].deps.items;
    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expectEqual(lib_id, deps[0]);
}

test "Workspace: removeModule forgets a module and keeps the other ids valid" {
    var ws = workspace.Workspace.init(testing.allocator);
    defer ws.deinit();
    _ = try ws.addModule("math.kup", "def add(a, b) a + b end");
    _ = try ws.addModule("closed.kup", "x = 1");
    _ = try ws.addModule("main.kup", "import \"./math.kup\"");
    try ws.linkDependencies();

    try testing.expect(try ws.removeModule("closed.kup"));
    try testing.expect(!try ws.removeModule("closed.kup"));

    try testing.expectEqual(@as(usize, 2), ws.modules.items.len);
    try testing.expect(ws.path_to_id.get("closed.kup") == null);
    for (ws.modules.items, 0..) |mod, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), @backingInt(mod.id));
        try testing.expectEqual(mod.id, ws.path_to_id.get(mod.path).?);
    }
    // main's import still points at math, whose id did not move, and main's did.
    const main = ws.modules.items[@backingInt(ws.path_to_id.get("main.kup").?)];
    try testing.expectEqualSlices(workspace.ModuleId, &.{ws.path_to_id.get("math.kup").?}, main.deps.items);
}

test "Workspace: a module's relative imports link to its neighbours" {
    var ws = workspace.Workspace.init(testing.allocator);
    defer ws.deinit();
    const hw = try ws.addModule("parts/hw.kup", "x = 1");
    const main = try ws.addModule("parts/main.kup", "import \"./hw.kup\"");
    // A file of the same name elsewhere is a different module.
    _ = try ws.addModule("hw.kup", "x = 2");
    try ws.linkDependencies();
    try testing.expectEqualSlices(workspace.ModuleId, &.{hw}, ws.modules.items[@backingInt(main)].deps.items);
}
