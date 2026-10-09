const std = @import("std");
const ParsedPackage = @import("provider.zig").ParsedPackage;

pub const GiteaProvider = struct {
    pub fn formatApiUrl(allocator: std.mem.Allocator, pkg: ParsedPackage) ![]const u8 {
        std.debug.assert(pkg.provider == .gitea);
        return allocator.print("https://{s}/api/v1/repos/{s}/{s}/commits/{s}", .{ pkg.domain, pkg.user, pkg.repo, pkg.ref });
    }

    pub fn formatArchiveUrl(allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) ![]const u8 {
        std.debug.assert(pkg.provider == .gitea);
        return allocator.print("https://{s}/{s}/{s}/archive/{s}.tar.gz", .{ pkg.domain, pkg.user, pkg.repo, commit_sha });
    }
};
