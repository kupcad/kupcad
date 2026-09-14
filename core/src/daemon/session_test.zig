const std = @import("std");
const testing = std.testing;
const ScriptSession = @import("session.zig").ScriptSession;
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../kernel/geometry_handle.zig");

test "ScriptSession: init and deinit manage memory cleanly" {
    var session = try ScriptSession.init(testing.allocator, testing.io);
    defer session.deinit();

    try testing.expectEqual(@as(u64, 1), session.global_revision);
    try testing.expectEqual(@as(usize, 0), session.nodes.items.len);
}

test "ScriptSession: buildReverseGraph inverts workspace module dependency edges" {
    var session = try ScriptSession.init(testing.allocator, testing.io);
    defer session.deinit();

    // Use exact pathing to ensure dependency linker resolves correctly
    const child_path = "math.kup";
    const parent_path = "main.kup";

    const child_id = try session.workspace.addModule(child_path, "def square(x) x * x end");
    const parent_id = try session.workspace.addModule(parent_path, "import \"math.kup\" as math; val = math.square(5)");

    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    try testing.expectEqual(@as(usize, 2), session.nodes.items.len);

    const parents = session.reverse_deps.get(child_id);
    try testing.expect(parents != null);
    try testing.expectEqual(@as(usize, 1), parents.?.items.len);
    try testing.expectEqual(parent_id, parents.?.items[0]);
}

test "ScriptSession: markFileEdited triggers reverse BFS invalidation" {
    var session = try ScriptSession.init(testing.allocator, testing.io);
    defer session.deinit();

    const child_path = "math.kup";
    const parent_path = "main.kup";

    const child_id = try session.workspace.addModule(child_path, "def square(x) x * x end");
    const parent_id = try session.workspace.addModule(parent_path, "import \"math.kup\" as math; val = math.square(5)");

    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    // Mark as clean initial evaluation state
    session.nodes.items[@intFromEnum(child_id)].is_stale = false;
    session.nodes.items[@intFromEnum(parent_id)].is_stale = false;

    // Edit child file
    try session.markFileEdited(child_path);

    try testing.expectEqual(@as(u64, 2), session.global_revision);
    try testing.expect(session.nodes.items[@intFromEnum(child_id)].is_stale);
    try testing.expect(session.nodes.items[@intFromEnum(parent_id)].is_stale);
}

test "ScriptSession: evaluateModule compiles code, stores CAD handle, and applies Wyhash early cutoff" {
    var session = try ScriptSession.init(testing.allocator, testing.io);
    defer session.deinit();

    const file_path = "model.kup";
    const mod_id = try session.workspace.addModule(file_path, "c = cube(10.0)");

    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    // 1. Initial Evaluation
    try session.evaluateModule(mod_id);

    const node1 = &session.nodes.items[@intFromEnum(mod_id)];
    try testing.expect(!node1.is_stale);
    try testing.expectEqual(@as(u64, 1), node1.verified_at);
    try testing.expect(node1.cached_handle != null);
    try testing.expect(node1.output_hash != 0);

    const initial_hash = node1.output_hash;

    // Verify 10x10x10 cube volume (1000.0) from cached handle
    const vol = kernel.volume(node1.cached_handle.?);
    try testing.expectApproxEqAbs(@as(f64, 1000.0), vol, 1e-4);

    // 2. Modify code to yield the identical output geometry (variable renaming)
    var mod = &session.workspace.modules.items[@intFromEnum(mod_id)];
    testing.allocator.free(mod.source);
    mod.source = try testing.allocator.dupe(u8, "box = cube(10.0)");

    try session.markFileEdited(file_path);

    try testing.expectEqual(@as(u64, 2), session.global_revision);

    // 3. Re-evaluate module
    try session.evaluateModule(mod_id);

    const node2 = &session.nodes.items[@intFromEnum(mod_id)];
    try testing.expect(!node2.is_stale);
    try testing.expectEqual(@as(u64, 2), node2.verified_at);

    // Wyhash early cutoff should detect identical output_hash
    try testing.expectEqual(initial_hash, node2.output_hash);
    try testing.expect(node2.cached_handle != null);
}
