const std = @import("std");
const ParsedPackage = @import("provider.zig").ParsedPackage;

pub const GitlabProvider = struct {
    /// Tags per page of the tag list (the API's maximum).
    pub const TAGS_PAGE_SIZE = 100;

    /// The page'th page (from 1) of the repository's tags, each with its commit.
    pub fn formatTagsUrl(allocator: std.mem.Allocator, pkg: ParsedPackage, page: usize) ![]const u8 {
        std.debug.assert(pkg.provider == .gitlab);
        return allocator.print("https://{s}/api/v4/projects/{s}%2F{s}/repository/tags?per_page={d}&page={d}", .{ pkg.domain, pkg.user, pkg.repo, TAGS_PAGE_SIZE, page });
    }

    pub fn formatApiUrl(allocator: std.mem.Allocator, pkg: ParsedPackage) ![]const u8 {
        std.debug.assert(pkg.provider == .gitlab);
        // GitLab API requires the project path to be URL-encoded (user%2Frepo)
        return allocator.print("https://{s}/api/v4/projects/{s}%2F{s}/repository/commits/{s}", .{ pkg.domain, pkg.user, pkg.repo, pkg.ref });
    }

    pub fn formatArchiveUrl(allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) ![]const u8 {
        std.debug.assert(pkg.provider == .gitlab);
        return allocator.print("https://{s}/{s}/{s}/-/archive/{s}/{s}-{s}.tar.gz", .{ pkg.domain, pkg.user, pkg.repo, commit_sha, pkg.repo, commit_sha });
    }
};
