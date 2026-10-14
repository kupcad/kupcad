const std = @import("std");
const fs = @import("fs.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;
const log_helpers = @import("../log.zig");

/// Generic file processor callback.
pub const ProcessFileFn = *const fn (io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void;

/// Calls `processFn` for every `.kup` file under `paths` (files or directories).
/// Returns how many paths or files could not be read; they are logged and skipped,
/// so one bad path doesn't hide results for the rest, but callers must still fail.
pub fn walkPaths(io: std.Io, allocator: std.mem.Allocator, paths: []const []const u8, context: ?*anyopaque, processFn: ProcessFileFn) !usize {
    const cwd = std.Io.Dir.cwd();
    var unreadable: usize = 0;

    for (paths) |path| {
        if (cwd.openDir(io, path, .{ .iterate = true })) |dir_obj| {
            var dir = dir_obj;
            defer dir.close(io);

            var dir_walker = try dir.walk(allocator);
            defer dir_walker.deinit();

            while (try dir_walker.next(io)) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".kup")) {
                    const full_path = try std.fs.path.join(allocator, &.{ path, entry.path });
                    defer allocator.free(full_path);
                    if (!try readAndProcess(io, allocator, full_path, context, processFn)) unreadable += 1;
                }
            }
        } else |err| {
            if (err == error.NotDir) {
                if (!try readAndProcess(io, allocator, path, context, processFn)) unreadable += 1;
            } else {
                reportUnreadable(io, path, err);
                unreadable += 1;
            }
        }
    }
    return unreadable;
}

fn reportUnreadable(io: std.Io, path: []const u8, err: anyerror) void {
    log_helpers.printStderr(io, "Error: Could not read '{s}': {s}\n", .{ path, @errorName(err) });
}

/// False if the file could not be read (logged; the walk continues).
fn readAndProcess(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, context: ?*anyopaque, processFn: ProcessFileFn) !bool {
    const source = fs.readFileLimit(io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        reportUnreadable(io, file_path, err);
        return false;
    };
    defer allocator.free(source);

    try processFn(io, allocator, file_path, source, context);
    return true;
}
