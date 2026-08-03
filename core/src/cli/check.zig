const std = @import("std");
const api = @import("../api.zig");

const FILE_SIZE_LIMIT = 1024 * 1024 * 10;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse {
        std.debug.print("Error: Missing file path. Usage: kupcad check <file>\n", .{});
        return;
    };

    // Read the file
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, file_path, allocator, .limited(FILE_SIZE_LIMIT));
    defer allocator.free(source);

    // Process via our pure API
    const diags = try api.checkCode(allocator, source);
    defer {
        for (diags) |d| allocator.free(d.message);
        allocator.free(diags);
    }

    if (diags.len == 0) {
        std.debug.print("Success: No syntax or semantic issues found.\n", .{});
    } else {
        std.debug.print("Found {d} issue(s):\n", .{diags.len});
        for (diags) |d| {
            std.debug.print("[{s}] Line {d}, Col {d}: {s}\n", .{ @tagName(d.severity), d.loc.line, d.loc.col, d.message });
        }
    }
}
