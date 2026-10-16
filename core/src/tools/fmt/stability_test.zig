//! The formatter is stable: formatting its output changes nothing. Checked over every
//! script the repository has (the examples, the test fixtures, the lint snapshot cases),
//! since a layout that flips between two forms would make `fmt --check` fail forever.

const std = @import("std");
const testing = std.testing;
const api = @import("../../api.zig");

/// Relative to `core/`, where the tests run.
const DIRS = [_][]const u8{ "../examples", "src/fixtures", "src/tools/lint/snapshots" };

test "Formatter: formatting the formatted output changes nothing, for every script here" {
    var checked: usize = 0;
    for (DIRS) |path| {
        var dir = try std.Io.Dir.cwd().openDir(testing.io, path, .{ .iterate = true });
        defer dir.close(testing.io);
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".kup")) continue;
            const source = try dir.readFileAlloc(testing.io, entry.name, testing.allocator, .limited(1 << 20));
            defer testing.allocator.free(source);
            // Scripts that are meant not to parse (lint cases for syntax errors) can't be formatted.
            const once = api.formatCode(testing.allocator, source, .{}) catch |err| switch (err) {
                error.SyntaxError => continue,
                else => {
                    std.debug.print("{s}/{s}: {}\n", .{ path, entry.name, err });
                    return err;
                },
            };
            defer testing.allocator.free(once);
            const twice = try api.formatCode(testing.allocator, once, .{});
            defer testing.allocator.free(twice);
            errdefer std.debug.print("{s}/{s} formats differently the second time\n", .{ path, entry.name });
            try testing.expectEqualStrings(once, twice);
            checked += 1;
        }
    }
    try testing.expect(checked > 10);
}
