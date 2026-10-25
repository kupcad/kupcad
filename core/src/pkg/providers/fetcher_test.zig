const std = @import("std");
const testing = std.testing;
const Fetcher = @import("fetcher.zig").Fetcher;
const ParsedPackage = @import("provider.zig").ParsedPackage;
const semver = @import("../semver.zig");
const Release = @import("fetcher.zig").Release;
const Cafs = @import("../cafs.zig").Cafs;
const MemoryVfs = @import("../../vfs/memory.zig").MemoryVfs;
const SlowServer = @import("../test_helpers.zig").SlowServer;

const SHA_A: [40]u8 = @splat('a');
const SHA_B: [40]u8 = @splat('b');
const SHA_C: [40]u8 = @splat('c');

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

test "Fetcher: tagsApiUrl lists each host's tags with their commits, by page" {
    const cases = [_]struct { spec: []const u8, url: []const u8 }{
        .{ .spec = "github.com/u/r@^1.0", .url = "https://api.github.com/repos/u/r/tags?per_page=100&page=2" },
        .{ .spec = "gitlab.com/u/r@^1.0", .url = "https://gitlab.com/api/v4/projects/u%2Fr/repository/tags?per_page=100&page=2" },
        .{ .spec = "codeberg.org/u/r@^1.0", .url = "https://codeberg.org/api/v1/repos/u/r/tags?limit=50&page=2" },
    };
    for (cases) |c| {
        const url = try Fetcher.tagsApiUrl(testing.allocator, try ParsedPackage.parse(c.spec), 2);
        defer testing.allocator.free(url);
        try testing.expectEqualStrings(c.url, url);
    }
}

test "Fetcher: pickRelease keeps the highest tag a range accepts, across pages" {
    // `pkg add x@^1.0` failed (the ref was rejected), and a bare version was used as a ref.
    const constraint = try semver.Constraint.parse("^1.2");
    var best: ?Release = null;
    defer if (best) |*b| b.deinit(testing.allocator);

    const page1 = "[{\"name\":\"v2.0.0\",\"commit\":{\"sha\":\"" ++ SHA_A ++ "\"}}," ++
        "{\"name\":\"v1.4.0\",\"commit\":{\"sha\":\"" ++ SHA_B ++ "\"}}," ++
        "{\"name\":\"nightly\",\"commit\":{\"sha\":\"" ++ SHA_A ++ "\"}}," ++
        "{\"name\":\"v1.9.0-rc1\",\"commit\":{\"sha\":\"" ++ SHA_A ++ "\"}}]";
    try testing.expectEqual(@as(usize, 4), try Fetcher.pickRelease(testing.allocator, page1, constraint, &best));
    try testing.expectEqualStrings("v1.4.0", best.?.tag);

    // GitLab's commits have an `id`; a higher match on a later page wins, a lower one doesn't.
    const page2 = "[{\"name\":\"1.5.1\",\"commit\":{\"id\":\"" ++ SHA_C ++ "\"}},{\"name\":\"v1.2.0\",\"commit\":{\"sha\":\"" ++ SHA_A ++ "\"}}]";
    _ = try Fetcher.pickRelease(testing.allocator, page2, constraint, &best);
    try testing.expectEqualStrings("1.5.1", best.?.tag);
    try testing.expectEqualStrings(&SHA_C, best.?.commit);

    const rejected = [_][]const u8{
        "{}", "[5]", "[{\"name\":\"v1.3.0\"}]", "[{\"name\":\"v1.3.0\",\"commit\":{\"sha\":\"../x\"}}]",
    };
    for (rejected) |body| try testing.expectError(error.InvalidApiResponse, Fetcher.pickRelease(testing.allocator, body, constraint, &best));
}

test "Fetcher: a ref is a version range only when it starts with an operator" {
    const range = try ParsedPackage.parse("github.com/u/r@^1.2");
    try testing.expectEqual(semver.ConstraintOp.caret, range.constraint.?.op);
    try testing.expectEqualStrings("^1.2", range.ref);
    try testing.expect((try ParsedPackage.parse("github.com/u/r@>=2.0")).constraint != null);
    // A bare version (a tag) or a branch named like one stays a ref.
    try testing.expect((try ParsedPackage.parse("github.com/u/r@v1.2.3")).constraint == null);
    try testing.expect((try ParsedPackage.parse("github.com/u/r@v2")).constraint == null);
    // A range has a strict charset and must parse.
    try testing.expectError(error.InvalidRef, ParsedPackage.parse("github.com/u/r@^1.x"));
    try testing.expectError(error.InvalidRef, ParsedPackage.parse("github.com/u/r@^1.0/../x"));
    try testing.expectError(error.InvalidRef, ParsedPackage.parse("github.com/u/r@^"));
}

test "Fetcher: an archive whose host stops sending is abandoned" {
    // Its head, then nothing: the install waited for good
    var server: SlowServer = undefined;
    try server.start(.{});
    defer server.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var files = MemoryVfs.init(testing.allocator);
    defer files.deinit();
    var cafs = try Cafs.init(testing.allocator, testing.io, root, files.vfs());
    defer cafs.deinit();

    var fetcher = Fetcher.init(testing.allocator, testing.io);
    defer fetcher.deinit();
    fetcher.stall = .fromMilliseconds(100);
    var url_buf: [64]u8 = undefined;
    try testing.expectError(error.DownloadStalled, fetcher.downloadArchive(try server.url(&url_buf, "/p.tar.gz"), &cafs, .flat));
}
