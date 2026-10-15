const std = @import("std");
const ParsedPackage = @import("provider.zig").ParsedPackage;

pub const GiteaProvider = struct {
    /// Tags per page of the tag list (Gitea's default maximum).
    pub const TAGS_PAGE_SIZE = 50;

    /// The page'th page (from 1) of the repository's tags, each with its commit.
    pub fn formatTagsUrl(allocator: std.mem.Allocator, pkg: ParsedPackage, page: usize) ![]const u8 {
        std.debug.assert(pkg.provider == .gitea);
        return allocator.print("https://{s}/api/v1/repos/{s}/{s}/tags?limit={d}&page={d}", .{ pkg.domain, pkg.user, pkg.repo, TAGS_PAGE_SIZE, page });
    }

    pub fn formatApiUrl(allocator: std.mem.Allocator, pkg: ParsedPackage) ![]const u8 {
        std.debug.assert(pkg.provider == .gitea);
        return allocator.print("https://{s}/api/v1/repos/{s}/{s}/commits/{s}", .{ pkg.domain, pkg.user, pkg.repo, pkg.ref });
    }

    pub fn formatArchiveUrl(allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) ![]const u8 {
        std.debug.assert(pkg.provider == .gitea);
        return allocator.print("https://{s}/{s}/{s}/archive/{s}.tar.gz", .{ pkg.domain, pkg.user, pkg.repo, commit_sha });
    }
};
