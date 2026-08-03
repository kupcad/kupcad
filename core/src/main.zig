const std = @import("std");
const api = @import("api.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.skip(); // Skip executable name

    const cmd = args_iter.next() orelse {
        std.debug.print("Usage: kupcad <command> [file]\nCommands: fmt, check\n", .{});
        return;
    };

    if (std.mem.eql(u8, cmd, "fmt")) {
        const file_path = args_iter.next() orelse {
            std.debug.print("Error: Missing file path\n", .{});
            return;
        };

        const source = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024 * 10));
        defer allocator.free(source);

        const formatted = api.formatCode(allocator, source) catch |err| {
            std.debug.print("Format failed: {}\n", .{err});
            return;
        };
        defer allocator.free(formatted);

        std.debug.print("{s}", .{formatted});
    } else if (std.mem.eql(u8, cmd, "check")) {
        const file_path = args_iter.next() orelse {
            std.debug.print("Error: Missing file path\n", .{});
            return;
        };

        // Zig 0.16: Use std.Io.Dir and pass the `io` handle and a `.limited()` enum
        const source = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024 * 10));
        defer allocator.free(source);

        const diags = try api.checkCode(allocator, source);
        defer {
            for (diags) |d| allocator.free(d.message);
            allocator.free(diags);
        }

        if (diags.len == 0) {
            std.debug.print("Success: No issues found.\n", .{});
        } else {
            for (diags) |d| {
                std.debug.print("[{s}] Line {d}, Col {d}: {s}\n", .{ @tagName(d.severity), d.loc.line, d.loc.col, d.message });
            }
        }
    } else {
        std.debug.print("Unknown command: {s}\n", .{cmd});
    }
}
