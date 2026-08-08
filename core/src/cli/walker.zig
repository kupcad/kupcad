const std = @import("std");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;

/// Generic file processor callback.
pub const ProcessFileFn = *const fn (io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void;

pub fn walkPaths(io: std.Io, allocator: std.mem.Allocator, paths: []const []const u8, context: ?*anyopaque, processFn: ProcessFileFn) !void {
    const cwd = std.Io.Dir.cwd();

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
                    try readAndProcess(io, allocator, full_path, context, processFn);
                }
            }
        } else |err| {
            if (err == error.NotDir) {
                try readAndProcess(io, allocator, path, context, processFn);
            } else {
                std.debug.print("Error accessing '{s}': {}\n", .{ path, err });
            }
        }
    }
}

fn readAndProcess(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, context: ?*anyopaque, processFn: ProcessFileFn) !void {
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(io, file_path, allocator, .limited(MAX_FILE_SIZE)) catch |err| {
        std.debug.print("Error reading '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(source);

    try processFn(io, allocator, file_path, source, context);
}
