const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

test "main: usage lists every command and the global options" {
    for ([_][]const u8{ "build", "watch", "check", "fmt", "doc", "pkg", "lsp", "dev", "--help", "--version" }) |needle| {
        errdefer std.debug.print("missing '{s}' in usage:\n{s}\n", .{ needle, main.USAGE });
        try testing.expect(std.mem.indexOf(u8, main.USAGE, needle) != null);
    }
}

test "main: the version comes from build.zig.zon" {
    try testing.expectEqualStrings("kupcad " ++ @import("build_info").version ++ "\n", main.VERSION_TEXT);
}
