const std = @import("std");
const testing = std.testing;
const pkg_cmd = @import("pkg_cmd.zig");
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const Args = @import("args.zig").Args;
const Reporter = @import("reporter.zig").Reporter;

test "pkg: a request is read whole before anything is opened, a stray argument refused" {
    // `prune --forse` pruned without --force, and `add` checked its argument only after
    // reading kupcad.json
    const cases = [_]struct { args: []const []const u8, request: ?pkg_cmd.Request = null, message: []const u8 = "" }{
        .{ .args = &.{"init"}, .request = .init },
        .{ .args = &.{"install"}, .request = .install },
        .{ .args = &.{"doctor"}, .request = .doctor },
        .{ .args = &.{"prune"}, .request = .{ .prune = .{ .force = false } } },
        .{ .args = &.{ "prune", "--force" }, .request = .{ .prune = .{ .force = true } } },
        .{ .args = &.{}, .message = "Usage: kupcad pkg <init|add|install|prune|doctor>" },
        .{ .args = &.{"frob"}, .message = "Error: Unknown pkg command 'frob'" },
        .{ .args = &.{ "prune", "--forse" }, .message = "Error: Unexpected argument '--forse' for kupcad pkg prune" },
        .{ .args = &.{ "prune", "--force", "now" }, .message = "Error: Unexpected argument 'now' for kupcad pkg prune" },
        .{ .args = &.{ "doctor", "--fix" }, .message = "Error: Unexpected argument '--fix' for kupcad pkg doctor" },
        .{ .args = &.{ "install", "x" }, .message = "Error: Unexpected argument 'x' for kupcad pkg install" },
        .{ .args = &.{"add"}, .message = "Usage: kupcad pkg add <alias>=<url>" },
        .{ .args = &.{ "add", "parts" }, .message = "Error: Expected <alias>=<url>, got 'parts'" },
        .{ .args = &.{ "add", "=github.com/a/b" }, .message = "Error: Expected <alias>=<url>, got '=github.com/a/b'" },
        .{ .args = &.{ "add", "-x=github.com/a/b" }, .message = "Error: Invalid alias '-x'" },
        .{ .args = &.{ "add", "parts=not a url" }, .message = "Error: Invalid package URL 'not a url'" },
        .{ .args = &.{ "add", "a=github.com/a/b", "c=github.com/c/d" }, .message = "Error: Unexpected argument 'c=github.com/c/d' for kupcad pkg add" },
    };
    for (cases) |case| {
        errdefer std.debug.print("args: {any}\n", .{case.args});
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var args = Args{ .items = case.args };
        const request = pkg_cmd.parseRequest(&args, .{ .io = testing.io, .capture = &out.writer });
        if (case.request) |expected| {
            try testing.expectEqual(expected, request.?);
            try testing.expectEqualStrings("", out.written());
        } else {
            try testing.expect(request == null);
            try testing.expect(std.mem.startsWith(u8, out.written(), case.message));
        }
    }

    // An added dependency keeps its alias and URL, and what the URL names
    var args = Args{ .items = &.{ "add", "parts=github.com/team/parts@^1.2" } };
    const added = pkg_cmd.parseRequest(&args, .{ .io = testing.io }).?.add;
    try testing.expectEqualStrings("parts", added.alias);
    try testing.expectEqualStrings("github.com/team/parts@^1.2", added.url);
    try testing.expect(added.package.constraint != null);
}

test "pkg init: writes a manifest once, and refuses to overwrite an existing one" {
    // It overwrote kupcad.json, dependencies and all, and exited 0.
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const reporter: @import("reporter.zig").Reporter = .{ .io = testing.io, .capture = &out.writer };

    try testing.expectEqual(.success, try pkg_cmd.initManifest(testing.allocator, mem.vfs(), reporter));
    try testing.expectEqualStrings("Initialized kupcad.json\n", out.written());
    const fresh = try mem.vfs().readFile(testing.allocator, "kupcad.json");
    defer testing.allocator.free(fresh);

    try mem.vfs().writeFile("kupcad.json", "{ \"name\": \"mine\", \"version\": \"1.0.0\", \"dependencies\": { \"hw\": \"github.com/x/hw\" } }");
    out.clearRetainingCapacity();
    try testing.expectEqual(.failure, try pkg_cmd.initManifest(testing.allocator, mem.vfs(), reporter));
    try testing.expect(std.mem.startsWith(u8, out.written(), "Error: kupcad.json already exists here; nothing changed."));
    const kept = try mem.vfs().readFile(testing.allocator, "kupcad.json");
    defer testing.allocator.free(kept);
    try testing.expect(std.mem.find(u8, kept, "github.com/x/hw") != null);
}
