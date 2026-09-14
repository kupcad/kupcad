const std = @import("std");
const testing = std.testing;
const ScriptSession = @import("session.zig").ScriptSession;
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../kernel/geometry_handle.zig");
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

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

test "ScriptSession: evaluateWorkspace processes multi-file dependencies and propagates early cutoffs" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var session = try ScriptSession.init(testing.allocator, testing.io);
    defer session.deinit();

    session.vm.vfs = mem_vfs.vfs();

    const leaf_path = "./leaf.kup";
    const root_path = "./root.kup";

    const leaf_source = "c = cube(10.0); export c;";
    const root_source = "import { c as l_c } from \"./leaf.kup\"; out = l_c.translate(20.0, 0.0, 0.0); export out;";

    try mem_vfs.vfs().writeFile(leaf_path, leaf_source);
    try mem_vfs.vfs().writeFile(root_path, root_source);

    const leaf_id = try session.workspace.addModule(leaf_path, leaf_source);
    const root_id = try session.workspace.addModule(root_path, root_source);

    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    // 1. Initial full workspace evaluation
    try session.evaluateWorkspace();

    var leaf_node = &session.nodes.items[@intFromEnum(leaf_id)];
    var root_node = &session.nodes.items[@intFromEnum(root_id)];

    try testing.expectEqual(@as(u64, 1), leaf_node.verified_at);
    try testing.expectEqual(@as(u64, 1), root_node.verified_at);
    try testing.expectEqual(@as(u64, 1), leaf_node.changed_at);
    try testing.expectEqual(@as(u64, 1), root_node.changed_at);

    // 2. Modify the leaf script to yield the EXACT SAME topological geometry
    const new_leaf_source = "c = cube(x: 10.0, y: 10.0, z: 10.0); export c;";
    try mem_vfs.vfs().writeFile(leaf_path, new_leaf_source);

    var mod_leaf = &session.workspace.modules.items[@intFromEnum(leaf_id)];
    testing.allocator.free(mod_leaf.source);
    mod_leaf.source = try testing.allocator.dupe(u8, new_leaf_source);

    // Invalidates leaf.kup and reverse-BFS invalidates root.kup
    try session.markFileEdited(leaf_path);
    try testing.expectEqual(@as(u64, 2), session.global_revision);

    // 3. Re-evaluate workspace
    try session.evaluateWorkspace();

    leaf_node = &session.nodes.items[@intFromEnum(leaf_id)];
    root_node = &session.nodes.items[@intFromEnum(root_id)];

    // Both files were verified topologically in revision 2
    try testing.expectEqual(@as(u64, 2), leaf_node.verified_at);
    try testing.expectEqual(@as(u64, 2), root_node.verified_at);

    // THE CRITICAL EARLY CUTOFF ASSERTION:
    // Leaf node was re-evaluated so its verified timestamp updated,
    // but because its Wyhash matched, the early cutoff intercepted the downstream propagation!
    // Root node's `changed_at` MUST remain 1, proving the parent kernel operation was bypassed!
    try testing.expectEqual(@as(u64, 1), root_node.changed_at);
}

test "ScriptSession: deep dependency chain short-circuits propagation on identical intermediate output" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var session = try ScriptSession.init(testing.allocator, testing.io);
    defer session.deinit();
    session.vm.vfs = mem_vfs.vfs();

    const a_source = "out = cube(10.0); export out;";
    const b_source = "import { out as a_out } from \"./a.kup\"; out_b = a_out.translate(5.0, 0.0, 0.0); export out_b;";
    const c_source = "import { out_b as b_out } from \"./b.kup\"; out_c = b_out.translate(0.0, 5.0, 0.0); export out_c;";

    try mem_vfs.vfs().writeFile("./a.kup", a_source);
    try mem_vfs.vfs().writeFile("./b.kup", b_source);
    try mem_vfs.vfs().writeFile("./c.kup", c_source);

    // A -> B -> C
    const a_id = try session.workspace.addModule("./a.kup", a_source);
    const b_id = try session.workspace.addModule("./b.kup", b_source);
    const c_id = try session.workspace.addModule("./c.kup", c_source);

    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    try session.evaluateWorkspace();

    // Change 'A' source code but maintain identical geometric output
    const new_a_source = "x = cube(10.0); out = x; export out;";
    try mem_vfs.vfs().writeFile("./a.kup", new_a_source);

    var mod_a = &session.workspace.modules.items[@intFromEnum(a_id)];
    testing.allocator.free(mod_a.source);
    mod_a.source = try testing.allocator.dupe(u8, new_a_source);

    try session.markFileEdited("./a.kup");
    try session.evaluateWorkspace();

    const a_node = &session.nodes.items[@intFromEnum(a_id)];
    const b_node = &session.nodes.items[@intFromEnum(b_id)];
    const c_node = &session.nodes.items[@intFromEnum(c_id)];

    // ALL verified_at timestamps updated to 2 during the topological pass
    try testing.expectEqual(@as(u64, 2), a_node.verified_at);
    try testing.expectEqual(@as(u64, 2), b_node.verified_at);
    try testing.expectEqual(@as(u64, 2), c_node.verified_at);

    // Downstream B and C changed_at timestamps remain 1 because A's output matched, completely bypassing B and C!
    try testing.expectEqual(@as(u64, 1), b_node.changed_at);
    try testing.expectEqual(@as(u64, 1), c_node.changed_at);
}

test "ScriptSession: gracefully halts evaluation on syntax error and leaves downstream stale" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var session = try ScriptSession.init(testing.allocator, testing.io);
    defer session.deinit();
    session.vm.vfs = mem_vfs.vfs();

    const a_source = "out = cube(10.0); export out;";
    const b_source = "import { out as a_out } from \"./a.kup\"; out_b = a_out.translate(5.0, 0.0, 0.0); export out_b;";

    try mem_vfs.vfs().writeFile("./a.kup", a_source);
    try mem_vfs.vfs().writeFile("./b.kup", b_source);

    const a_id = try session.workspace.addModule("./a.kup", a_source);
    const b_id = try session.workspace.addModule("./b.kup", b_source);

    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    // Initial evaluation succeeds
    try session.evaluateWorkspace();

    // Introduce a syntax error in A
    const bad_a_source = "out = cube(10.0; export out;";
    try mem_vfs.vfs().writeFile("./a.kup", bad_a_source);

    var mod_a = &session.workspace.modules.items[@intFromEnum(a_id)];
    testing.allocator.free(mod_a.source);
    mod_a.source = try testing.allocator.dupe(u8, bad_a_source);

    try session.markFileEdited("./a.kup");

    const err = session.evaluateWorkspace();
    try testing.expectError(error.ParseError, err);

    const a_node = &session.nodes.items[@intFromEnum(a_id)];
    const b_node = &session.nodes.items[@intFromEnum(b_id)];

    try testing.expect(a_node.is_stale);
    try testing.expect(b_node.is_stale);
}
