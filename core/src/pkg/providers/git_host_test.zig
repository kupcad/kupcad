const std = @import("std");
const testing = std.testing;
const git_host = @import("git_host.zig");
const ParsedPackage = @import("provider.zig").ParsedPackage;

test "GitHost: each host's tag list, commit lookup and archive URLs" {
    const sha = "0123456789abcdef0123456789abcdef01234567";
    const cases = [_]struct { spec: []const u8, tags: []const u8, commit: []const u8, archive: []const u8 }{
        .{
            .spec = "github.com/kupcad/std@main",
            .tags = "https://api.github.com/repos/kupcad/std/tags?per_page=100&page=2",
            .commit = "https://api.github.com/repos/kupcad/std/commits/main",
            .archive = "https://github.com/kupcad/std/archive/" ++ sha ++ ".tar.gz",
        },
        .{
            .spec = "gitlab.com/kupcad/std@main",
            .tags = "https://gitlab.com/api/v4/projects/kupcad%2Fstd/repository/tags?per_page=100&page=2",
            .commit = "https://gitlab.com/api/v4/projects/kupcad%2Fstd/repository/commits/main",
            .archive = "https://gitlab.com/kupcad/std/-/archive/" ++ sha ++ "/std-" ++ sha ++ ".tar.gz",
        },
        .{
            .spec = "codeberg.org/kupcad/std@main",
            .tags = "https://codeberg.org/api/v1/repos/kupcad/std/tags?limit=50&page=2",
            .commit = "https://codeberg.org/api/v1/repos/kupcad/std/commits/main",
            .archive = "https://codeberg.org/kupcad/std/archive/" ++ sha ++ ".tar.gz",
        },
    };
    for (cases) |c| {
        errdefer std.debug.print("{s}\n", .{c.spec});
        const pkg = try ParsedPackage.parse(c.spec);
        const host = git_host.of(pkg.provider) orelse return error.NotAGitHost;
        inline for (.{ .{ "tags", 0 }, .{ "commit", 1 }, .{ "archive", 2 } }) |kind| {
            const url = switch (kind[1]) {
                0 => try host.tags_url(testing.allocator, pkg, 2),
                1 => try host.commit_url(testing.allocator, pkg),
                else => try host.archive_url(testing.allocator, pkg, sha),
            };
            defer testing.allocator.free(url);
            try testing.expectEqualStrings(@field(c, kind[0]), url);
        }
    }
}

test "GitHost: an http or local package is on no git host" {
    try testing.expect(git_host.of(.http) == null);
    try testing.expect(git_host.of(.local) == null);
    try testing.expect(git_host.of(.github) != null);
}

test "Providers: an http package's archive is its URL, a local one's the path it names, resolved" {
    const HttpProvider = @import("http.zig").HttpProvider;
    const LocalProvider = @import("local.zig").LocalProvider;
    const http = try HttpProvider.formatArchiveUrl(testing.allocator, try ParsedPackage.parse("https://example.com/parts-1.2.tar.gz"), "");
    defer testing.allocator.free(http);
    try testing.expectEqualStrings("https://example.com/parts-1.2.tar.gz", http);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg.tar.gz", .data = "" });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const expected = try std.fs.path.join(testing.allocator, &.{ dir, "pkg.tar.gz" });
    defer testing.allocator.free(expected);
    // Relative to the project (its folder given as written), or absolute inside it
    const local = try LocalProvider.formatArchiveUrl(testing.allocator, testing.io, try ParsedPackage.parse("file:./pkg.tar.gz"), dir);
    defer testing.allocator.free(local);
    try testing.expectEqualStrings(expected, local);
    const spec = try std.mem.concat(testing.allocator, u8, &.{ "file:", dir, "/./pkg.tar.gz" });
    defer testing.allocator.free(spec);
    const absolute = try LocalProvider.formatArchiveUrl(testing.allocator, testing.io, try ParsedPackage.parse(spec), dir);
    defer testing.allocator.free(absolute);
    try testing.expectEqualStrings(expected, absolute);
    // A path that isn't there is the install's error, not a link to nothing
    try testing.expectError(error.FileNotFound, LocalProvider.formatArchiveUrl(testing.allocator, testing.io, try ParsedPackage.parse("file:nonexistent/pkg.tar.gz"), dir));
    // One outside the project is refused, however it is written: a cloned manifest named any
    // archive on the disk
    var elsewhere = testing.tmpDir(.{});
    defer elsewhere.cleanup();
    try elsewhere.dir.writeFile(testing.io, .{ .sub_path = "pkg.tar.gz", .data = "" });
    const outside = try elsewhere.dir.realPathFileAlloc(testing.io, "pkg.tar.gz", testing.allocator);
    defer testing.allocator.free(outside);
    const by_path = try std.mem.concat(testing.allocator, u8, &.{ "file:", outside });
    defer testing.allocator.free(by_path);
    try testing.expectError(error.ArchiveOutsideProject, LocalProvider.formatArchiveUrl(testing.allocator, testing.io, try ParsedPackage.parse(by_path), dir));
    const by_climb = try std.mem.concat(testing.allocator, u8, &.{ "file:../", std.fs.path.basename(std.fs.path.dirname(outside).?), "/pkg.tar.gz" });
    defer testing.allocator.free(by_climb);
    try testing.expectError(error.ArchiveOutsideProject, LocalProvider.formatArchiveUrl(testing.allocator, testing.io, try ParsedPackage.parse(by_climb), dir));
}
