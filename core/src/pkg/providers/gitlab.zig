const std = @import("std");
const ParsedPackage = @import("provider.zig").ParsedPackage;

pub const GitlabProvider = struct {
    pub fn formatApiUrl(allocator: std.mem.Allocator, pkg: ParsedPackage) ![]const u8 {
        std.debug.assert(pkg.provider == .gitlab);
        // GitLab API requires the project path to be URL-encoded (user%2Frepo)
        return std.fmt.allocPrint(allocator, "https://{s}/api/v4/projects/{s}%2F{s}/repository/commits/{s}", .{ pkg.domain, pkg.user, pkg.repo, pkg.ref });
    }

    pub fn formatArchiveUrl(allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) ![]const u8 {
        std.debug.assert(pkg.provider == .gitlab);
        return std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}/-/archive/{s}/{s}-{s}.tar.gz", .{ pkg.domain, pkg.user, pkg.repo, commit_sha, pkg.repo, commit_sha });
    }
};
