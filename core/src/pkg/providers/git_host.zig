//! The URLs of the git hosts packages come from, one entry per host: adding a host is one
//! entry here, where it was a struct of its own and a prong in four switches (one of them
//! an `else` that sent every other host to Gitea's URLs).

const std = @import("std");
const provider = @import("provider.zig");
const ParsedPackage = provider.ParsedPackage;

const Error = std.mem.Allocator.Error;

const HOSTS = std.EnumArray(provider.ProviderType, ?GitHost).init(.{
    .github = .{ .tags_page_size = 100, .tags_url = github.tags, .commit_url = github.commit, .archive_url = github.archive },
    .gitlab = .{ .tags_page_size = 100, .tags_url = gitlab.tags, .commit_url = gitlab.commit, .archive_url = gitlab.archive },
    .gitea = .{ .tags_page_size = 50, .tags_url = gitea.tags, .commit_url = gitea.commit, .archive_url = gitea.archive },
    .http = null,
    .local = null,
});

pub const GitHost = struct {
    /// Tags per page of the tag list (the most the host's API gives).
    tags_page_size: usize,
    /// The `page`th page (from 1) of the repository's tags, each with its commit.
    tags_url: *const fn (allocator: std.mem.Allocator, pkg: ParsedPackage, page: usize) Error![]const u8,
    /// The API endpoint that resolves `pkg.ref` to a commit.
    commit_url: *const fn (allocator: std.mem.Allocator, pkg: ParsedPackage) Error![]const u8,
    /// The archive of the repository at `commit_sha`.
    archive_url: *const fn (allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) Error![]const u8,
};

/// The git host `kind` names; null for a package that isn't on one (an http archive, a
/// local file), which has no commits or tags.
pub fn of(kind: provider.ProviderType) ?GitHost {
    return HOSTS.get(kind);
}

const github = struct {
    fn tags(allocator: std.mem.Allocator, pkg: ParsedPackage, page: usize) Error![]const u8 {
        return allocator.print("https://api.github.com/repos/{s}/{s}/tags?per_page={d}&page={d}", .{ pkg.user, pkg.repo, HOSTS.get(.github).?.tags_page_size, page });
    }
    fn commit(allocator: std.mem.Allocator, pkg: ParsedPackage) Error![]const u8 {
        return allocator.print("https://api.github.com/repos/{s}/{s}/commits/{s}", .{ pkg.user, pkg.repo, pkg.ref });
    }
    fn archive(allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) Error![]const u8 {
        return allocator.print("https://github.com/{s}/{s}/archive/{s}.tar.gz", .{ pkg.user, pkg.repo, commit_sha });
    }
};

const gitlab = struct {
    // The API names a project by its URL-encoded path (user%2Frepo).
    fn tags(allocator: std.mem.Allocator, pkg: ParsedPackage, page: usize) Error![]const u8 {
        return allocator.print("https://{s}/api/v4/projects/{s}%2F{s}/repository/tags?per_page={d}&page={d}", .{ pkg.domain, pkg.user, pkg.repo, HOSTS.get(.gitlab).?.tags_page_size, page });
    }
    fn commit(allocator: std.mem.Allocator, pkg: ParsedPackage) Error![]const u8 {
        return allocator.print("https://{s}/api/v4/projects/{s}%2F{s}/repository/commits/{s}", .{ pkg.domain, pkg.user, pkg.repo, pkg.ref });
    }
    fn archive(allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) Error![]const u8 {
        return allocator.print("https://{s}/{s}/{s}/-/archive/{s}/{s}-{s}.tar.gz", .{ pkg.domain, pkg.user, pkg.repo, commit_sha, pkg.repo, commit_sha });
    }
};

const gitea = struct {
    fn tags(allocator: std.mem.Allocator, pkg: ParsedPackage, page: usize) Error![]const u8 {
        return allocator.print("https://{s}/api/v1/repos/{s}/{s}/tags?limit={d}&page={d}", .{ pkg.domain, pkg.user, pkg.repo, HOSTS.get(.gitea).?.tags_page_size, page });
    }
    fn commit(allocator: std.mem.Allocator, pkg: ParsedPackage) Error![]const u8 {
        return allocator.print("https://{s}/api/v1/repos/{s}/{s}/commits/{s}", .{ pkg.domain, pkg.user, pkg.repo, pkg.ref });
    }
    fn archive(allocator: std.mem.Allocator, pkg: ParsedPackage, commit_sha: []const u8) Error![]const u8 {
        return allocator.print("https://{s}/{s}/{s}/archive/{s}.tar.gz", .{ pkg.domain, pkg.user, pkg.repo, commit_sha });
    }
};
