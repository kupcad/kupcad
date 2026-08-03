const std = @import("std");
const api = @import("../api.zig");

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse {
        std.debug.print("Error: Missing file path. Usage: kupcad fmt <file>\n", .{});
        return;
    };

    // Read the file using the secure IO handle
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, file_path, allocator, .limited(1024 * 1024 * 10));
    defer allocator.free(source);

    // Process via our pure API
    const formatted = api.formatCode(allocator, source) catch |err| {
        std.debug.print("Format failed: {}\n", .{err});
        return;
    };
    defer allocator.free(formatted);

    // Print to stdout (or overwrite file later)
    std.debug.print("{s}", .{formatted});
}
