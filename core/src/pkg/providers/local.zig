const std = @import("std");
const ParsedPackage = @import("provider.zig").ParsedPackage;

pub const LocalProvider = struct {
    pub fn formatApiUrl(allocator: std.mem.Allocator, pkg: ParsedPackage) ![]const u8 {
        _ = allocator;
        _ = pkg;
        return error.NotApplicable;
    }

    pub fn formatArchiveUrl(allocator: std.mem.Allocator, io: std.Io, pkg: ParsedPackage, commit_sha: []const u8) ![]const u8 {
        _ = commit_sha;
        std.debug.assert(pkg.provider == .local);

        const cwd = std.Io.Dir.cwd();
        // realPathFileAlloc returns a sentinel slice; re-dupe so callers can free it as []const u8.
        const real = try cwd.realPathFileAlloc(io, pkg.repo, allocator);
        defer allocator.free(real);
        return allocator.dupe(u8, real);
    }
};
