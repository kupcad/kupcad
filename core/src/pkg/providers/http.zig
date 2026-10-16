//! The package provider for a plain HTTP archive URL: the archive to download is the URL
//! itself, whatever the commit.

const std = @import("std");
const ParsedPackage = @import("provider.zig").ParsedPackage;

pub const HttpProvider = struct {
    /// For direct HTTP, the "repo" field contains the full raw URL.
    pub fn formatArchiveUrl(allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) ![]const u8 {
        _ = commit_sha;
        std.debug.assert(pkg.provider == .http);
        return allocator.dupe(u8, pkg.repo);
    }
};
