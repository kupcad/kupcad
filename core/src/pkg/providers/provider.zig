const std = @import("std");

pub const ProviderType = enum {
    github,
    gitlab,
    gitea, // Covers Codeberg and self-hosted Forgejo/Gitea
    http,
    local,
};

pub const ParsedPackage = struct {
    provider: ProviderType,
    domain: []const u8,
    user: []const u8,
    repo: []const u8,
    ref: []const u8, // branch, tag, or SHA (default: "main")

    /// Parses a URL string into a structured package identifier
    pub fn parse(requested_url: []const u8) !ParsedPackage {
        // Handle local paths first
        if (std.mem.startsWith(u8, requested_url, "file:")) {
            return .{
                .provider = .local,
                .domain = "",
                .user = "",
                .repo = requested_url[5..],
                .ref = "",
            };
        }

        // Handle direct HTTP archives
        if (std.mem.endsWith(u8, requested_url, ".tar.gz") or std.mem.endsWith(u8, requested_url, ".zip")) {
            return .{
                .provider = .http,
                .domain = "",
                .user = "",
                .repo = requested_url,
                .ref = "",
            };
        }

        // Handle Git-based providers
        var base_url = requested_url;
        var ref: []const u8 = "main";

        if (std.mem.indexOfScalar(u8, requested_url, '@')) |idx| {
            base_url = requested_url[0..idx];
            ref = requested_url[idx + 1 ..];
        }

        var iter = std.mem.splitScalar(u8, base_url, '/');
        const domain = iter.next() orelse return error.InvalidPackageUrl;
        const user = iter.next() orelse return error.InvalidPackageUrl;
        const repo = iter.next() orelse return error.InvalidPackageUrl;

        const provider_type: ProviderType = if (std.mem.eql(u8, domain, "github.com"))
            .github
        else if (std.mem.eql(u8, domain, "gitlab.com"))
            .gitlab
        else if (std.mem.eql(u8, domain, "codeberg.org"))
            .gitea
        else
            .gitea; // Fallback assumes self-hosted Gitea/Forgejo if unknown domain

        return .{
            .provider = provider_type,
            .domain = domain,
            .user = user,
            .repo = repo,
            .ref = ref,
        };
    }
};
