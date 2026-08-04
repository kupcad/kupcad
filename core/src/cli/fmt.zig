const std = @import("std");
const api = @import("../api.zig");

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    var has_args = false;

    // Loop over multiple files/globs
    while (args_iter.next()) |path| {
        has_args = true;
        try processPath(init, allocator, path);
    }

    if (!has_args) {
        std.debug.print("Error: Missing file path. Usage: kupcad fmt <file|dir>...\n", .{});
    }
}

fn processPath(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    if (cwd.openDir(init.io, path, .{ .iterate = true })) |dir_obj| {
        var dir = dir_obj;
        defer dir.close(init.io);

        // FIX: dir.walk only takes the allocator
        var walker = try dir.walk(allocator);
        defer walker.deinit();

        // FIX: walker.next takes the IO context to perform syscalls
        while (try walker.next(init.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".kup")) {
                const full_path = try std.fs.path.join(allocator, &.{ path, entry.path });
                defer allocator.free(full_path);
                try processFile(init, allocator, full_path);
            }
        }
    } else |err| {
        if (err == error.NotDir) {
            try processFile(init, allocator, path);
        } else {
            std.debug.print("Error accessing '{s}': {}\n", .{ path, err });
        }
    }
}

fn processFile(init: std.process.Init, allocator: std.mem.Allocator, file_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, file_path, allocator, .limited(1024 * 1024 * 10)) catch |err| {
        std.debug.print("Error reading '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(source);

    // Process via our pure API
    const formatted = api.formatCode(allocator, source) catch |err| {
        std.debug.print("Format failed for '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(formatted);

    // Print to stdout (later, we can implement in-place writes using atomicFile)
    std.debug.print("{s}", .{formatted});
}
