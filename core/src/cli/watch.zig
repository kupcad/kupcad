const std = @import("std");
const ScriptSession = @import("../daemon/session.zig").ScriptSession;
const Watcher = @import("../daemon/watcher.zig").Watcher;
const fs = @import("fs.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse return error.MissingFilePath;

    var session = try ScriptSession.init(allocator, init.io);
    defer session.deinit();

    // Initial load
    const source = try fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE);
    defer allocator.free(source);

    _ = try session.workspace.addModule(file_path, source);
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    // Initialize and block on the libxev event loop
    var watcher = try Watcher.init(&session, file_path, init.io);
    defer watcher.deinit();

    try watcher.start();
}
