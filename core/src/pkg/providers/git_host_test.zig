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
