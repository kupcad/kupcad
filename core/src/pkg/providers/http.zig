const std = @import("std");
const ParsedPackage = @import("provider.zig").ParsedPackage;

pub const HttpProvider = struct {
    /// HTTP archives don't have a commit API. The system should catch error.NotApplicable
    /// and proceed directly to downloading the archive.
    pub fn formatApiUrl(allocator: std.mem.Allocator, pkg: ParsedPackage) ![]const u8 {
        _ = allocator;
        _ = pkg;
        return error.NotApplicable;
    }

    /// For direct HTTP, the "repo" field contains the full raw URL.
    pub fn formatArchiveUrl(allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) ![]const u8 {
        _ = commit_sha;
        std.debug.assert(pkg.provider == .http);
        return allocator.dupe(u8, pkg.repo);
    }
};
