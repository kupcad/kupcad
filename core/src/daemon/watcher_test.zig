const std = @import("std");
const testing = std.testing;
const xev = @import("xev");
const ScriptSession = @import("session.zig").ScriptSession;
const Watcher = @import("watcher.zig").Watcher;

test "Daemon Watcher: detects file modification on event loop tick" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_dir_path);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_watch_target.kup", .{tmp_dir_path});
    defer testing.allocator.free(file_path);

    // 1. Create a temporary source file inside isolated tmpDir
    const cwd = std.Io.Dir.cwd();
    {
        const file = try cwd.createFile(testing.io, file_path, .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, "x = cube(10)\n");
    }

    // 2. Initialize Session and Module
    var session = try ScriptSession.init(testing.allocator, testing.io);
    defer session.deinit();

    _ = try session.workspace.addModule(file_path, "x = cube(10)\n");
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    const root_id = session.workspace.path_to_id.get(file_path).?;

    // Clear initial state (global_revision starts at 1)
    session.nodes.items[@intFromEnum(root_id)].is_stale = false;
    session.nodes.items[@intFromEnum(root_id)].verified_at = 1;

    // 3. Initialize Watcher & enable one-shot mode for unit test isolation
    var watcher = try Watcher.init(&session, file_path, testing.io);
    defer watcher.deinit();
    watcher.is_one_shot = true;

    // 4. Sleep briefly to ensure filesystem mtime timestamp increments, then modify file
    testing.io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
    {
        const file = try cwd.createFile(testing.io, file_path, .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, "x = cube(20)\n");
    }

    // 5. Run a single poll cycle via native std.Io async engine
    try watcher.start();

    // 6. Assert that markFileEdited bumped revision to 2 AND re-evaluation verified the node
    try testing.expectEqual(@as(u64, 2), session.global_revision);

    const node = session.nodes.items[@intFromEnum(root_id)];
    try testing.expectEqual(@as(u64, 2), node.verified_at);
    try testing.expect(!node.is_stale);
}
