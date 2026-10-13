const std = @import("std");
const semver = @import("../../core/semver.zig");
const validate = @import("../validate.zig");

pub const ProviderType = enum {
    github,
    gitlab,
    gitea,
    http,
    local,

    /// Providers with a commit-resolution API (refs are pinned to an immutable commit).
    pub fn isGitHost(self: ProviderType) bool {
        return switch (self) {
            .github, .gitlab, .gitea => true,
            .http, .local => false,
        };
    }
};

/// Length of the hex digest prefix used to derive ids for URL/path based packages.
const URL_ID_HEX_LEN = 16;

pub const ParsedPackage = struct {
    provider: ProviderType,
    domain: []const u8,
    user: []const u8,
    repo: []const u8,
    ref: []const u8, // branch, tag, or SHA (default: "main"); empty for http/local
    constraint: ?semver.Constraint = null, // Extracted SemVer criteria

    /// Parses and validates a dependency specifier. Every component is checked
    /// against a strict charset because specifiers may come from untrusted,
    /// downloaded manifests and are later used in URLs and filesystem paths.
    pub fn parse(requested_url: []const u8) !ParsedPackage {
        if (std.mem.startsWith(u8, requested_url, "file:")) {
            const path = requested_url[5..];
            if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPackageUrl;
            return .{ .provider = .local, .domain = "", .user = "", .repo = path, .ref = "" };
        }

        if (std.mem.endsWith(u8, requested_url, ".tar.gz") or std.mem.endsWith(u8, requested_url, ".zip")) {
            try validateArchiveUrl(requested_url);
            return .{ .provider = .http, .domain = "", .user = "", .repo = requested_url, .ref = "" };
        }

        var base_url = requested_url;
        var ref: []const u8 = "main";
        var constraint: ?semver.Constraint = null;

        if (std.mem.indexOfScalar(u8, requested_url, '@')) |idx| {
            base_url = requested_url[0..idx];
            ref = requested_url[idx + 1 ..];

            // Attempt to parse the reference as a strict SemVer constraint
            if (semver.Constraint.parse(ref)) |parsed| {
                constraint = parsed;
            } else |_| {} // Fall back to treating it as a raw branch/SHA
        }

        var iter = std.mem.splitScalar(u8, base_url, '/');
        const domain = iter.next() orelse return error.InvalidPackageUrl;
        const user = iter.next() orelse return error.InvalidPackageUrl;
        const repo = iter.next() orelse return error.InvalidPackageUrl;
        if (iter.next() != null) return error.InvalidPackageUrl;

        try validate.validateHost(domain);
        try validate.validateRepoSegment(user);
        try validate.validateRepoSegment(repo);
        // Refs are interpolated into API URLs; never allow them to carry a scheme,
        // query string or path traversal.
        try validate.validateRef(ref);

        const provider_type: ProviderType = if (std.mem.eql(u8, domain, "github.com"))
            .github
        else if (std.mem.eql(u8, domain, "gitlab.com"))
            .gitlab
        else if (std.mem.eql(u8, domain, "codeberg.org"))
            .gitea
        else
            .gitea;

        return .{
            .provider = provider_type,
            .domain = domain,
            .user = user,
            .repo = repo,
            .ref = ref,
            .constraint = constraint,
        };
    }

    /// Stable, filesystem-safe identifier for the package (used as a store folder name).
    /// URL/path based packages hash their location so no URL characters reach the filesystem.
    pub fn pkgId(self: ParsedPackage, allocator: std.mem.Allocator) ![]const u8 {
        if (self.provider.isGitHost()) {
            return allocator.print("{s}-{s}-{s}", .{ self.domain, self.user, self.repo });
        }
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.repo, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        return allocator.print("{s}-{s}", .{ @tagName(self.provider), hex[0..URL_ID_HEX_LEN] });
    }

    /// Whether a dependency declared by a *downloaded* package may be followed.
    /// Transitive deps may only reference public git hosts: `file:` would read
    /// arbitrary local paths and raw URLs / IP-literal hosts enable SSRF.
    pub fn isAllowedTransitive(self: ParsedPackage) bool {
        if (!self.provider.isGitHost()) return false;
        return validate.isPublicRegistryHost(self.domain);
    }
};

/// Direct archive URLs must be absolute http(s) URLs with a plain hostname.
fn validateArchiveUrl(url: []const u8) !void {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.InvalidPackageUrl;
    for (url) |c| if (c <= ' ' or c == 0x7f) return error.InvalidPackageUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidPackageUrl;
    if (uri.user != null or uri.password != null) return error.InvalidPackageUrl;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = std.Io.net.HostName.fromUri(uri, &host_buf) catch return error.InvalidPackageUrl;
    validate.validateHost(host.bytes) catch return error.InvalidPackageUrl;
}
