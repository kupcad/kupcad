const std = @import("std");
const ScriptSession = @import("../daemon/session.zig").ScriptSession;
const fs = @import("fs.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse return error.MissingFilePath;

    var session = try ScriptSession.init(allocator, init.io);
    defer session.deinit();

    // Initial load using the central file size limit
    const source = try fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE);
    defer allocator.free(source);

    _ = try session.workspace.addModule(file_path, source);
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    std.debug.print("Watching '{s}' for changes...\n", .{file_path});

    const cwd = std.Io.Dir.cwd();
    var last_mtime: i128 = 0;

    if (cwd.statFile(init.io, file_path, .{})) |stat| last_mtime = stat.mtime.nanoseconds else |_| {}

    while (true) {
        // Yield to the OS kernel using the new std.Io sleep interface
        init.io.sleep(.fromMilliseconds(500), .awake) catch {};

        if (cwd.statFile(init.io, file_path, .{})) |stat| {
            if (stat.mtime.nanoseconds > last_mtime) {
                last_mtime = stat.mtime.nanoseconds;
                std.debug.print("\nFile changed: {s}\n", .{file_path});

                try session.markFileEdited(file_path);

                const root_id = session.workspace.path_to_id.get(file_path).?;
                session.evaluateModule(root_id) catch |err| {
                    std.debug.print("Evaluation failed: {}\n", .{err});
                };
            }
        } else |_| {}
    }
}
