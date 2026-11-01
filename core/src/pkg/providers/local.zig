//! `LocalProvider`: a package archive on the local disk (`file:<path>`), whose "archive URL"
//! is the archive's real path, inside the project; used by pkg/resolver.zig.

const std = @import("std");
const ParsedPackage = @import("provider.zig").ParsedPackage;

pub const LocalProvider = struct {
    /// The real path of the archive `pkg` names, read from `project_dir` (a relative path
    /// is the project's), which must stay inside the project: a cloned project's manifest
    /// could otherwise name any archive on the disk (`file:../../anything.tar.gz`, an
    /// absolute path), and `pkg install` copied it into the project (ArchiveOutsideProject).
    pub fn formatArchiveUrl(allocator: std.mem.Allocator, io: std.Io, pkg: ParsedPackage, project_dir: []const u8) ![]const u8 {
        std.debug.assert(pkg.provider == .local);
        const cwd = std.Io.Dir.cwd();
        const project = try cwd.realPathFileAlloc(io, project_dir, allocator);
        defer allocator.free(project);
        const named = try std.fs.path.resolve(allocator, &.{ project, pkg.repo });
        defer allocator.free(named);
        // realPathFileAlloc returns a sentinel slice; re-dupe so callers can free it as []const u8.
        const real = try cwd.realPathFileAlloc(io, named, allocator);
        defer allocator.free(real);
        if (!std.mem.startsWith(u8, real, project) or real.len == project.len or real[project.len] != std.fs.path.sep) return error.ArchiveOutsideProject;
        return allocator.dupe(u8, real);
    }
};
