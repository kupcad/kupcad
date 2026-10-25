const std = @import("std");
const testing = std.testing;
const ScriptSession = @import("session.zig").ScriptSession;
const watcher_mod = @import("watcher.zig");
const Watcher = watcher_mod.Watcher;
const kernel = @import("../kernel/kernel.zig");
const NativeVfs = @import("../vfs/native.zig").NativeVfs;

/// Pushes a file's mtime explicitly so change detection never depends on the
/// filesystem's timestamp granularity (no sleeps needed).
const MTIME_BUMP_NS: i96 = std.time.ns_per_s;

/// Records what the watcher reports.
const Recorder = struct {
    events: std.ArrayList(std.meta.Tag(watcher_mod.Event)) = .empty,
    failed_module_path: ?[]const u8 = null,
    session: *ScriptSession,

    fn listener(self: *Recorder) watcher_mod.Listener {
        return .{ .ptr = self, .onEvent = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: watcher_mod.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.events.append(testing.allocator, event) catch @panic("OOM");
        if (event == .failed) self.failed_module_path = self.session.workspace.modules.items[@backingInt(event.failed.module)].path;
    }

    fn deinit(self: *Recorder) void {
        self.events.deinit(testing.allocator);
    }
};

const Fixture = struct {
    tmp: testing.TmpDir,
    dir: []u8,
    /// The disk, as `kupcad watch` gives it; on the heap, since the session points at it.
    disk: *NativeVfs,
    session: ScriptSession,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        // Relative to the test's cwd: the VM's file system refuses absolute paths, as it
        // does for a script given to `kupcad watch`.
        const dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
        errdefer testing.allocator.free(dir);
        const disk = try testing.allocator.create(NativeVfs);
        errdefer testing.allocator.destroy(disk);
        disk.* = NativeVfs.init(testing.io, std.Io.Dir.cwd());
        return .{ .tmp = tmp, .dir = dir, .disk = disk, .session = try ScriptSession.init(testing.allocator, testing.io, disk.vfs()) };
    }

    fn deinit(self: *Fixture) void {
        self.session.deinit();
        testing.allocator.destroy(self.disk);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn path(self: *Fixture, name: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ self.dir, name });
    }

    fn write(self: *Fixture, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }

    /// Rewrites `name` (a module or a data file) with its mtime moved by `bump` from the
    /// watcher's last sighting.
    fn rewrite(self: *Fixture, watcher: *const Watcher, name: []const u8, data: []const u8, bump: i96) !void {
        const full = try self.path(name);
        defer testing.allocator.free(full);
        const seen = watcher.mtimes.get(full) orelse watcher.data_mtimes.get(full) orelse return error.NotWatched;
        const file = try self.tmp.dir.createFile(testing.io, name, .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, data);
        const new_mtime = std.Io.Timestamp.fromNanoseconds(@intCast(seen + bump));
        try file.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = new_mtime } });
    }

    /// Loads `root` (written already) with its imports, as the watch command does.
    fn load(self: *Fixture, root: []const u8) ![]u8 {
        const full = try self.path(root);
        errdefer testing.allocator.free(full);
        const source = try self.tmp.dir.readFileAlloc(testing.io, root, testing.allocator, .limited(1 << 16));
        defer testing.allocator.free(source);
        _ = try self.session.workspace.addModule(full, source);
        try self.session.loadImports();
        return full;
    }

    fn rootVolume(self: *Fixture, root_path: []const u8) f64 {
        const id = self.session.workspace.path_to_id.get(root_path).?;
        return kernel.volume(self.session.nodes.items[@backingInt(id)].cached_handle.?);
    }
};

test "Daemon Watcher: re-reads and re-evaluates the file after a modification" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("watched.kup", "x = cube(10)\n");
    const root = try fx.load("watched.kup");
    defer testing.allocator.free(root);
    var recorder = Recorder{ .session = &fx.session };
    defer recorder.deinit();
    var watcher = try Watcher.init(&fx.session, testing.io, recorder.listener());
    defer watcher.deinit();
    try testing.expect(watcher.evaluate());

    try fx.rewrite(&watcher, "watched.kup", "x = cube(20)\n", MTIME_BUMP_NS);
    try testing.expect(try watcher.poll());

    // The new source was used (it used to re-run the stale initial source).
    try testing.expectEqualStrings("x = cube(20)\n", fx.session.workspace.modules.items[0].source);
    try testing.expectApproxEqAbs(@as(f64, 20 * 20 * 20), fx.rootVolume(root), 1e-6);
    try testing.expectEqualSlices(std.meta.Tag(watcher_mod.Event), &.{ .built, .changed, .built }, recorder.events.items);
    try testing.expect(!try watcher.poll()); // nothing changed since
}

test "Daemon Watcher: an edit to an imported module rebuilds the script" {
    // Only the root was watched, and its imports came from the VM's import cache, so an
    // edit to a module never showed up.
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("lib.kup", "side = 10\nexport side\n");
    try fx.write("main.kup", "import { side } from \"./lib.kup\"\nx = cube(side)\n");
    const root = try fx.load("main.kup");
    defer testing.allocator.free(root);
    try testing.expectEqual(@as(usize, 2), fx.session.workspace.modules.items.len);

    var recorder = Recorder{ .session = &fx.session };
    defer recorder.deinit();
    var watcher = try Watcher.init(&fx.session, testing.io, recorder.listener());
    defer watcher.deinit();
    errdefer {
        std.debug.print("events: {any}\n", .{recorder.events.items});
        if (fx.session.failure) |f| for (f.diagnostics) |d| std.debug.print("diag: {s}\n", .{d.message});
    }
    try testing.expect(watcher.evaluate());
    try testing.expectApproxEqAbs(@as(f64, 1000), fx.rootVolume(root), 1e-6);

    try fx.rewrite(&watcher, "lib.kup", "side = 20\nexport side\n", MTIME_BUMP_NS);
    try testing.expect(try watcher.poll());
    try testing.expectApproxEqAbs(@as(f64, 8000), fx.rootVolume(root), 1e-6);
}

test "Daemon Watcher: a module deleted is told once, and rebuilt from when it is back" {
    // A module whose file went was passed over: the build stayed "up to date" without it
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("lib.kup", "side = 10\nexport side\n");
    try fx.write("main.kup", "import { side } from \"./lib.kup\"\nx = cube(side)\n");
    const root = try fx.load("main.kup");
    defer testing.allocator.free(root);
    var recorder = Recorder{ .session = &fx.session };
    defer recorder.deinit();
    var watcher = try Watcher.init(&fx.session, testing.io, recorder.listener());
    defer watcher.deinit();
    try testing.expect(watcher.evaluate());

    try fx.tmp.dir.deleteFile(testing.io, "lib.kup");
    _ = try watcher.poll();
    try testing.expectEqualSlices(std.meta.Tag(watcher_mod.Event), &.{ .built, .changed, .reload_failed }, recorder.events.items);
    _ = try watcher.poll();
    try testing.expectEqual(@as(usize, 3), recorder.events.items.len);

    try fx.write("lib.kup", "side = 20\nexport side\n");
    try testing.expect(try watcher.poll());
    try testing.expectApproxEqAbs(@as(f64, 8000), fx.rootVolume(root), 1e-6);
}

test "Daemon Watcher: an edit to a module reached through a re-export rebuilds the script" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("lib.kup", "side = 10\nexport side\n");
    try fx.write("mid.kup", "export { side } from \"./lib.kup\"\n");
    try fx.write("main.kup", "import { side } from \"./mid.kup\"\nx = cube(side)\n");
    const root = try fx.load("main.kup");
    defer testing.allocator.free(root);
    // lib.kup is in the workspace too, so it is watched
    try testing.expectEqual(@as(usize, 3), fx.session.workspace.modules.items.len);

    var recorder = Recorder{ .session = &fx.session };
    defer recorder.deinit();
    var watcher = try Watcher.init(&fx.session, testing.io, recorder.listener());
    defer watcher.deinit();
    try testing.expect(watcher.evaluate());
    try testing.expectApproxEqAbs(@as(f64, 1000), fx.rootVolume(root), 1e-6);

    try fx.rewrite(&watcher, "lib.kup", "side = 20\nexport side\n", MTIME_BUMP_NS);
    try testing.expect(try watcher.poll());
    try testing.expectApproxEqAbs(@as(f64, 8000), fx.rootVolume(root), 1e-6);
}

test "Daemon Watcher: a build that fails is reported, and watching goes on" {
    // A failed build after a change printed no diagnostics; a failed first build ended
    // the command.
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("watched.kup", "x = cube(\n");
    const root = try fx.load("watched.kup");
    defer testing.allocator.free(root);
    var recorder = Recorder{ .session = &fx.session };
    defer recorder.deinit();
    var watcher = try Watcher.init(&fx.session, testing.io, recorder.listener());
    defer watcher.deinit();

    try testing.expect(!watcher.evaluate());
    try testing.expectEqualStrings(root, recorder.failed_module_path.?);

    try fx.rewrite(&watcher, "watched.kup", "x = cube(3)\n", MTIME_BUMP_NS);
    try testing.expect(try watcher.poll());
    try testing.expectApproxEqAbs(@as(f64, 27), fx.rootVolume(root), 1e-6);
    try testing.expectEqualSlices(std.meta.Tag(watcher_mod.Event), &.{ .failed, .changed, .built }, recorder.events.items);
}

test "Daemon Watcher: an edit to a JSON file the script reads rebuilds it" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("size.json", "{\"side\": 10}");
    try fx.write("main.kup", "import size from \"./size.json\"\nx = cube(size[:side])\n");
    const root = try fx.load("main.kup");
    defer testing.allocator.free(root);
    var recorder = Recorder{ .session = &fx.session };
    defer recorder.deinit();
    var watcher = try Watcher.init(&fx.session, testing.io, recorder.listener());
    defer watcher.deinit();
    try testing.expect(watcher.evaluate());
    try testing.expectApproxEqAbs(@as(f64, 1000), fx.rootVolume(root), 1e-6);

    // The module's source is the same: only the data says to run it again
    try fx.rewrite(&watcher, "size.json", "{\"side\": 20}", MTIME_BUMP_NS);
    try testing.expect(try watcher.poll());
    try testing.expectApproxEqAbs(@as(f64, 8000), fx.rootVolume(root), 1e-6);
    try testing.expectEqualSlices(std.meta.Tag(watcher_mod.Event), &.{ .built, .changed, .built }, recorder.events.items);
    try testing.expect(!try watcher.poll()); // nothing changed since
}

test "Daemon Watcher: a JSON file missing at the first build is watched, so creating it rebuilds" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("main.kup", "import size from \"./size.json\"\nx = cube(size[:side])\n");
    const root = try fx.load("main.kup");
    defer testing.allocator.free(root);
    var recorder = Recorder{ .session = &fx.session };
    defer recorder.deinit();
    var watcher = try Watcher.init(&fx.session, testing.io, recorder.listener());
    defer watcher.deinit();
    try testing.expect(!watcher.evaluate());

    try fx.write("size.json", "{\"side\": 3}");
    try testing.expect(try watcher.poll());
    try testing.expectApproxEqAbs(@as(f64, 27), fx.rootVolume(root), 1e-6);
    try testing.expectEqualSlices(std.meta.Tag(watcher_mod.Event), &.{ .run_failed, .changed, .built }, recorder.events.items);
}

test "Daemon Watcher: a file restored to an older version counts as a change" {
    // The mtime was compared with `>`, so `git checkout` of an older file was missed.
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("watched.kup", "x = cube(10)\n");
    const root = try fx.load("watched.kup");
    defer testing.allocator.free(root);
    var recorder = Recorder{ .session = &fx.session };
    defer recorder.deinit();
    var watcher = try Watcher.init(&fx.session, testing.io, recorder.listener());
    defer watcher.deinit();
    try testing.expect(watcher.evaluate());

    try fx.rewrite(&watcher, "watched.kup", "x = cube(2)\n", -MTIME_BUMP_NS);
    try testing.expect(try watcher.poll());
    try testing.expectApproxEqAbs(@as(f64, 8), fx.rootVolume(root), 1e-6);
}
