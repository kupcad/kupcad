const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const version_cmd = @import("version_cmd.zig");
const Args = @import("args.zig").Args;
const frame = @import("../preview/frame.zig");

/// What `kupcad version` with `items` prints, and how it ends.
fn ran(items: []const []const u8, out: *std.Io.Writer.Allocating) version_cmd.Outcome {
    var args: Args = .{ .items = items };
    return version_cmd.run(&args, .{ .io = testing.io, .capture = &out.writer });
}

test "version: the text --version prints, or with --json the version, protocol and platform" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(.success, ran(&.{}, &out));
    try testing.expectEqualStrings("kupcad " ++ @import("build_info").version ++ "\n", out.written());

    out.clearRetainingCapacity();
    try testing.expectEqual(.success, ran(&.{"--json"}, &out));
    // Parsed strictly: what a front end reads, field for field
    const Info = struct { version: []const u8, protocolVersion: u32, os: []const u8, arch: []const u8 };
    const parsed = try std.json.parseFromSlice(Info, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(@import("build_info").version, parsed.value.version);
    try testing.expectEqual(frame.PROTOCOL_VERSION, parsed.value.protocolVersion);
    try testing.expectEqualStrings(@tagName(builtin.os.tag), parsed.value.os);
    try testing.expectEqualStrings(@tagName(builtin.cpu.arch), parsed.value.arch);
}

test "version: an option it doesn't take fails, saying so" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(.failure, ran(&.{"--yaml"}, &out));
    try testing.expect(std.mem.startsWith(u8, out.written(), "Error: Unknown option '--yaml'"));
}
