const std = @import("std");
const semver = @import("../../core/semver.zig");
const validate = @import("../validate.zig");
const ArchiveLayout = @import("../cafs.zig").ArchiveLayout;

/// Length of the hex digest prefix used to derive ids for URL/path based packages.
const URL_ID_HEX_LEN = 16;
/// Hex digits of the location-and-ref hash that ends a git-host package id.
const REF_ID_HEX_LEN = 8;

/// The first character of a ref that is a version range rather than a branch, tag or commit.
const RANGE_OPERATORS = "^~>=";

/// The public git hosts a bare `host/user/repo` may name, and the API each speaks.
const KNOWN_HOSTS = [_]struct { []const u8, ProviderType }{
    .{ "github.com", .github },
    .{ "gitlab.com", .gitlab },
    .{ "codeberg.org", .gitea },
    .{ "gitea.com", .gitea },
};

/// What a self-hosted git server is written with to say which API it speaks
/// (`gitlab:git.example.com/team/parts`): its API can't be told from its name.
const HOST_PREFIXES = [_]struct { []const u8, ProviderType }{
    .{ "gitlab:", .gitlab },
    .{ "gitea:", .gitea },
};

pub const ProviderType = enum {
    github,
    gitlab,
    gitea,
    http,
    local,

    /// Providers with a commit-resolution API (refs are pinned to an immutable commit).
    pub fn isGitHost(self: ProviderType) bool {
        return @import("git_host.zig").of(self) != null;
    }

    /// Git hosts wrap their archives in a top folder; an archive named directly is the package.
    pub fn archiveLayout(self: ProviderType) ArchiveLayout {
        return if (self.isGitHost()) .wrapped else .flat;
    }
};

pub const ParsedPackage = struct {
    provider: ProviderType,
    domain: []const u8,
    user: []const u8,
    repo: []const u8,
    ref: []const u8, // branch, tag, SHA or version range (default: "main"); empty for http/local
    /// A ref that is a version range (`^1.2`, `~1.4`, `>=2.0`, `=1.2.3`): resolved to the
    /// highest tag that satisfies it. A bare version such as `v1.2.3` is the tag itself.
    constraint: ?semver.Constraint = null,

    /// Parses and validates a dependency specifier. Every component is checked
    /// against a strict charset because specifiers may come from untrusted,
    /// downloaded manifests and are later used in URLs and filesystem paths.
    pub fn parse(requested_url: []const u8) !ParsedPackage {
        if (std.mem.startsWith(u8, requested_url, "file:")) {
            const path = requested_url[5..];
            if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPackageUrl;
            return .{ .provider = .local, .domain = "", .user = "", .repo = path, .ref = "" };
        }

        // Only gzip'd tarballs are extracted: a .zip was accepted here and then read as one.
        if (std.mem.endsWith(u8, requested_url, ".zip")) return error.UnsupportedArchive;
        if (std.mem.endsWith(u8, requested_url, ".tar.gz")) {
            try validateArchiveUrl(requested_url);
            return .{ .provider = .http, .domain = "", .user = "", .repo = requested_url, .ref = "" };
        }

        var spec = requested_url;
        var declared: ?ProviderType = null;
        for (HOST_PREFIXES) |prefix| {
            if (std.mem.startsWith(u8, spec, prefix[0])) {
                spec = spec[prefix[0].len..];
                declared = prefix[1];
            }
        }

        var base_url = spec;
        var ref: []const u8 = "main";
        var constraint: ?semver.Constraint = null;

        if (std.mem.indexOfScalar(u8, spec, '@')) |idx| {
            base_url = spec[0..idx];
            ref = spec[idx + 1 ..];

            // Only an operator makes it a range: `v2` may be a branch, and was always a ref.
            if (ref.len > 0 and std.mem.indexOfScalar(u8, RANGE_OPERATORS, ref[0]) != null) {
                try validate.validateRange(ref);
                constraint = semver.Constraint.parse(ref) catch return error.InvalidRef;
            }
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
        // query string or path traversal. (A range never reaches a URL: its tags are listed.)
        if (constraint == null) try validate.validateRef(ref);

        const provider_type = try providerFor(domain, declared);

        return .{
            .provider = provider_type,
            .domain = domain,
            .user = user,
            .repo = repo,
            .ref = ref,
            .constraint = constraint,
        };
    }

    /// Stable, filesystem-safe identifier for the package at its ref: the key of its
    /// kupcad.lock entry and store rows. A git-host package reads as its location, and a
    /// hash of location and ref keeps it unambiguous: `github.com/a-b/c` and
    /// `github.com/a/b-c` were both `github.com-a-b-c`, and one repository at two refs was
    /// one package, whichever install worker finished first. URL/path based packages
    /// hash their location so no URL characters reach the filesystem.
    pub fn pkgId(self: ParsedPackage, allocator: std.mem.Allocator) ![]const u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        if (self.provider.isGitHost()) {
            for ([_][]const u8{ self.domain, "/", self.user, "/", self.repo, "@", self.ref }) |part| hasher.update(part);
            hasher.final(&digest);
            const hex = std.fmt.bytesToHex(digest, .lower);
            return allocator.print("{s}-{s}-{s}-{s}", .{ self.domain, self.user, self.repo, hex[0..REF_ID_HEX_LEN] });
        }
        hasher.update(self.repo);
        hasher.final(&digest);
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

/// What is wrong with a specifier `ParsedPackage.parse` rejected, for a person.
pub fn describeParseError(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownPackageHost => "unknown git host; for a self-hosted server write gitlab:<host>/<user>/<repo> or gitea:<host>/<user>/<repo>",
        error.ProviderMismatch => "the prefix names another API than that host's",
        error.InvalidHost => "the host must be a plain name such as github.com (no port, no IP address)",
        error.InvalidRef => "the part after @ must be a branch, tag, commit or version",
        error.UnsupportedArchive => "only .tar.gz archives can be installed, not .zip",
        else => "expected <host>/<user>/<repo>[@ref], file:<path>, or an http(s) URL of a .tar.gz",
    };
}

/// The API `domain` speaks: a known host's, or the one its prefix declares. Unknown hosts
/// were taken for Gitea, so a self-hosted GitLab failed with a puzzling 404.
fn providerFor(domain: []const u8, declared: ?ProviderType) !ProviderType {
    for (KNOWN_HOSTS) |known| {
        if (!std.ascii.eqlIgnoreCase(known[0], domain)) continue;
        if (declared) |d| if (d != known[1]) return error.ProviderMismatch;
        return known[1];
    }
    return declared orelse error.UnknownPackageHost;
}

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
