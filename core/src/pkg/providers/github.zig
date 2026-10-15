const std = @import("std");
const ParsedPackage = @import("provider.zig").ParsedPackage;

pub const GithubProvider = struct {
    /// Tags per page of the tag list (the API's maximum).
    pub const TAGS_PAGE_SIZE = 100;

    /// The page'th page (from 1) of the repository's tags, each with its commit.
    pub fn formatTagsUrl(allocator: std.mem.Allocator, pkg: ParsedPackage, page: usize) ![]const u8 {
        std.debug.assert(pkg.provider == .github);
        return allocator.print("https://api.github.com/repos/{s}/{s}/tags?per_page={d}&page={d}", .{ pkg.user, pkg.repo, TAGS_PAGE_SIZE, page });
    }

    /// Formats the API endpoint to resolve a branch/tag to a commit SHA
    pub fn formatApiUrl(allocator: std.mem.Allocator, pkg: ParsedPackage) ![]const u8 {
        std.debug.assert(pkg.provider == .github);
        return allocator.print("https://api.github.com/repos/{s}/{s}/commits/{s}", .{ pkg.user, pkg.repo, pkg.ref });
    }

    /// Formats the direct tarball download URL given a resolved commit SHA
    pub fn formatArchiveUrl(allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) ![]const u8 {
        std.debug.assert(pkg.provider == .github);
        return allocator.print("https://github.com/{s}/{s}/archive/{s}.tar.gz", .{ pkg.user, pkg.repo, commit_sha });
    }
};
