const std = @import("std");
const Watcher = @import("../daemon/watcher.zig").Watcher;
const fs = @import("fs.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse return error.MissingFilePath;

    // Spin up the cache controller
    var manager = SessionManager.init(allocator, 1);
    defer manager.deinit();

    var session = try manager.getOrInitializeSession(file_path, init.io);

    const source = try fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE);
    defer allocator.free(source);

    _ = try session.workspace.addModule(file_path, source);
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    // Perform initial cold-boot evaluation
    try session.evaluateWorkspace();

    // Initialize and block on the libxev event loop using the persistent session
    var watcher = try Watcher.init(session, file_path, init.io);
    defer watcher.deinit();

    try watcher.start();
}
