const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

test "main: usage lists every command and the global options" {
    for ([_][]const u8{ "build", "watch", "check", "fmt", "doc", "pkg", "lsp", "dev", "version", "--help", "--version" }) |needle| {
        errdefer std.debug.print("missing '{s}' in usage:\n{s}\n", .{ needle, main.USAGE });
        try testing.expect(std.mem.find(u8, main.USAGE, needle) != null);
    }
}

test "main: the version comes from build.zig.zon" {
    try testing.expectEqualStrings("kupcad " ++ @import("build_info").version ++ "\n", @import("cli/version_cmd.zig").TEXT);
}

test "main: every command has its own usage, which names it" {
    for (main.COMMANDS) |c| {
        errdefer std.debug.print("{s}:\n{s}\n", .{ c.name, c.usage });
        const head = try testing.allocator.print("Usage: kupcad {s}", .{c.name});
        defer testing.allocator.free(head);
        try testing.expect(std.mem.startsWith(u8, c.usage, head));
        try testing.expect(std.mem.endsWith(u8, c.usage, "\n"));
    }
    try testing.expect(std.mem.find(u8, main.USAGE, "Run 'kupcad <command> --help'") != null);
}

test "main: --help is found anywhere among a command's arguments" {
    const wants = @import("cli/args.zig").wantsHelp;
    try testing.expect(wants(&.{"--help"}));
    try testing.expect(wants(&.{ "part.kup", "-h" }));
    try testing.expect(!wants(&.{ "part.kup", "--helpful" }));
    try testing.expect(!wants(&.{}));
}
