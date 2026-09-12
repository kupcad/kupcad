const std = @import("std");
const ParsedPackage = @import("provider.zig").ParsedPackage;

pub const GithubProvider = struct {
    /// Formats the API endpoint to resolve a branch/tag to a commit SHA
    pub fn formatApiUrl(allocator: std.mem.Allocator, pkg: ParsedPackage) ![]const u8 {
        std.debug.assert(pkg.provider == .github);
        return std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/commits/{s}", .{ pkg.user, pkg.repo, pkg.ref });
    }

    /// Formats the direct tarball download URL given a resolved commit SHA
    pub fn formatArchiveUrl(allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) ![]const u8 {
        std.debug.assert(pkg.provider == .github);
        return std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/archive/{s}.tar.gz", .{ pkg.user, pkg.repo, commit_sha });
    }
};
