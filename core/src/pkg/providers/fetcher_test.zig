const std = @import("std");
const testing = std.testing;
const Fetcher = @import("fetcher.zig").Fetcher;
const ParsedPackage = @import("provider.zig").ParsedPackage;

// Guards the audit fix where non-GitHub hosts used the raw ref as the request URL.
test "Fetcher: commitApiUrl dispatches per provider and never uses the ref as a URL" {
    const cases = [_]struct { spec: []const u8, url: []const u8 }{
        .{ .spec = "github.com/u/r@main", .url = "https://api.github.com/repos/u/r/commits/main" },
        .{ .spec = "gitlab.com/u/r@v1.0", .url = "https://gitlab.com/api/v4/projects/u%2Fr/repository/commits/v1.0" },
        .{ .spec = "gitea:git.example.org/u/r@main", .url = "https://git.example.org/api/v1/repos/u/r/commits/main" },
        .{ .spec = "gitlab:git.example.org/u/r@main", .url = "https://git.example.org/api/v4/projects/u%2Fr/repository/commits/main" },
    };
    for (cases) |c| {
        const url = try Fetcher.commitApiUrl(testing.allocator, try ParsedPackage.parse(c.spec));
        defer testing.allocator.free(url);
        try testing.expectEqualStrings(c.url, url);
    }

    // Archive URLs and local paths have no commit API.
    try testing.expectError(error.NotApplicable, Fetcher.commitApiUrl(testing.allocator, try ParsedPackage.parse("https://example.org/pkg.tar.gz")));
    try testing.expectError(error.NotApplicable, Fetcher.commitApiUrl(testing.allocator, try ParsedPackage.parse("file:/tmp/pkg.tar.gz")));
}

// The commit id ends up in paths and URLs, so the API body's shape is validated.
test "Fetcher: parseCommitShaResponse validates the response shape" {
    const sha = "0123456789abcdef0123456789abcdef01234567";
    const sha256 = sha ++ "0123456789abcdef01234567";
    const accepted = [_][]const u8{
        "{\"sha\": \"" ++ sha ++ "\"}", // GitHub / Gitea
        "{\"id\": \"" ++ sha ++ "\"}", // GitLab
        "[{\"sha\": \"" ++ sha ++ "\"}]", // Gitea list endpoints
    };
    for (accepted) |body| {
        const got = try Fetcher.parseCommitShaResponse(testing.allocator, body);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(sha, got);
    }
    const got256 = try Fetcher.parseCommitShaResponse(testing.allocator, "{\"sha\": \"" ++ sha256 ++ "\"}");
    defer testing.allocator.free(got256);
    try testing.expectEqualStrings(sha256, got256);

    const rejected = [_][]const u8{
        "not json",                            "[]",                                   "\"str\"",
        "{}",                                  "{\"sha\": 5}",                         "{\"sha\": \"../../etc\"}",
        "{\"sha\": \"" ++ sha[0..39] ++ "\"}", "{\"sha\": \"" ++ sha[0..39] ++ "g\"}",
    };
    for (rejected) |body| {
        testing.expectError(error.InvalidApiResponse, Fetcher.parseCommitShaResponse(testing.allocator, body)) catch |err| {
            std.debug.print("accepted API body: {s}\n", .{body});
            return err;
        };
    }
}
